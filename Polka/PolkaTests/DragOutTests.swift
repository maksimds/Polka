import AppKit
import Testing
@testable import Polka

@MainActor
struct DragOutTests {
    private func item(_ draft: ShelfItem.Draft) -> ShelfItem {
        let store = ShelfStore()
        store.add([draft])
        return store.items[0]
    }

    private func pasteboard(holding writer: NSPasteboardWriting) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        return pasteboard
    }

    private var fileItem: ShelfItem {
        item(ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    // MARK: - What the target app receives

    @Test func aFileGoesOutAsTheRealFile() {
        let board = pasteboard(holding: ShelfDragSource.pasteboardWriter(for: fileItem))

        #expect(DropReceiver.items(from: board) == [.file(URL(fileURLWithPath: "/tmp/report.pdf"))])
    }

    @Test func aLinkGoesOutAsAURLAndAsPlainText() throws {
        let link = URL(string: "https://example.com/a?b=1")!
        let writer = ShelfDragSource.pasteboardWriter(for: item(ShelfItem.Draft(linkURL: link)))

        let board = pasteboard(holding: writer)

        #expect(board.string(forType: .URL) == link.absoluteString)
        #expect(board.string(forType: .string) == link.absoluteString)
        #expect(DropReceiver.items(from: board) == [.link(link)])
    }

    // MARK: - Not landing back on the shelf

    @Test func aDragFromAnotherAppIsAccepted() {
        let view = DropTargetView(frame: .zero)
        let drag = FakeDrag(pasteboard: pasteboard(holding: URL(fileURLWithPath: "/tmp/a.txt") as NSURL),
                            source: nil)

        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
    }

    /// A tile dragged over its own panel is moving to a new place, not being stored again.
    @Test func aTileDraggedOverThePanelIsAMove() {
        let view = DropTargetView(frame: .zero)
        let drag = FakeDrag(pasteboard: pasteboard(holding: ShelfDragSource.pasteboardWriter(for: fileItem)),
                            source: ShelfDragSource(images: ShelfItemImages(previewsFolder: nil)),
                            operations: [.move, .generic, .copy])

        #expect(view.draggingEntered(drag) == .move)
        #expect(view.draggingUpdated(drag) == .move)
    }

    /// Holding Option leaves only copy on offer. The tile still moves.
    @Test func aTileStillMovesWithOptionHeld() {
        let view = DropTargetView(frame: .zero)
        let drag = FakeDrag(pasteboard: pasteboard(holding: ShelfDragSource.pasteboardWriter(for: fileItem)),
                            source: ShelfDragSource(images: ShelfItemImages(previewsFolder: nil)),
                            operations: .copy)

        #expect(view.draggingEntered(drag) == .copy)
    }

    /// A missing file's drag carries only Polka's own marker, which no app reads as
    /// a file or a link.
    @Test func aMissingFileCarriesNothingAnotherAppCanUse() {
        let item = fileItem
        let board = pasteboard(holding: ShelfDragSource.shelfOnlyWriter(for: item))

        #expect(DropReceiver.items(from: board).isEmpty)
        #expect(!DropReceiver.canAccept(board))
        #expect(board.string(forType: ShelfDragSource.shelfOnlyType) == item.id.uuidString)
    }
}

/// Stands in for AppKit's drag information, which only exists during a real drag.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation

    init(pasteboard: NSPasteboard, source: Any?, operations: NSDragOperation = .copy) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSourceOperationMask = operations
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
