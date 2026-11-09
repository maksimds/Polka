import AppKit
import Combine
import SwiftUI

/// Owns the notch panel and drives its state:
/// hover to expand, leave to collapse, any drag on screen opens it as a drop target.
@MainActor
final class NotchPanelController {
    private let store: ShelfStore
    private let model: NotchViewModel
    private let dragMonitor = GlobalDragMonitor()
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?

    private var mouseMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var delayedCollapseTask: Task<Void, Never>?

    /// How long the pointer must rest on the notch before it expands (accidental-open guard).
    private let hoverDelay: Duration = .milliseconds(150)
    /// How long the pointer can be away before the panel collapses while a message is showing.
    private let noticeLeaveDelay: Duration = .seconds(3)
    /// Extra room around the expanded panel before leaving it collapses the panel.
    private let leaveMargin: CGFloat = 16

    init(store: ShelfStore) {
        self.store = store
        model = NotchViewModel(store: store)
    }

    func start() {
        let panel = NotchPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        let hostingView = NSHostingView(rootView: NotchView(model: model, store: store))
        hostingView.sizingOptions = []

        let dropView = DropTargetView(frame: .zero)
        dropView.onTargetChanged = { [weak self] targeted in
            self?.model.isDropTargeted = targeted
        }
        dropView.onDrop = { [weak self] items in
            self?.model.handleDrop(items)
            self?.dragMonitor.endDrag()
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
        observeScreenChanges()
    }

    // MARK: - Layout

    private func layoutPanel() {
        guard let panel, let screen = NotchGeometry.preferredScreen() else {
            Log.window.error("No screen available for the notch panel")
            return
        }
        let geometry = NotchGeometry(screen: screen)
        self.geometry = geometry
        model.notchSize = geometry.notchRect.size

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
        panel?.ignoresMouseEvents = (state == .collapsed)
        if state != .collapsed { cancelHover() }
        if state != .expanded { cancelDelayedCollapse() }
        Log.window.debug("State: \(String(describing: state), privacy: .public)")
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
        guard let geometry else { return }
        let point = NSEvent.mouseLocation

        switch model.state {
        case .collapsed:
            if geometry.hoverRect.contains(point) {
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
        }
    }

    private func scheduleExpand() {
        guard hoverTask == nil else { return }
        hoverTask = Task { [weak self, hoverDelay] in
            try? await Task.sleep(for: hoverDelay)
            guard !Task.isCancelled else { return }
            self?.expandIfStillHovering()
        }
    }

    private func expandIfStillHovering() {
        hoverTask = nil
        guard let geometry, model.state == .collapsed,
              geometry.hoverRect.contains(NSEvent.mouseLocation) else { return }
        model.state = .expanded
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
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
            guard let self, self.model.state != .dropReady else { return }
            self.model.state = .dropReady
        }
        dragMonitor.onDragEnded = { [weak self] in
            self?.finishDrag()
        }
        dragMonitor.start()
    }

    /// After a drag ends: stay expanded if the pointer is over the panel, otherwise collapse.
    /// A successful drop has already switched the state to expanded.
    private func finishDrag() {
        guard model.state == .dropReady, let geometry else { return }
        let area = geometry.expandedRect(size: model.expandedSize)
        model.state = area.contains(NSEvent.mouseLocation) ? .expanded : .collapsed
    }
}
