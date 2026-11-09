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
    /// Called one run-loop tick after a drag ends, however it ended.
    var onEnded: (@MainActor () -> Void)?

    func startDrag(of item: ShelfItem,
                   image: NSImage,
                   imageFrame: NSRect,
                   from view: NSView,
                   event: NSEvent) {
        onWillStart?()
        Log.drop.debug("Dragging out \(item.title, privacy: .public)")
        let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardWriter(for: item))
        draggingItem.setDraggingFrame(imageFrame, contents: image)
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
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

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        Log.drop.debug("Drag out ended, operation: \(operation.rawValue)")
        DispatchQueue.main.async { [weak self] in self?.onEnded?() }
    }
}
