import AppKit

/// Detects a drag that starts anywhere on screen, in any app.
///
/// How it works: the system drag pasteboard's change count goes up when an app
/// starts a real drag (a file, a link). Moving a window or selecting text does not
/// change it. The pasteboard keeps old contents after a drag ends, so its contents
/// alone can't tell us a drag is happening; we compare the count at mouse-down with
/// the count during mouse-dragged events instead.
///
/// Global mouse monitors do not need Accessibility permission.
@MainActor
final class GlobalDragMonitor {
    var onDragStarted: (@MainActor () -> Void)?
    var onDragEnded: (@MainActor () -> Void)?
    /// Called over and over while a drag is active, from dragged events and from the
    /// mouse-button poll, since dragged events may stop reaching global monitors once
    /// the other app's drag is under way. The pointer may not have moved since the last call.
    var onDragMoved: (@MainActor () -> Void)?

    private(set) var isDragging = false
    private var isOwnDragActive = false

    private let pasteboard = NSPasteboard(name: .drag)
    private var changeCountAtMouseDown = 0
    private var monitors: [Any] = []
    private var releaseTimer: Timer?

    func start() {
        changeCountAtMouseDown = pasteboard.changeCount

        addGlobalMonitor(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        addGlobalMonitor(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        addGlobalMonitor(.leftMouseUp) { [weak self] _ in self?.endDrag() }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    /// Ends the current drag. Safe to call more than once.
    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        changeCountAtMouseDown = pasteboard.changeCount
        Log.input.debug("Drag ended")
        onDragEnded?()
    }

    /// A drag out of the panel changes the drag pasteboard like any other drag, so
    /// without this Polka would read its own drag as an incoming one.
    func beginOwnDrag() {
        isOwnDragActive = true
    }

    func endOwnDrag() {
        isOwnDragActive = false
        changeCountAtMouseDown = pasteboard.changeCount
    }

    // MARK: - Private

    private func mouseDown() {
        changeCountAtMouseDown = pasteboard.changeCount
    }

    private func mouseDragged() {
        if isDragging {
            onDragMoved?()
            return
        }
        guard !isOwnDragActive, pasteboard.changeCount != changeCountAtMouseDown else { return }
        isDragging = true
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Log.input.debug("Drag started, pasteboard types: \(types, privacy: .public)")
        startReleaseTimer()
        onDragStarted?()
    }

    /// Backup for drag end: a mouse-up during a drag session is not always delivered
    /// to global monitors (for example when the drop lands in Polka itself), so poll
    /// the mouse button state while a drag is active.
    private func startReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.endDrag()
                } else {
                    self?.onDragMoved?()
                }
            }
        }
    }

    private func addGlobalMonitor(_ mask: NSEvent.EventTypeMask,
                                  _ action: @escaping @MainActor (NSEvent) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { action(event) }
        }
        if let monitor { monitors.append(monitor) }
    }
}
