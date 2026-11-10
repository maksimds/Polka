import AppKit

/// AppKit drop destination that wraps the SwiftUI content.
///
/// SwiftUI's `.onDrop` tries to make its window key when a drag enters, and the
/// notch panel refuses key status (so it never steals focus). An AppKit
/// `NSDraggingDestination` does not need key status, so drops work reliably here.
///
/// Both callbacks run one run-loop tick after AppKit's drag callback returns.
/// AppKit is still mid-drag during its callback, and changing state then makes the
/// window redraw too early, which logs "Reentrant message: kDragIPCCompleted".
final class DropTargetView: NSView {
    var onTargetChanged: (@MainActor (Bool) -> Void)?
    var onDrop: (@MainActor ([DroppedItem]) -> Void)?
    /// The one exception to waiting a tick: an app's file promise has to be asked for
    /// during the drop itself, while the drag is still going. Whatever it calls must
    /// only start receiving, and leave state changes until the files arrive.
    var onPromisesDropped: (@MainActor ([NSFilePromiseReceiver]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropReceiver.acceptedPasteboardTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(DropReceiver.acceptedPasteboardTypes)
    }

    /// Hosts a child view (the SwiftUI content) that fills this view.
    func embed(_ child: NSView) {
        child.frame = bounds
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let canAccept = isAcceptable(sender)
        Log.drop.debug("Drag entered panel, acceptable: \(canAccept)")
        reportTargetChanged(canAccept)
        return canAccept ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isAcceptable(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        Log.drop.debug("Drag exited panel")
        reportTargetChanged(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // The pasteboard is only readable during this call, so read it now.
        let items = DropReceiver.items(from: sender.draggingPasteboard)
        let accepted = !items.isEmpty
        Log.drop.debug("Drop performed, accepted: \(accepted)")
        guard accepted else { return false }

        let promises = items.compactMap(\.promise)
        if !promises.isEmpty {
            onPromisesDropped?(promises)
        }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(items) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        reportTargetChanged(false)
    }

    /// AppKit only sets `draggingSource` for drags that started inside Polka, which
    /// here means an item being dragged out. It must not land back on the shelf.
    private func isAcceptable(_ drag: NSDraggingInfo) -> Bool {
        drag.draggingSource == nil && DropReceiver.canAccept(drag.draggingPasteboard)
    }

    private func reportTargetChanged(_ targeted: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onTargetChanged?(targeted) }
    }
}
