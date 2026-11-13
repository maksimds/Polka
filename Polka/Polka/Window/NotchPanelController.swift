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
    private let model: NotchViewModel
    private let dragMonitor = GlobalDragMonitor()
    private let dragSource: ShelfDragSource
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
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var delayedCollapseTask: Task<Void, Never>?
    private var dragOpenTask: Task<Void, Never>?
    /// Waits for a click that ended a rename to be over before the keys go back.
    private var keyboardReturnTask: Task<Void, Never>?
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
         quickLook: QuickLookController,
         share: ShareController,
         fileChooser: FileChooser,
         openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.images = images
        self.quickLook = quickLook
        self.share = share
        self.fileChooser = fileChooser
        self.openSettings = openSettings
        dragSource = ShelfDragSource(images: images)
        model = NotchViewModel(store: store, copies: copies, converter: converter)
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
        dropView.onPromisesDropped = { [weak self] promises in
            self?.model.receivePromisedFiles(promises)
        }
        dropView.onDrop = { [weak self] items in
            self?.model.handleDrop(items)
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
            self?.model.finishTileMove(at: drop.target, gliding: gliding)
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
            .sink { [weak panel] renaming in panel?.endsEditingOnClickElsewhere = renaming }
            .store(in: &cancellables)

        startMouseMonitors()
        startDragMonitor()
        startDragSource()
        observeScreenChanges()
        observeKeyboardLoss(of: panel)
        observeMenus()
        // Sharing held the shelf open. The pointer may have stopped moving outside it,
        // so check where it is now rather than wait for the next move.
        share.onFinished = { [weak self] in self?.pointerMoved() }
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

        // The panel is fixed at the largest size; SwiftUI animates the shape inside it.
        let size = CGSize(width: model.expandedSize.width + 80,
                          height: model.expandedSize.height + 40)
        let origin = CGPoint(x: geometry.notchRect.midX - size.width / 2,
                             y: screen.frame.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        Log.window.info("""
            Panel placed. Notch: \(String(describing: geometry.notchRect), privacy: .public), \
            hasNotch: \(geometry.hasNotch), screen: \(screen.localizedName, privacy: .public)
            """)
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
        panel?.ignoresMouseEvents = state.isAtNotchSize
        if state == .collapsed { collapsedAt = .now }
        if state != .collapsed { cancelHover() }
        if state != .expanded { cancelDelayedCollapse() }
        Log.window.debug("State: \(String(describing: state), privacy: .public)")
    }

    /// Expired items never show, even if the expiry timer ran late, and files that
    /// moved or went missing since the last look are caught before they're seen.
    /// Run while the hover delay counts down or a drag is on its way, rather than as
    /// the panel opens, so the opening animation never waits on the disk.
    private func prepareToOpen() {
        store.removeExpired()
        store.refreshReferences()
    }

    /// The gear in the panel: the shelf gets out of the way, then Settings opens.
    private func openSettingsFromPanel() {
        model.state = .collapsed
        openSettings()
    }

    // MARK: - Adding from the + menu

    /// "Link": the shelf turns into the link field. A tick later, since this runs
    /// as the menu closes, and the panel shouldn't take the keys while it tracks.
    private func addLinkFromPanel() {
        DispatchQueue.main.async { [weak self] in
            self?.model.beginAddingLink()
        }
    }

    /// "File": the shelf gets out of the way, then the Open dialog opens.
    private func addFilesFromPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.state = .collapsed
            self.fileChooser.choose { [weak self] urls in
                self?.model.addFiles(urls)
            }
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
        if model.state == .addingLink {
            model.state = .collapsed
        } else if model.renamingItemID != nil {
            // Ending the edit is what hands the typed name to the tile.
            panel.makeFirstResponder(nil)
            model.state = .collapsed
        }
    }

    // MARK: - Opening and inspecting items

    /// Each one but Copy and Share collapses the panel first, so it isn't covering what
    /// opens. The files are worked out before that, since collapsing clears the selection.
    private var itemCommands: ShelfItemCommands {
        ShelfItemCommands(open: { [weak self] in self?.openItem($0) },
                          quickLook: { [weak self] in self?.quickLookItems(from: $0) },
                          showInfo: { [weak self] in self?.showInfoForItems(from: $0) },
                          copy: { [weak self] in self?.model.copyText($0) },
                          share: { [weak self] in self?.shareItems(from: $0, pointingAt: $1, $2) })
    }

    /// Double-click. A file that can't be found does nothing, as it can't be dragged.
    /// Text has nothing to open, so it shows in Quick Look, on its own.
    private func openItem(_ id: ShelfItem.ID) {
        if let item = model.item(id), item.kind == .text {
            show([item])
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
            if model.renamingItemID != nil || isMenuOpen || share.isSharing {
                // The shelf stays open while you type a name, wherever the pointer
                // goes, as the link field does. Return, Esc or a click ends it.
                // Likewise while a menu is open: choosing or dismissing it ends that,
                // and the next move away collapses the shelf as usual. And while the
                // share popover, or the service picked from it, is up.
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

    // MARK: - Leaving while a message is showing

    private func isPointerNearPanel(_ geometry: NotchGeometry) -> Bool {
        geometry.expandedRect(size: model.expandedSize)
            .insetBy(dx: -leaveMargin, dy: -leaveMargin)
            .contains(NSEvent.mouseLocation)
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
              !isMenuOpen, !share.isSharing, !isPointerNearPanel(geometry) else { return }
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
                MainActor.assumeIsolated { self?.isMenuOpen = isOpen }
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
        case .draggingOut, .addingLink:
            break
        }
    }

    private func openDropZone() {
        cancelDragOpen()
        guard dragMonitor.isDragging, model.state == .collapsed || model.state == .expanded else { return }
        // The drop zone opens on the screen the drag is on.
        followPointer()
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
            self?.dragMonitor.beginOwnDrag()
            self?.model.beginTileMove(contents)
        }
        dragSource.onMoved = { [weak self] point in
            guard let self, let geometry = self.geometry else { return }
            let panelRect = geometry.expandedRect(size: self.model.expandedSize)
            self.model.dragOutMoved(isInsidePanel: panelRect.contains(point))
        }
        dragSource.onEnded = { [weak self] in
            self?.dragMonitor.endOwnDrag()
            // A drop on the shelf has already moved the tiles by now.
            self?.model.endTileMove()
            self?.model.dragOutEnded()
            // No mouse-moved events arrive during a drag, so check where the pointer ended up.
            self?.pointerMoved()
        }
    }

    /// After a drag ends: stay expanded if the pointer is over the panel, otherwise collapse.
    /// A successful drop has already switched the state to expanded.
    private func finishDrag() {
        guard model.state == .dropReady, let geometry else { return }
        let area = geometry.expandedRect(size: model.expandedSize)
        model.state = area.contains(NSEvent.mouseLocation) ? .expanded : .collapsed
    }
}
