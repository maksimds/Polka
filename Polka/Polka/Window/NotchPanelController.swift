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
    private let model: NotchViewModel
    private let dragMonitor = GlobalDragMonitor()
    private let dragSource: ShelfDragSource
    /// Read on every use, so a change in Settings applies right away.
    private let settings = ShelfSettings()
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?

    private var mouseMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var delayedCollapseTask: Task<Void, Never>?
    private var dragOpenTask: Task<Void, Never>?
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
         quickLook: QuickLookController,
         openSettings: @escaping @MainActor () -> Void) {
        self.store = store
        self.images = images
        self.quickLook = quickLook
        self.openSettings = openSettings
        dragSource = ShelfDragSource(images: images)
        model = NotchViewModel(store: store, copies: copies)
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

        startMouseMonitors()
        startDragMonitor()
        startDragSource()
        observeScreenChanges()
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

    // MARK: - Opening and inspecting items

    /// Each one collapses the panel first, so it isn't covering what opens. The files
    /// are worked out before that, since collapsing clears the selection.
    private var itemCommands: ShelfItemCommands {
        ShelfItemCommands(open: { [weak self] in self?.openItem($0) },
                          quickLook: { [weak self] in self?.quickLookItems(from: $0) },
                          showInfo: { [weak self] in self?.showInfoForItems(from: $0) })
    }

    /// Double-click. A file that can't be found does nothing, as it can't be dragged.
    private func openItem(_ id: ShelfItem.ID) {
        guard let url = model.urlToOpen(id) else { return }
        model.state = .collapsed
        if !ItemOpener.open(url) {
            model.showNotice("Couldn't open \(url.lastPathComponent)")
        }
    }

    private func quickLookItems(from id: ShelfItem.ID) {
        let files = model.filesToShow(from: id)
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
            if isPointerNearPanel(geometry) {
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
        guard let geometry, model.state == .expanded, !isPointerNearPanel(geometry) else { return }
        model.state = .collapsed
    }

    private func cancelDelayedCollapse() {
        delayedCollapseTask?.cancel()
        delayedCollapseTask = nil
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
        case .draggingOut:
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
