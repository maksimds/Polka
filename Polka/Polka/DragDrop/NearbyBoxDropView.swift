import AppKit

/// The Send To box's drop target (N5): the AppKit view under its SwiftUI content, as
/// `DropTargetView` is under the shelf's. A drag over a Mac's row lights the row; a
/// drop on it sends what's dragged to that Mac, its picture shrinking into the Mac's
/// circle. Anywhere else in the box, nothing is dropped.
///
/// Tiles from the shelf and things from other apps both land here. A tile drag is a
/// move as over the shelf (no green plus); anything else is a copy.
final class NearbyBoxDropView: NSView {
    /// Where the rows are, measured by SwiftUI.
    var geometry: NearbyBoxGeometry?
    /// Whether the Mac with this Bonjour name can take what's dragged.
    var canTake: ((String) -> Bool)?
    /// The Mac a drag is over, or nil when it's over none.
    var onHover: ((String?) -> Void)?
    /// What of the tiles being dragged can go, asked during the drop (nothing changes).
    var tilesToSend: (() -> [ShelfItem])?
    /// What was dropped, and on which Mac, a run-loop tick after the drop.
    var onDrop: (([ShelfItem], String) -> Void)?

    private var hovered: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropReceiver.acceptedPasteboardTypes + [ShelfDragSource.shelfOnlyType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func embed(_ child: NSView) {
        child.frame = bounds
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hover(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard mac(under: sender) != nil else {
            Log.drop.info("A drop on the Send To box missed every Mac")
            return false
        }
        sender.animatesToDestination = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return true
    }

    /// The pasteboard and the tiles are read now, while they can be; the send starts a
    /// tick later, since changing things inside a drag callback upsets AppKit.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = mac(under: sender) else { return false }
        let items = DropTargetView.isTileDrag(sender)
            ? tilesToSend?() ?? []
            : DropReceiver.itemsToSend(from: sender.draggingPasteboard)
        guard !items.isEmpty else { return false }
        if sender.animatesToDestination, let circle = geometry?.circles[id] {
            // Each picture shrinks into the circle's middle as it lands.
            let target = appKitRect(CGRect(x: circle.midX - 3, y: circle.midY - 3, width: 6, height: 6))
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                          searchOptions: [:]) { item, _, _ in
                item.draggingFrame = target
            }
        }
        Log.drop.info("Dropped \(items.count, privacy: .public) item(s) on a Mac in the Send To box")
        DispatchQueue.main.async { [weak self] in self?.onDrop?(items, id) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hover(nil)
    }

    // MARK: - Private

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let id = mac(under: sender)
        hover(id)
        guard id != nil else { return [] }
        guard DropTargetView.isTileDrag(sender) else { return .copy }
        let offered = sender.draggingSourceOperationMask
        return [NSDragOperation.move, .generic, .copy].first { offered.contains($0) } ?? []
    }

    /// The Mac whose row the drag is over, if it can take what's dragged.
    private func mac(under sender: NSDraggingInfo) -> String? {
        guard let id = geometry?.mac(at: swiftUIPoint(sender.draggingLocation)),
              canTake?(id) ?? false else { return nil }
        return id
    }

    private func hover(_ id: String?) {
        guard id != hovered else { return }
        hovered = id
        DispatchQueue.main.async { [weak self] in self?.onHover?(id) }
    }

    /// AppKit measures from the bottom left of the window, and SwiftUI from the top
    /// left of the content, which fills this view.
    private func swiftUIPoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func appKitRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
