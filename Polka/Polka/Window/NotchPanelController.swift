import AppKit
import Combine
import SwiftUI

/// Owns the notch panel and drives its state:
/// hover to expand, leave to collapse, any drag on screen opens it as a drop target.
@MainActor
final class NotchPanelController {
    private let store: ShelfStore
    private let images: ShelfItemImages
    private let openSettings: @MainActor () -> Void
    private let quickLook: QuickLookController
    private let share: ShareController
    private let fileChooser: FileChooser
    /// Nearby Sharing: offers from other Macs open the panel by themselves.
    private let nearby: NearbyService?
    private let model: NotchViewModel
    private let dragMonitor = GlobalDragMonitor()
    private let dragSource: ShelfDragSource
    /// Cmd-V and Cmd-C over the open shelf, on only while the pointer is over it.
    private let shortcuts = ShelfShortcuts()
    /// Read on every use, so a change in Settings applies right away.
    private let settings = ShelfSettings()
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?

    private var mouseMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    /// A menu is open: a header symbol's ("Sort By", "Add New") or a tile's right-click
    /// menu. The shelf stays open meanwhile, wherever the pointer goes, so the menu
    /// is never left floating over a collapsed notch.
    private var isMenuOpen = false
    /// Settings is open. The shelf stays open meanwhile, wherever the pointer goes, so
    /// changes to its look show as they're made (`openForSettings`).
    private var isSettingsOpen = false
    /// Moves the shelf to the Settings screen once it has finished shrinking.
    private var settingsMoveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var delayedCollapseTask: Task<Void, Never>?
    private var dragOpenTask: Task<Void, Never>?
    /// Waits for a click that ended a rename to be over before the keys go back.
    private var keyboardReturnTask: Task<Void, Never>?
    /// Waits for a Mac's minute to pass before its next offer may open the panel.
    private var offerCheckTask: Task<Void, Never>?
    /// No offer opens the panel before this, so the shelf an offer was just accepted
    /// into, or the closing of one just declined, isn't replaced at once by the next.
    private var nextOfferNotBefore = ContinuousClock.now
    /// True while the open shelf has asked Nearby Sharing to look for Macs, for Send To.
    private var isBrowsingForShelf = false
    /// Each Send To still running, by the id its tiles know it by, with the id
    /// `NearbyService` knows it by, for Stop Sending.
    private var sendIDs: [UUID: UUID] = [:]
    /// Sends that finished before `NearbyService.send` returned their id.
    private var finishedSends: Set<UUID> = []
    /// The Send To box beside the open shelf (N5): drop a tile, or something from
    /// another app, on a Mac nearby to send it.
    private let box = NearbyBoxController()
    /// What a drag from another app holds that could go to a Mac, read as the drop
    /// zone opens: anything at all, and any files.
    private var incomingToSend: (any: Bool, files: Bool) = (false, false)
    /// What of the last tile drag could go to a Mac, noted as it started: its drop
    /// on the box can arrive after the drag has ended and the move is cleared.
    private var tileDragToSend: [ShelfItem] = []
    /// True while the Send To box has asked Nearby Sharing to keep looking for Macs.
    private var isBrowsingForBox = false
    private var collapsedAt = ContinuousClock.now

    /// How long the pointer can be away before the panel collapses while a message is showing.
    private let noticeLeaveDelay: Duration = .seconds(3)
    /// Extra room around the expanded panel before leaving it collapses the panel.
    private let leaveMargin: CGFloat = 16
    /// About how long the shape takes to shrink back to notch size. The panel waits
    /// this long after collapsing before it moves to another screen, so the end of the
    /// animation doesn't play out on the new one.
    private let collapseSettleTime: Duration = .milliseconds(500)
    /// How long a drag from another app runs before the drop zone opens, unless it
    /// reaches the notch first. Quick drags, like moving a file between two Finder
    /// windows, are often over by then and never open it.
    private let dragOpenDelay: Duration = .milliseconds(500)
    /// How long before a hover opens the panel the notch starts to swell. Within about
    /// a tenth of a second, the eye reads the two as a single motion.
    private let swellLead: Duration = .milliseconds(100)

    init(store: ShelfStore,
         images: ShelfItemImages,
         copies: CopyKeeper?,
         converter: PDFConverter?,
         compressor: FolderCompressor? = nil,
         quickLook: QuickLookController,
         share: ShareController,
         fileChooser: FileChooser,
         nearby: NearbyService? = nil,
         openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.images = images
        self.quickLook = quickLook
        self.share = share
        self.fileChooser = fileChooser
        self.nearby = nearby
        self.openSettings = openSettings
        dragSource = ShelfDragSource(images: images)
        model = NotchViewModel(store: store, copies: copies, converter: converter, compressor: compressor)
    }

