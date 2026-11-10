import AppKit
import Testing
@testable import Polka

/// File promises (M3 step 6): files that apps like Photos, Mail and browsers write only
/// once the drop target asks. Receiving needs a real drag from another app, so these
/// test how promises are read and what happens once a file has arrived.
@MainActor
struct FilePromiseTests {
    private let fileManager = FileManager.default
    private let writer = PromiseWriter()

    private func pasteboard(holding writers: [NSPasteboardWriting]) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
        return pasteboard
    }

    private func promise(of fileType: String, alongside link: URL? = nil) -> NSFilePromiseProvider {
        let provider = PromiseWithLink(fileType: fileType, delegate: writer)
        provider.link = link
        return provider
    }

    private func withCopiesFolder(_ body: (ShelfCopies) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try await body(ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true)))
    }

    // MARK: - Reading a drop

    @Test func aPromiseOnItsOwnIsReadAsAPromise() {
        let items = DropReceiver.items(from: pasteboard(holding: [promise(of: "public.jpeg")]))

        #expect(items.count == 1)
        #expect(items.first?.promise?.fileTypes == ["public.jpeg"])
    }

    @Test func aBrowserImageIsTheImageRatherThanItsAddress() {
        let address = URL(string: "https://example.com/photo.jpg")!

        let items = DropReceiver.items(from: pasteboard(holding: [promise(of: "public.jpeg", alongside: address)]))

        #expect(items.count == 1)
        #expect(items.first?.promise != nil)
    }

    @Test func aPromisedBookmarkFileIsTakenAsTheLink() {
        let address = URL(string: "https://example.com/page")!

        let items = DropReceiver.items(from: pasteboard(holding: [promise(of: "com.apple.web-internet-location",
                                                                          alongside: address)]))

        #expect(items == [.link(address)])
    }

    @Test func aRealFileComesBeforeAPromise() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        let items = DropReceiver.items(from: pasteboard(holding: [file as NSURL, promise(of: "public.jpeg")]))

        #expect(items == [.file(file)])
    }

    @Test func aPromiseDragIsAccepted() {
        let view = DropTargetView(frame: .zero)
        let drag = FakeDrag(pasteboard: pasteboard(holding: [promise(of: "public.png")]), source: nil)

        #expect(view.draggingEntered(drag) == .copy)
    }

    @Test func aPromiseIsAskedForDuringTheDropAndStateWaitsATick() async throws {
        let view = DropTargetView(frame: .zero)
        var promisesSeenDuringDrop = 0
        var dropReported = false
        view.onPromisesDropped = { promisesSeenDuringDrop = $0.count }
        view.onDrop = { _ in dropReported = true }
        let drag = FakeDrag(pasteboard: pasteboard(holding: [promise(of: "public.png")]), source: nil)

        #expect(view.performDragOperation(drag))

        #expect(promisesSeenDuringDrop == 1)
        #expect(!dropReported)
        try await Task.sleep(for: .milliseconds(50))
        #expect(dropReported)
    }

    @Test func aDropOfOnlyPromisesAddsNothingYetButOpensTheShelf() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.state = .dropReady
        let items = DropReceiver.items(from: pasteboard(holding: [promise(of: "public.png")]))

        model.handleDrop(items)

        #expect(store.items.isEmpty)
        #expect(model.state == .expanded)
        #expect(model.notice == nil)
    }

    // MARK: - Once the file arrives

    @Test func anArrivedFileIsAddedAsACopy() async throws {
        try await withCopiesFolder { copies in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let file = try copies.makeFolder().appendingPathComponent("IMG_0001.heic")
            try Data("photo".utf8).write(to: file)
            var failures = 0

            keeper.promisedFileArrived(at: file, failure: nil) { _ in failures += 1 }

            #expect(failures == 0)
            #expect(store.items.map(\.title) == ["IMG_0001.heic"])
            #expect(store.items[0].kind == .file)
            #expect(store.items[0].storageMode == .copy)
            #expect(store.items[0].original == nil)
        }
    }

    @Test func aRemovedPromisedFileIsDeleted() async throws {
        try await withCopiesFolder { copies in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let file = try copies.makeFolder().appendingPathComponent("IMG_0001.heic")
            try Data("photo".utf8).write(to: file)
            keeper.promisedFileArrived(at: file, failure: nil) { _ in }

            store.remove(id: store.items[0].id)

            #expect(copies.folderNames().isEmpty)
        }
    }

    @Test func aFileWrittenOutsideTheCopiesFolderIsOnlyReferenced() async throws {
        try await withCopiesFolder { copies in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let elsewhere = copies.folder.deletingLastPathComponent().appendingPathComponent("photo.png")
            try Data("photo".utf8).write(to: elsewhere)
            keeper.promisedFileArrived(at: elsewhere, failure: nil) { _ in }
            #expect(store.items.first?.storageMode == .reference)

            store.remove(id: store.items[0].id)

            #expect(fileManager.fileExists(atPath: elsewhere.path))
        }
    }

    @Test func aFileThatNeverArrivesShowsAMessage() async throws {
        try await withCopiesFolder { copies in
            let store = ShelfStore()
            let keeper = CopyKeeper(store: store, copies: copies)
            let missing = copies.folder.appendingPathComponent(UUID().uuidString).appendingPathComponent("Clip.mov")
            var failedName: String?

            keeper.promisedFileArrived(at: missing, failure: "The app stopped") { failedName = $0 }

            #expect(failedName == "Clip.mov")
            #expect(store.items.isEmpty)
        }
    }
}

/// Writes a promised file the way a source app would. Receiving isn't tested, so
/// this is only here because a promise needs a delegate.
private final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "promised"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}

/// A promise that can also carry a web address on the same pasteboard item, the way
/// a browser offers both when an image is dragged.
private final class PromiseWithLink: NSFilePromiseProvider {
    var link: URL?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let types = super.writableTypes(for: pasteboard)
        return link == nil ? types : types + [.URL]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .URL, let link { return link.absoluteString }
        return super.pasteboardPropertyList(forType: type)
    }
}
