import AppKit

/// What a drag that starts on a tile carries.
struct ShelfDragContents: Equatable {
    /// The pressed tile's item first, then the rest of the selection in shelf order.
    let items: [ShelfItem]
    /// True for a file whose original can't be found. It can still be moved around
    /// the shelf, but there is nothing to hand to another app.
    let staysOnShelf: Bool
}

/// The source for every drag that starts on a shelf tile, whether it ends in another
/// app (a drag out) or back on the shelf (moving the tile).
///
/// It belongs to the panel controller rather than to a tile, because SwiftUI can
/// remove a tile while its drag is still running, and AppKit still needs somewhere
/// to report how the drag ended.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    /// Only Polka reads this. A tile that stays on the shelf carries nothing else, so
    /// no other app accepts it, and the panel registers for it so it can still be moved.
    static let shelfOnlyType = NSPasteboard.PasteboardType("com.maksimds.Polka.shelf-item")

    /// Called just before a drag starts, before it touches the drag pasteboard.
    var onWillStart: (@MainActor (ShelfDragContents) -> Void)?
    /// Called one run-loop tick after the pointer moves during a drag, with its screen position.
    var onMoved: (@MainActor (NSPoint) -> Void)?
    /// Called one run-loop tick after a drag ends, however it ended.
    var onEnded: (@MainActor () -> Void)?

    /// The drag that's running. Nil between drags.
    private(set) var current: ShelfDragContents?

    private let images: ShelfItemImages
    /// Side of each item's picture under the pointer.
    private let previewSide: CGFloat = 52

    init(images: ShelfItemImages) {
        self.images = images
        super.init()
    }

    /// Starts one drag carrying every item in `contents`, each as its own file or link,
    /// so a drop into Finder or Mail gets them all. `point` is in `view`'s coordinates.
    func startDrag(of contents: ShelfDragContents, at point: NSPoint, from view: NSView, event: NSEvent) {
        let items = contents.items
        guard !items.isEmpty else { return }
        current = contents
        onWillStart?(contents)
        Log.drop.debug("""
            Dragging \(items.map(\.title).joined(separator: ", "), privacy: .private)\
            \(contents.staysOnShelf ? " (shelf only)" : "", privacy: .public)
            """)
        let frame = NSRect(x: point.x - previewSide / 2,
                           y: point.y - previewSide / 2,
                           width: previewSide,
                           height: previewSide)
        let draggingItems = items.map { item in
            let writer = contents.staysOnShelf ? Self.shelfOnlyWriter(for: item) : Self.pasteboardWriter(for: item)
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
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

    /// Just the item's id, in a type only Polka reads.
    static func shelfOnlyWriter(for item: ShelfItem) -> NSPasteboardWriting {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: shelfOnlyType)
        return pasteboardItem
    }

    // MARK: - NSDraggingSource

    /// Over Polka's own panel the drag is a move: the tile changes places, and the
    /// pointer shows no green plus. Anywhere else it's copy only, because if move were
    /// offered there, dropping into Finder on the same disk would move the user's
    /// original file. Copy and generic stay allowed on the panel so that holding
    /// Option or Command, which narrows the choice, doesn't stop the move.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication {
            return [.move, .generic, .copy]
        }
        return current?.staysOnShelf == true ? [] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        DispatchQueue.main.async { [weak self] in self?.onMoved?(screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        Log.drop.debug("Tile drag ended, operation: \(operation.rawValue)")
        DispatchQueue.main.async { [weak self] in
            self?.current = nil
            self?.onEnded?()
        }
    }
}
