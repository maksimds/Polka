import AppKit

/// The source for every drag that starts on a shelf tile.
///
/// It belongs to the panel controller rather than to a tile, because SwiftUI can
/// remove a tile while its drag is still running, and AppKit still needs somewhere
/// to report how the drag ended.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    /// Called just before a drag starts, before it touches the drag pasteboard.
    var onWillStart: (@MainActor () -> Void)?
    /// Called one run-loop tick after the pointer moves during a drag, with its screen position.
    var onMoved: (@MainActor (NSPoint) -> Void)?
    /// Called one run-loop tick after a drag ends, however it ended.
    var onEnded: (@MainActor () -> Void)?

    private let images: ShelfItemImages
    /// Side of each item's picture under the pointer.
    private let previewSide: CGFloat = 52

    init(images: ShelfItemImages) {
        self.images = images
        super.init()
    }

    /// Starts one drag carrying every item in `items`, each as its own file or link,
    /// so a drop into Finder or Mail gets them all. `point` is in `view`'s coordinates.
    func startDrag(of items: [ShelfItem], at point: NSPoint, from view: NSView, event: NSEvent) {
        guard !items.isEmpty else { return }
        onWillStart?()
        Log.drop.debug("""
            Dragging out \(items.map(\.title).joined(separator: ", "), privacy: .public)
            """)
        let frame = NSRect(x: point.x - previewSide / 2,
                           y: point.y - previewSide / 2,
                           width: previewSide,
                           height: previewSide)
        let draggingItems = items.map { item in
            let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardWriter(for: item))
            // A tile's picture is cached by then, so this is the thumbnail it shows.
            draggingItem.setDraggingFrame(frame, contents: images.image(for: item))
            return draggingItem
        }
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        // Several items gather into a pile under the pointer, as in Finder, and macOS
        // shows how many there are.
        session.draggingFormation = items.count > 1 ? .pile : .default
    }

    /// What the target app receives: the real file, or the link as both a URL and
    /// plain text so that text fields accept it too.
    static func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting {
        switch item.source {
        case .file:
            return item.url as NSURL
        case .link(let url):
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(url.absoluteString, forType: .URL)
            pasteboardItem.setString(url.absoluteString, forType: .string)
            return pasteboardItem
        }
    }

    // MARK: - NSDraggingSource

    /// Copy only. If move were offered too, dropping into Finder on the same disk
    /// would move the user's original file.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        DispatchQueue.main.async { [weak self] in self?.onMoved?(screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        Log.drop.debug("Drag out ended, operation: \(operation.rawValue)")
        DispatchQueue.main.async { [weak self] in self?.onEnded?() }
    }
}