    func start() {
        let panel = NotchPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        let hostingView = NSHostingView(rootView: NotchView(model: model,
                                                            store: store,
                                                            images: images,
                                                            dragSource: dragSource,
                                                            openSettings: { [weak self] in
                                                                self?.openSettingsFromPanel()
                                                            },
                                                            addLink: { [weak self] in
                                                                self?.addLinkFromPanel()
                                                            },
                                                            addFiles: { [weak self] in
                                                                self?.addFilesFromPanel()
                                                            },
                                                            addFolder: { [weak self] in
                                                                self?.addFolderFromPanel()
                                                            },
                                                            pasteable: {
                                                                PasteReader.contents(of: .general)
                                                            },
                                                            paste: { [weak self] contents in
                                                                self?.pasteFromPanel(contents)
                                                            },
                                                            commands: itemCommands,
                                                            pointer: { [weak self] in
                                                                self?.pointerInPanel()
                                                            }))
        hostingView.sizingOptions = []

        let dropView = DropTargetView(frame: .zero)
        dropView.onTargetChanged = { [weak self] targeted in
            self?.model.isDropTargeted = targeted
        }
        dropView.onDragMoved = { [weak self] point in
            self?.model.externalDragMoved(to: point)
        }
        dropView.dropFolder = { [weak self] point in
            self?.model.dropZoneFolder(at: point)
        }
        dropView.onPromisesDropped = { [weak self] promises, folderID in
            self?.model.receivePromisedFiles(promises, intoFolder: folderID)
        }
        dropView.onDrop = { [weak self] items, folderID in
            self?.model.handleDrop(items, intoFolder: folderID)
            self?.dragMonitor.endDrag()
        }
        // The shelf's own tiles, dragged to a new place on it.
        dropView.onTileMoved = { [weak self] point in
            self?.model.tileMoved(to: point)
        }
        dropView.onTileExited = { [weak self] in
            self?.model.tileMoveLeft()
        }
        dropView.tileDrop = { [weak self] point in
            self?.model.tileDrop(at: point)
        }
        dropView.onTileDropped = { [weak self] drop, gliding in
            self?.model.finishTileMove(drop, gliding: gliding)
        }
        dropView.freeSpaceMenu = { [weak self] point in
            self?.freeSpaceMenu(at: point)
        }
        dropView.embed(hostingView)
        panel.contentView = dropView
        self.panel = panel

        layoutPanel()
        panel.orderFrontRegardless()

        model.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        // The two times the panel takes the keys: the link field, and a tile's name
        // being edited. `@Published` reports a change before it's made, so this works
        // from the values it's handed rather than reading the model.
        model.$state.combineLatest(model.$renamingItemID)
            .map { state, renaming in state == .addingLink || renaming != nil }
            .removeDuplicates()
            .sink { [weak self] needsKeyboard in
                if needsKeyboard {
                    self?.takeKeyboard()
                } else {
                    self?.giveKeyboardBack()
                }
            }
            .store(in: &cancellables)
        model.$renamingItemID
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self, weak panel] renaming in
                panel?.endsEditingOnClickElsewhere = renaming
                if !renaming { self?.showNextOfferSoon() }
            }
            .store(in: &cancellables)
        // Cmd-V and Cmd-C go off the moment the shelf closes or the panel takes the keys, and
        // on when the shelf opens under a pointer that's already over it. Pointer
        // moves keep it up to date in between (`pointerMoved`).
        model.$state.combineLatest(model.$renamingItemID)
            .sink { [weak self] state, renaming in
                self?.updateShortcuts(state: state, isRenaming: renaming != nil)
            }
            .store(in: &cancellables)
        shortcuts.onPaste = { [weak self] in self?.pasteFromShortcut() }
        shortcuts.onCopy = { [weak self] in self?.copyFromShortcut() }

        startMouseMonitors()
        startDragMonitor()
        startDragSource()
        observeScreenChanges()
        observeKeyboardLoss(of: panel)
        observeMenus()
        // Sharing held the shelf open. The pointer may have stopped moving outside it,
        // so check where it is now rather than wait for the next move.
        share.onFinished = { [weak self] in
            self?.pointerMoved()
            self?.showNextOfferSoon()
        }
        startNearby()
    }

    // MARK: - Layout

    /// Places the panel on the screen the pointer is on.
    private func layoutPanel() {
        guard let screen = NotchGeometry.screen(containing: NSEvent.mouseLocation)
                ?? NotchGeometry.preferredScreen() else {
            Log.window.error("No screen available for the notch panel")
            return
        }
        place(on: screen)
    }

    /// Moves the panel to the pointer's screen if it isn't there already. There is one
    /// panel that moves rather than one per screen, since the pointer can only be on
    /// one screen at a time. A screen without a notch gets a pill at the top center.
    private func followPointer() {
        guard let geometry,
              let screen = NotchGeometry.screen(containing: NSEvent.mouseLocation),
              // By frame rather than by object, so a screen still counts as the same
              // one if AppKit replaces its NSScreen object.
              screen.frame != geometry.screen.frame else { return }
        place(on: screen)
    }

    /// The pointer in the panel's SwiftUI space: the hosting view fills the panel, and
    /// SwiftUI measures from its top left, while screen points go up from the bottom.
    private func pointerInPanel() -> CGPoint? {
        guard let frame = panel?.frame else { return nil }
        let pointer = NSEvent.mouseLocation
        return CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
    }

    /// Only a collapsed panel moves, and only once it has finished shrinking. An open
    /// one stays put until the pointer leaves it.
    private func followPointerIfSettled() {
        guard model.state == .collapsed, ContinuousClock.now - collapsedAt >= collapseSettleTime else { return }
        followPointer()
    }

    private func place(on screen: NSScreen) {
        guard let panel else { return }
        let geometry = NotchGeometry(screen: screen)
        self.geometry = geometry
        model.notchSize = geometry.notchRect.size
        model.hasNotch = geometry.hasNotch

        panel.setFrame(panelFrame(for: geometry), display: true)
        updateBox()

        Log.window.info("""
            Panel placed. Notch: \(String(describing: geometry.notchRect), privacy: .public), \
            hasNotch: \(geometry.hasNotch), screen: \(screen.localizedName, privacy: .public)
            """)
    }

    /// The panel is fixed at the largest size; SwiftUI animates the shape inside it.
    /// It's bigger than the open shelf, with room for the shadow, and while the shelf
    /// is open all of it takes clicks, the clear part too.
    private func panelFrame(for geometry: NotchGeometry) -> CGRect {
        let size = CGSize(width: model.expandedSize.width + 80,
                          height: model.expandedSize.height + 40)
        return CGRect(x: geometry.notchRect.midX - size.width / 2,
                      y: geometry.screen.frame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.window.info("Screen parameters changed, re-laying out")
                self?.layoutPanel()
            }
        }
    }

    // MARK: - State

    private func apply(_ state: NotchState) {
        // Only take mouse and drag events when there is something to interact with.
        updateMouseEvents(state: state)
        if state == .collapsed { collapsedAt = .now }
        if state != .collapsed { cancelHover() }
        if state != .expanded { cancelDelayedCollapse() }
        // Something on the panel may have ended, so a waiting offer can open now.
        if state == .collapsed || state == .expanded { showNextOfferSoon() }
        updateBrowsing(for: state)
        // `model.state` changes after this; the box reads it.
        DispatchQueue.main.async { [weak self] in self?.updateBox() }
        Log.window.debug("State: \(String(describing: state), privacy: .public)")
    }

    /// Files that moved or went missing since the last look are caught before they're
    /// seen. Run while the hover delay counts down or a drag is on its way, rather than
    /// as the panel opens, so the opening animation never waits on the disk.
    private func prepareToOpen() {
        store.refreshReferences()
    }

    /// The gear in the panel. The shelf stays open, and Settings opens below it.
    private func openSettingsFromPanel() {
        openSettings()
    }

    // MARK: - Settings

    /// Settings is opening on `screen`: the shelf opens there too and stays open until
    /// Settings closes. Returns where the panel's bottom will be, in screen points, so
    /// Settings can sit below it. The panel's window, not the shelf: its clear room
    /// under the shelf takes clicks too, and covered Settings' title bar, close button
    /// and all.
    ///
    /// A shelf open on another display closes there first, and opens on this one once
    /// it has shrunk, as the panel only ever moves while closed.
    func openForSettings(on screen: NSScreen?) -> CGFloat? {
        isSettingsOpen = true
        cancelHover()
        settingsMoveTask?.cancel()
        settingsMoveTask = nil
        guard let target = screen ?? geometry?.screen else { return nil }
        if let geometry, geometry.screen.frame != target.frame {
            switch model.state {
            case .collapsed:
                place(on: target)
                expandForSettings()
            case .expanded:
                model.state = .collapsed
                settingsMoveTask = Task { [weak self, collapseSettleTime] in
                    try? await Task.sleep(for: collapseSettleTime)
                    guard !Task.isCancelled, let self, self.isSettingsOpen,
                          self.model.state == .collapsed else { return }
                    self.settingsMoveTask = nil
                    self.place(on: target)
                    self.expandForSettings()
                }
            case .dropReady, .draggingOut, .addingLink, .offer:
                // Busy with something else; it stays where it is.
                break
            }
        } else {
            expandForSettings()
        }
        return panelFrame(for: NotchGeometry(screen: target)).minY
    }

    private func expandForSettings() {
        guard model.state == .collapsed else { return }
        prepareToOpen()
        model.state = .expanded
    }

    /// Settings closed: the shelf collapses as usual, unless the pointer is over it.
    func settingsClosed() {
        isSettingsOpen = false
        settingsMoveTask?.cancel()
        settingsMoveTask = nil
        pointerMoved()
    }

    // MARK: - Adding from the + menu

    /// "Link": the shelf turns into the link field. A tick later, since this runs
    /// as the menu closes, and the panel shouldn't take the keys while it tracks.
    private func addLinkFromPanel() {
        DispatchQueue.main.async { [weak self] in
            self?.model.beginAddingLink()
        }
    }

    /// "File": the shelf gets out of the way, then the Open dialog opens. What's
    /// chosen goes into the shelf folder that was open, which closing forgets.
    private func addFilesFromPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let folderID = self.model.shownFolder?.id
            self.model.state = .collapsed
            self.fileChooser.choose { [weak self] urls in
                self?.model.addFiles(urls, in: folderID)
            }
        }
    }

    /// "Folder" or "New Folder": a new shelf folder with its name ready to type. A tick
    /// later, like Rename, since the panel takes the keys for the name and shouldn't
    /// while the menu that chose it still tracks the pointer.
    private func addFolderFromPanel() {
        DispatchQueue.main.async { [weak self] in
            self?.model.createFolder()
        }
    }

    /// "Paste": what the menu said is on the clipboard goes on the shelf, which stays
    /// open. A tick later, like the others, since this runs as the menu closes. A
    /// picture's bytes are only read now; the clipboard may have changed since the menu
    /// opened, and then there may be none.
    private func pasteFromPanel(_ contents: Pasteable) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard contents == .image else {
                self.model.paste(contents)
                return
            }
            if let image = PasteReader.image(from: .general) {
                self.model.pasteImage(image)
            } else {
                self.model.showNotice("The picture is no longer on the clipboard")
            }
        }
    }

    /// Cmd-V over the open shelf: whatever the + menu's Paste would add. With nothing
    /// Polka can keep on the clipboard, the system beep, as any app gives when there's
    /// nothing to paste.
    private func pasteFromShortcut() {
        guard model.state == .expanded else { return }
        guard let contents = PasteReader.contents(of: .general) else {
            NSSound.beep()
            return
        }
        Log.input.debug("Cmd-V over the shelf")
        pasteFromPanel(contents)
    }

    /// Cmd-C over the open shelf: the selected tiles onto the clipboard. Nothing
    /// selected, or only files that can't be found, gives the system beep, as an app
    /// does when there's nothing to copy.
    private func copyFromShortcut() {
        guard model.state == .expanded else { return }
        if !model.copySelection() {
            NSSound.beep()
        }
    }

    /// A right-click on the open shelf's free space, between and around the tiles or
    /// on an empty shelf, as on the desktop: a menu with "New Folder" first, as on the
    /// desktop, on the shelf itself (a folder never goes into another), then the +
    /// menu's Paste, named after what's on the clipboard, with its ⌘V. Nothing on the
    /// header, a message or the clear room around the shape. Like a click on free space
    /// (and a right-click on the desktop), it clears the selection.
    private func freeSpaceMenu(at point: CGPoint) -> NSMenu? {
        guard model.state == .expanded, model.gridGeometry.shelfArea.contains(point) else { return nil }
        model.clearSelection()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.canCreateFolder {
            menu.addItem(NSMenuItem(title: "New Folder") { [weak self] in self?.addFolderFromPanel() })
            menu.addItem(.separator())
        }
        menu.addItem(.paste(PasteReader.contents(of: .general)) { [weak self] contents in
            self?.pasteFromPanel(contents)
        })
        return menu
    }

    /// Turns Cmd-V and Cmd-C on or off for where things stand now. `@Published` reports a change
    /// before it's made, so the state and renaming come from the caller when known.
    private func updateShortcuts(state: NotchState? = nil, isRenaming: Bool? = nil) {
        let isOverPanel = geometry.map {
            $0.expandedRect(size: model.expandedSize).contains(NSEvent.mouseLocation)
        } ?? false
        shortcuts.isOn = ShelfShortcuts.isWanted(state: state ?? model.state,
                                                 isRenaming: isRenaming ?? (model.renamingItemID != nil),
                                                 isMenuOpen: isMenuOpen,
                                                 isSharing: share.isSharing,
                                                 isPointerOverPanel: isOverPanel)
    }

    /// Screenshots that just arrived: the next time the panel opens, it shows them.
    /// The open shelf doesn't jump to them while you're using it.
    func reveal(_ ids: Set<ShelfItem.ID>) {
        guard model.state == .collapsed else { return }
        model.reveal(ids)
    }

    /// The link field or a name being edited needs the keys. The panel becomes the key
    /// window, the one that gets typing, but Polka doesn't become the active app (see
    /// `NotchPanel`).
    private func takeKeyboard() {
        guard let panel else { return }
        keyboardReturnTask?.cancel()
        keyboardReturnTask = nil
        panel.acceptsKeyboard = true
        panel.makeKey()
    }

    /// Back to never taking the keys. If the panel still has them, they go back to
    /// the app you were in: taking the key window off screen is what hands them
    /// over, and it comes straight back in the same moment.
    ///
    /// A click elsewhere on the shelf that ended a rename is still going on at this
    /// point, and may yet become a drag or open a menu. Taking the panel off screen
    /// in the middle of it would cut it short, so then the keys go back once it's
    /// over. Until then the panel keeps swallowing Command shortcuts.
    private func giveKeyboardBack() {
        guard let panel, panel.acceptsKeyboard else { return }
        keyboardReturnTask?.cancel()
        keyboardReturnTask = nil
        guard isPressOver else {
            keyboardReturnTask = Task { [weak self] in
                while !Task.isCancelled, self?.isPressOver == false {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { return }
                self?.keyboardReturnTask = nil
                self?.giveKeyboardBack()
            }
            return
        }
        panel.acceptsKeyboard = false
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// No mouse button is held, no tile is being dragged, and no menu is open. While a
    /// menu is up, the app runs in the run loop's tracking mode.
    private var isPressOver: Bool {
        NSEvent.pressedMouseButtons == 0
            && dragSource.current == nil
            && RunLoop.main.currentMode != .eventTracking
    }

    /// A click in another app (or Cmd-Tab) while the link field is up or a tile is
    /// being renamed takes the keys from the panel. You've moved on, so the panel
    /// closes. The link field adds nothing; a new name is kept, as in Finder.
    private func observeKeyboardLoss(of panel: NotchPanel) {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelLostKeyboard() }
        }
    }

    private func panelLostKeyboard() {
        // Not when the panel is giving the keys back itself.
        guard let panel, panel.acceptsKeyboard else { return }
        // With Settings open, the shelf stays open: the field closes, or the name is
        // kept, and the shelf is back as it was.
        let afterwards: NotchState = isSettingsOpen ? .expanded : .collapsed
        if model.state == .addingLink {
            model.state = afterwards
        } else if model.renamingItemID != nil {
            // Ending the edit is what hands the typed name to the tile.
            panel.makeFirstResponder(nil)
            model.state = afterwards
        }
    }

    // MARK: - Opening and inspecting items

    /// Each one but Copy and Share collapses the panel first, so it isn't covering what
    /// opens. The files are worked out before that, since collapsing clears the selection.
    private var itemCommands: ShelfItemCommands {
        ShelfItemCommands(open: { [weak self] in self?.openItem($0) },
                          quickLook: { [weak self] in self?.quickLookItems(from: $0) },
                          showInfo: { [weak self] in self?.showInfoForItems(from: $0) },
                          copy: { [weak self] in self?.model.copy(from: $0) },
                          share: { [weak self] in self?.shareItems(from: $0, pointingAt: $1, $2) },
                          sendTargets: { [weak self] in self?.sendTargets(for: $0) },
                          send: { [weak self] in self?.send(from: $0, to: $1) },
                          stopSending: { [weak self] in self?.model.stopSending($0) },
                          moveDestinations: { [weak self] in self?.model.moveDestinations(for: $0) ?? [] },
                          move: { [weak self] in self?.model.move(from: $0, toFolder: $1) })
    }

    /// Double-click. A file that can't be found does nothing, as it can't be dragged.
    /// Text has nothing to open, so it shows in Quick Look, on its own. A shelf folder
    /// opens in the panel itself, which stays open.
    private func openItem(_ id: ShelfItem.ID) {
        if let item = model.item(id), item.kind == .text {
            show([item])
            return
        }
        if let item = model.item(id), item.isShelfFolder {
            // A tick later: chosen from the menu, the menu is still closing.
            DispatchQueue.main.async { [weak self] in self?.model.openFolder(id) }
            return
        }
        guard let url = model.urlToOpen(id) else { return }
        model.state = .collapsed
        if !ItemOpener.open(url) {
            model.showNotice("Couldn't open \(url.lastPathComponent)")
        }
    }

    private func quickLookItems(from id: ShelfItem.ID) {
        show(model.itemsToShow(from: id))
    }

    /// Quick Look shows files themselves, and text as a page of text, from a file
    /// written for it (`TextPreviewFile`).
    private func show(_ items: [ShelfItem]) {
        let files = items.compactMap { item -> URL? in
            guard case .text(let text) = item.source else { return item.urlToOpen() }
            return TextPreviewFile.write(text, named: item.displayName, id: item.id)
        }
        guard !files.isEmpty else { return }
        model.state = .collapsed
        quickLook.show(files)
    }

    private func showInfoForItems(from id: ShelfItem.ID) {
        let files = model.filesToShow(from: id)
        guard !files.isEmpty else { return }
        model.state = .collapsed
        if !ItemOpener.showInfo(for: files) {
            model.showNotice("Couldn't open Get Info in Finder")
        }
    }

    /// The shelf stays open, since the popover points at the tile: like a menu, it
    /// holds the shelf open until it closes, and so does the service picked from it.
    /// Shown a tick later, once the menu that chose it has gone.
    private func shareItems(from id: ShelfItem.ID, pointingAt view: NSView, _ area: NSRect) {
        let objects = ShareController.objects(for: model.itemsToShare(from: id))
        guard !objects.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.state == .expanded else { return }
            self.share.share(objects, from: view, at: area)
            self.updateShortcuts()
        }
    }

    // MARK: - Hover

    private func startMouseMonitors() {
        // Pointer over other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            mouseMonitors.append(global)
        }
        // Pointer over Polka's own panel (when it accepts mouse events).
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func pointerMoved() {
        defer {
            updateMouseEvents()
            updateShortcuts()
        }
        followPointerIfSettled()
        guard let geometry else { return }
        let point = NSEvent.mouseLocation

        switch model.state {
        case .collapsed:
            if geometry.hoverRect(area: settings.hoverArea).contains(point) {
                scheduleExpand()
            } else {
                cancelHover()
            }
        case .expanded:
            if model.renamingItemID != nil || isMenuOpen || share.isSharing || isSettingsOpen {
                // The shelf stays open while you type a name, wherever the pointer
                // goes, as the link field does. Return, Esc or a click ends it.
                // Likewise while a menu is open: choosing or dismissing it ends that,
                // and the next move away collapses the shelf as usual. And while the
                // share popover, or the service picked from it, is up, or Settings.
                cancelDelayedCollapse()
            } else if isPointerNearPanel(geometry) {
                cancelDelayedCollapse()
            } else if model.notice != nil {
                scheduleDelayedCollapse()
            } else {
                model.state = .collapsed
            }
        case .dropReady:
            // A mouse-moved event means no button is held, so any drag is over.
            dragMonitor.endDrag()
        case .draggingOut:
            // The panel can't reopen until the drag ends.
            break
        case .addingLink:
            // The field stays while you type, wherever the pointer goes. A click
            // elsewhere closes it (`panelLostKeyboard`).
            break
        case .offer:
            // An offer stays until it's answered, wherever the pointer goes.
            break
        }
    }

    /// Waits for the hover delay from Settings (the accidental-open guard), then opens
    /// the panel if the pointer is still there.
    ///
    /// The notch starts to swell `swellLead` before the panel opens, not when the
    /// pointer arrives. Started any earlier, the swell finishes and sits still before
    /// the panel follows, which reads as two separate steps. This close, the swell
    /// carries straight into the opening as one motion. The total wait is unchanged.
    private func scheduleExpand() {
        guard hoverTask == nil else { return }
        prepareToOpen()
        let delay = Duration.milliseconds(settings.hoverDelay)
        let lead = min(swellLead, delay)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay - lead)
            guard !Task.isCancelled else { return }
            self?.swellIfStillHovering()
            try? await Task.sleep(for: lead)
            guard !Task.isCancelled else { return }
            self?.expandIfStillHovering()
        }
    }

    private func swellIfStillHovering() {
        guard let geometry, model.state == .collapsed,
              geometry.hoverRect(area: settings.hoverArea).contains(NSEvent.mouseLocation) else { return }
        model.isAboutToOpen = true
    }

    private func expandIfStillHovering() {
        hoverTask = nil
        guard let geometry, model.state == .collapsed,
              geometry.hoverRect(area: settings.hoverArea).contains(NSEvent.mouseLocation) else {
            cancelHover()
            return
        }
        model.state = .expanded
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
        // Only when it changes: this runs on every mouse move away from the notch.
        if model.isAboutToOpen {
            model.isAboutToOpen = false
        }
    }

    /// The panel takes clicks only while the shelf is bigger than the notch. And while
    /// Settings holds the shelf open with the pointer away, not even then: the panel's
    /// clear room around the shelf would swallow clicks meant for the windows under it.
    /// The pointer coming back near the shelf turns clicks on again before it can get
    /// there, since leaving and nearing are both mouse moves.
    private func updateMouseEvents(state: NotchState? = nil) {
        guard let panel else { return }
        let state = state ?? model.state
        var ignores = state.isAtNotchSize
        if !ignores, state == .expanded, isSettingsOpen, let geometry, !isPointerNearPanel(geometry) {
            ignores = true
        }
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
    }

    // MARK: - Leaving while a message is showing

    private func isPointerNearPanel(_ geometry: NotchGeometry) -> Bool {
        let shelf = geometry.expandedRect(size: model.expandedSize).insetBy(dx: -leaveMargin, dy: -leaveMargin)
        return box.reaches(NSEvent.mouseLocation, from: shelf)
    }

    /// Runs on a timer because the pointer may stop moving once it has left.
    /// The message stays in the model, so it is still there on the next hover.
    private func scheduleDelayedCollapse() {
        guard delayedCollapseTask == nil else { return }
        delayedCollapseTask = Task { [weak self, noticeLeaveDelay] in
            try? await Task.sleep(for: noticeLeaveDelay)
            guard !Task.isCancelled else { return }
            self?.collapseIfStillAway()
        }
    }

    private func collapseIfStillAway() {
        delayedCollapseTask = nil
        guard let geometry, model.state == .expanded, model.renamingItemID == nil,
              !isMenuOpen, !share.isSharing, !isSettingsOpen,
              !isPointerNearPanel(geometry) else { return }
        model.state = .collapsed
    }

    private func cancelDelayedCollapse() {
        delayedCollapseTask?.cancel()
        delayedCollapseTask = nil
    }

    // MARK: - Menus

    /// AppKit announces every menu Polka opens, pop-up or right-click, when it starts
    /// and stops following the pointer. While one is open, mouse moves still reach
    /// `pointerMoved`, which would otherwise collapse the shelf under the menu.
    private func observeMenus() {
        let changes: [(Notification.Name, Bool)] = [(NSMenu.didBeginTrackingNotification, true),
                                                     (NSMenu.didEndTrackingNotification, false)]
        menuObservers = changes.map { name, isOpen in
            // Run as it's posted, which is always on the main thread, so the flag is
            // set before the next mouse move is handled.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuOpen = isOpen
                    self?.updateShortcuts()
                    if !isOpen { self?.showNextOfferSoon() }
                }
            }
        }
    }

    // MARK: - Global drag

    private func startDragMonitor() {
        dragMonitor.onDragStarted = { [weak self] in
            self?.dragStarted()
        }
        dragMonitor.onDragMoved = { [weak self] in
            self?.dragMoved()
        }
        dragMonitor.onDragEnded = { [weak self] in
            self?.cancelDragOpen()
            self?.finishDrag()
            self?.showNextOfferSoon()
        }
        dragMonitor.start()
    }

    /// A drag from another app has started. The drop zone doesn't open right away,
    /// which was distracting for drags that have nothing to do with Polka. It opens
    /// as soon as the drag reaches the notch, or once it has run for `dragOpenDelay`.
    private func dragStarted() {
        guard model.state != .dropReady else { return }
        // A drop opens the shelf, so get it ready while the drag is on its way.
        prepareToOpen()
        cancelDragOpen()
        dragOpenTask = Task { [weak self, dragOpenDelay] in
            try? await Task.sleep(for: dragOpenDelay)
            guard !Task.isCancelled else { return }
            self?.openDropZone()
        }
        // The drag may have started right at the notch.
        dragMoved()
    }

    /// Called many times a second while a drag runs. Mouse-moved events don't arrive
    /// during a drag, so this is where the panel follows the pointer and notices the
    /// drag reaching the notch.
    private func dragMoved() {
        switch model.state {
        case .dropReady:
            // The drop zone moves with the drag if it crosses to another screen.
            followPointer()
        case .collapsed, .expanded:
            followPointerIfSettled()
            if let geometry, geometry.hoverRect(area: settings.hoverArea).contains(NSEvent.mouseLocation) {
                openDropZone()
            }
        case .draggingOut, .addingLink, .offer:
            break
        }
    }

    private func openDropZone() {
        cancelDragOpen()
        guard dragMonitor.isDragging, model.state == .collapsed || model.state == .expanded else { return }
        // The drop zone opens on the screen the drag is on.
        followPointer()
        let toSend = DropReceiver.itemsToSend(from: NSPasteboard(name: .drag))
        incomingToSend = (!toSend.isEmpty, toSend.contains { $0.kind == .file })
        model.state = .dropReady
    }

    private func cancelDragOpen() {
        dragOpenTask?.cancel()
        dragOpenTask = nil
    }

    private func startDragSource() {
        // Every tile drag lifts the tiles out of the grid. A drop back on the shelf
        // moves them; a drop anywhere else leaves them where they were.
        dragSource.onWillStart = { [weak self] contents in
            guard let self else { return }
            self.dragMonitor.beginOwnDrag()
            self.model.beginTileMove(contents)
            self.tileDragToSend = self.model.tileMoveItemsToSend
            self.updateBox()
        }
        dragSource.onMoved = { [weak self] _ in
            guard let self, let geometry = self.geometry else { return }
            let panelRect = geometry.expandedRect(size: self.model.expandedSize)
            // On the way to the Send To box, and over it, the shelf stays open. The
            // pointer itself, rather than the point AppKit reports for the picture.
            self.model.dragOutMoved(isInsidePanel: self.box.reaches(NSEvent.mouseLocation, from: panelRect))
        }
        dragSource.onEnded = { [weak self] in
            // Ended over the box: its drop may not have been read yet.
            if self?.box.contains(NSEvent.mouseLocation) == true { self?.box.awaitDrop() }
            self?.dragMonitor.endOwnDrag()
            // A drop on the shelf has already moved the tiles by now.
            self?.model.endTileMove()
            self?.model.dragOutEnded()
            // A drag out shrinks the shelf; with Settings open, it opens again.
            if self?.isSettingsOpen == true, self?.model.state == .collapsed {
                self?.model.state = .expanded
            }
            // No mouse-moved events arrive during a drag, so check where the pointer ended up.
            self?.pointerMoved()
            self?.showNextOfferSoon()
            self?.updateBox()
        }
    }

    /// After a drag ends: stay expanded if the pointer is over the panel, otherwise collapse.
    /// A successful drop has already switched the state to expanded.
    private func finishDrag() {
        guard model.state == .dropReady, let geometry else { return }
        // Ended over the Send To box: its drop may not have been read yet.
        if box.contains(NSEvent.mouseLocation) { box.awaitDrop() }
        let area = geometry.expandedRect(size: model.expandedSize)
        // With Settings open, the shelf stays open after the drag too.
        model.state = isSettingsOpen || area.contains(NSEvent.mouseLocation) ? .expanded : .collapsed
    }

    // MARK: - Nearby Sharing

    /// How long after an offer is answered before the next one may open the panel.
    private let offerPause: Duration = .milliseconds(1500)

    private func startNearby() {
        guard let nearby else { return }
        model.onOfferAnswered = { [weak self] offer, answer in
            self?.offerAnswered(offer, answer)
        }
        nearby.onReceived = { [weak self] items, senderName, withoutAsking in
            self?.received(items, from: senderName, withoutAsking: withoutAsking)
        }
        nearby.onRememberedOfferTooLarge = { [weak self] senderName in
            self?.model.showNotice("There isn't enough space on this Mac for what \(senderName) sent")
        }
        nearby.onReceiveFailed = { [weak self] senderName, cancelledByThem in
            self?.model.receiveNearbyFailed(from: senderName, cancelledByThem: cancelledByThem)
        }
        model.onStopSending = { [weak self] transfer in
            self?.stopSending(transfer)
        }
        model.onCancelReceiving = { [weak self] id in
            self?.nearby?.cancelReceiving(id)
        }
        box.onDrop = { [weak self] items, peerID in
            self?.sendFromBox(items, to: peerID)
        }
        box.tilesToSend = { [weak self] in
            guard let self else { return [] }
            let dragged = self.model.tileMoveItemsToSend
            // The drag may already have ended.
            return dragged.isEmpty ? self.tileDragToSend : dragged
        }
        // The Macs the box lists stay found while it's up, whatever the shelf does.
        box.onShownChange = { [weak self] shown in
            guard let self, let nearby = self.nearby, shown != self.isBrowsingForBox else { return }
            self.isBrowsingForBox = shown
            if shown { nearby.beginBrowsing() } else { nearby.endBrowsing() }
        }
        box.model.onStop = { [weak self] transfer in
            self?.stopSending(transfer)
        }
        // `@Published` reports a change before it's made, so the list is read a tick later.
        nearby.$peers
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateBox() }
            }
            .store(in: &cancellables)
        nearby.$receiving
            .map { $0.filter { $0.totalBytes > 0 } }
            .removeDuplicates()
            .sink { [weak self] receiving in self?.model.nearbyReceiving = receiving }
            .store(in: &cancellables)
        // `@Published` reports a change before it's made, so the list is read a tick later.
        nearby.$offers
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.offersChanged() }
            }
            .store(in: &cancellables)
    }

    private func offersChanged() {
        guard let nearby else { return }
        // The offer on screen went away unanswered: it timed out, the other Mac
        // withdrew it, or Nearby Sharing was turned off.
        if model.state == .offer, let shown = model.shownOffer,
           !nearby.offers.contains(where: { $0.id == shown.id }) {
            model.shownOffer = nil
            closeOffer()
        }
        showNextOffer()
    }

    /// Tiles from a remembered Mac arrived while something was going on on the panel.
    /// It opens to show them once that ends.
    private var arrivalWaiting = false

    private func received(_ items: [NearbyReceivedItem], from senderName: String, withoutAsking: Bool) {
        model.receiveNearby(items, from: senderName, withoutAsking: withoutAsking)
        guard withoutAsking else { return }
        arrivalWaiting = true
        showNextOffer()
    }

    /// Opens the shelf by itself to show what a remembered Mac sent (NS-18), scrolled
    /// to it under the message naming the sender, as an offer opens the panel: never
    /// in the middle of something, and without taking the keys. It closes 3 s later
    /// unless the pointer comes to it. An open shelf only scrolls to it.
    private func showArrival() {
        guard arrivalWaiting, isFreeToOpenByItself else { return }
        arrivalWaiting = false
        guard model.state == .collapsed else { return }
        followPointer()
        model.state = .expanded
        Log.window.info("Showing what a remembered Mac sent")
        if let geometry, !isPointerNearPanel(geometry) { scheduleDelayedCollapse() }
    }

    /// Nothing is going on on the panel that opening it by itself would break: a drag,
    /// a tile being moved, a rename, the link field, an open menu, Share or an offer.
    private var isFreeToOpenByItself: Bool {
        (model.state == .collapsed || model.state == .expanded)
            && model.renamingItemID == nil && model.tileMove == nil
            && !isMenuOpen && !dragMonitor.isDragging && !share.isSharing
    }

    /// After whatever just ended has settled.
    private func showNextOfferSoon() {
        guard nearby?.offers.isEmpty == false || arrivalWaiting else { return }
        DispatchQueue.main.async { [weak self] in self?.showNextOffer() }
    }

    /// Opens the panel on the next waiting offer, if one may open it now (NS-17): never
    /// in the middle of a drag, a tile move, a rename, the link field, an open menu or
    /// Share, and never over another offer. A Mac whose offer opened the panel within
    /// the last minute waits for the minute to pass. Like a drag arriving, the panel
    /// doesn't take the keys and Polka doesn't become the active app.
    private func showNextOffer() {
        offerCheckTask?.cancel()
        offerCheckTask = nil
        showArrival()
        guard let nearby, !nearby.offers.isEmpty else { return }
        let now = ContinuousClock.now
        if now < nextOfferNotBefore {
            checkOffersAgain(after: nextOfferNotBefore - now)
            return
        }
        guard isFreeToOpenByItself else { return }
        let next = nearby.nextOfferToShow()
        if let id = next.id, let offer = nearby.offers.first(where: { $0.id == id }) {
            // A closed panel opens on the screen the pointer is on, as the drop zone does.
            if model.state == .collapsed { followPointer() }
            nearby.showingOffer(id)
            model.shownOffer = offer
            model.state = .offer
            Log.window.info("Showing an offer")
        } else if let date = next.checkAgainAt {
            checkOffersAgain(after: .seconds(max(date.timeIntervalSinceNow, 0.1)))
        }
    }

    private func checkOffersAgain(after delay: Duration) {
        offerCheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.showNextOffer()
        }
    }

    private func offerAnswered(_ offer: NearbyIncomingOffer, _ answer: NotchViewModel.OfferAnswer) {
        nextOfferNotBefore = .now + offerPause
        switch answer {
        case .accept:
            if nearby?.accept(offer.id) == .notEnoughSpace {
                model.showNotice("There isn't enough space on this Mac for what \(offer.senderName) shared")
            }
            // The view grows back into the shelf, where the items land as they arrive.
            model.state = .expanded
        case .decline:
            nearby?.decline(offer.id)
            closeOffer()
        case .block:
            nearby?.decline(offer.id, block: true)
            closeOffer()
        }
    }

    // MARK: Send To

    /// Nearby Macs are looked for only while the shelf is open, so Send To has them
    /// ready, and not while it's closed: looking keeps the Wi-Fi radio hopping to the
    /// peer-to-peer channel, which costs battery.
    private func updateBrowsing(for state: NotchState) {
        // The drop zone too, for the Send To box beside it.
        let wants = state == .expanded || state == .addingLink || state == .offer || state == .dropReady
        guard let nearby, wants != isBrowsingForShelf else { return }
        isBrowsingForShelf = wants
        if wants {
            nearby.beginBrowsing()
        } else {
            nearby.endBrowsing()
        }
    }

    /// What Send To on `id` lists as it opens: the Macs found nearby that told their
    /// names, or a note saying why there are none. Nil while Nearby Sharing is off. A
    /// Mac on an older Polka is listed but can't be chosen when it can't take what's
    /// being sent: anything at all on N1's, files on N2's.
    private func sendTargets(for id: ShelfItem.ID) -> [NearbySendTarget]? {
        guard let nearby, nearby.isEnabled else { return nil }
        switch nearby.status {
        case .noLocalNetwork:
            return [NearbySendTarget(peerID: nil, title: "Local Network Access Is Off")]
        case .failed:
            return [NearbySendTarget(peerID: nil, title: "Nearby Sharing Isn't Working")]
        case .off, .starting, .on:
            break
        }
        let peers = nearby.peers
        guard !peers.isEmpty else {
            let isStillLooking = nearby.browsingSince.map { -$0.timeIntervalSinceNow < 5 } ?? true
            return [NearbySendTarget(peerID: nil, title: isStillLooking ? "Looking for Macs…" : "No Macs Nearby")]
        }
        let hasFiles = model.itemsToSend(from: id).contains { $0.kind == .file }
        return NearbySendTarget.list(peers, hasFiles: hasFiles)
    }

    /// Send To > a Mac. The shelf stays open, as for Copy and Share, and the sending
    /// tiles say how it's going.
    private func send(from id: ShelfItem.ID, to peerID: String) {
        let items = model.itemsToSend(from: id)
        guard !items.isEmpty else { return }
        startSend(items, showingOn: items.map(\.id), to: peerID, inBox: false)
    }

    /// A drop on a Mac in the Send To box (N5): tiles from the shelf, which say how it's
    /// going as with Send To, or things from another app, which go straight to the Mac
    /// without landing on the shelf, so the drop zone closes. The box shows how it's
    /// going either way.
    private func sendFromBox(_ items: [ShelfItem], to peerID: String) {
        Log.window.info("Sending \(items.count, privacy: .public) item(s) dropped on the Send To box")
        let onShelf = Set(store.items.map(\.id))
        let tileIDs = items.map(\.id).filter(onShelf.contains)
        if model.state == .dropReady { dragMonitor.endDrag() }
        startSend(items, showingOn: tileIDs, to: peerID, inBox: true)
    }

    private func startSend(_ items: [ShelfItem], showingOn ids: [ShelfItem.ID], to peerID: String, inBox: Bool) {
        guard let nearby else { return }
        guard let peer = nearby.peers.first(where: { $0.id == peerID }) else {
            model.showNotice("That Mac is no longer nearby")
            return
        }
        let transfer = UUID()
        if inBox { box.addSend(transfer, to: NearbyBoxModel.mac(peer, carryingFiles: false)) }
        let started = nearby.send(items, to: peerID) { [weak self] status in
            guard let self else { return }
            if !ids.isEmpty {
                self.model.showSending(Self.sendingLabel(status, to: peer.name), isFinished: status.isFinished,
                                       on: ids, transfer: transfer)
            }
            if inBox { self.box.update(transfer, status) }
            if status.isFinished {
                self.sendIDs[transfer] = nil
                self.finishedSends.insert(transfer)
            }
            switch status {
            case .failed(.tooLarge):
                self.model.showNotice("That's more than 1 GB, too much to send at once")
            case .failed(.unreadable):
                self.model.showNotice("A file couldn't be read, so nothing more was sent")
            default:
                break
            }
        }
        if let started {
            // Unless it finished already, before `send` returned.
            if finishedSends.remove(transfer) == nil { sendIDs[transfer] = started }
        } else {
            if inBox { box.update(transfer, .failed(.unreachable)) }
            model.showNotice("Couldn't send to \(peer.name)")
        }
    }

    /// Shows or hides the Send To box beside the open shelf: while a tile that can be
    /// sent is dragged on it, or the drop zone is open for something from another app
    /// that can, with Nearby Sharing on and a Mac nearby. And while what was dropped on
    /// it is being sent, whatever the shelf does.
    private func updateBox() {
        guard let nearby, let geometry else { return }
        let tiles = model.state == .expanded ? model.tileMoveItemsToSend : []
        let incoming = model.state == .dropReady && incomingToSend.any
        let carriesFiles = incoming ? incomingToSend.files : tiles.contains { $0.kind == .file }
        let peers = nearby.isEnabled ? nearby.peers : []
        let macs = peers.map { NearbyBoxModel.mac($0, carryingFiles: carriesFiles) }
        if box.model.macs != macs { box.model.macs = macs }
        let isDragging = (!tiles.isEmpty || incoming) && !macs.isEmpty
        if box.model.isDragging != isDragging { box.model.isDragging = isDragging }
        box.place(beside: geometry.expandedRect(size: model.expandedSize),
                  top: geometry.screen.frame.maxY - geometry.notchRect.height)
    }

    /// Stop Sending: the Send To a tile is in.
    private func stopSending(_ transfer: UUID) {
        guard let id = sendIDs[transfer] else { return }
        nearby?.cancelSending(id)
    }

    /// What a sending tile's detail line says.
    private static func sendingLabel(_ status: NearbyOutgoingSession.Status, to name: String) -> String {
        switch status {
        case .connecting, .waiting: return "Waiting for \(name)…"
        case let .sending(fraction): return "Sending \(Int(fraction * 100))%"
        case .sent: return "Sent"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .failed(.tooOld): return "\(name) needs a newer Polka"
        case .failed(.unreachable), .failed(.wrongMac): return "Couldn't reach \(name)"
        case .failed(.tooLarge): return "Over 1 GB"
        case .failed(.unreadable): return "Couldn't read the file"
        case .failed(.nothingToSend): return "Nothing to send"
        }
    }

    /// The offer view goes: the panel collapses, unless Settings holds the shelf open.
    private func closeOffer() {
        guard model.state == .offer else { return }
        model.state = isSettingsOpen ? .expanded : .collapsed
    }
}
