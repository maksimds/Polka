import Foundation
import Testing
@testable import Polka

/// Right-click > Share: which items it sends, and what each one is to the share services.
@MainActor
struct ShareTests {
    /// Real files a and b, then a link and a text, newest first on the shelf, handed
    /// back in a, b, link, text order.
    private func withShelf(_ body: (NotchViewModel, ShelfStore, [ShelfItem.ID], URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["a", "b"].map { name in
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            return file
        }
        let store = ShelfStore()
        store.add(files.map { ShelfItem.Draft(fileURL: $0) }
                  + [ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!), ShelfItem.Draft(text: "note")])
        let ids = files.map { file in store.items.first { $0.url.lastPathComponent == file.lastPathComponent }!.id }
            + [store.items.first { $0.kind == .link }!.id, store.items.first { $0.kind == .text }!.id]
        try body(NotchViewModel(store: store), store, ids, folder)
    }

    // MARK: - Which items

    @Test func anUnselectedTileSharesOnlyItself() throws {
        try withShelf { model, _, ids, _ in
            model.click(ids[0], .only)

            #expect(model.itemsToShare(from: ids[2]).map(\.id) == [ids[2]])
        }
    }

    /// Links and text go along, unlike Quick Look's links and Get Info's both.
    @Test func aSelectedTileSharesTheWholeSelectionStartingWithIt() throws {
        try withShelf { model, _, ids, _ in
            for id in ids { model.click(id, .toggle) }

            let shared = model.itemsToShare(from: ids[3]).map(\.id)
            #expect(shared.first == ids[3])
            #expect(Set(shared) == Set(ids))
        }
    }

    @Test func missingFilesStayBehind() throws {
        try withShelf { model, store, ids, folder in
            try FileManager.default.removeItem(at: folder.appendingPathComponent("b"))
            store.refreshReferences()
            for id in ids { model.click(id, .toggle) }

            #expect(Set(model.itemsToShare(from: ids[0]).map(\.id)) == [ids[0], ids[2], ids[3]])
        }
    }

    /// Quick Look still leaves links out, now that it shares the selection rule.
    @Test func quickLookStillLeavesLinksOut() throws {
        try withShelf { model, _, ids, _ in
            for id in ids { model.click(id, .toggle) }

            #expect(!model.itemsToShow(from: ids[0]).contains { $0.kind == .link })
            #expect(model.itemsToShow(from: ids[0]).count == 3)
        }
    }

    // MARK: - What each item is

    @Test func eachKindGoesAsWhatTheServicesTake() {
        let store = ShelfStore()
        let link = URL(string: "https://github.com/apple/swift")!
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.pdf")),
                   ShelfItem.Draft(linkURL: link),
                   ShelfItem.Draft(text: "Hello\nthere")])
        let file = store.items.first { $0.kind == .file }!
        let linkItem = store.items.first { $0.kind == .link }!
        let text = store.items.first { $0.kind == .text }!

        let objects = ShareController.objects(for: [file, linkItem, text])

        #expect(objects.count == 3)
        #expect((objects[0] as? URL)?.path == "/tmp/report.pdf")
        #expect(objects[1] as? URL == link)
        #expect(objects[2] as? String == "Hello\nthere")
    }

    /// The real file, as with opening and Quick Look, while it can be found.
    @Test func aKeptCopySharesItsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("report.txt")
        try Data().write(to: original)
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: original)])
        store.useCopy(id: store.items[0].id, at: URL(fileURLWithPath: "/tmp/Polka/Copies/1/report.txt"))

        let objects = ShareController.objects(for: store.items)

        #expect((objects.first as? URL)?.path == original.path)
    }

    /// A link saved before links had to be web addresses isn't handed on.
    @Test func aLinkThatIsNotAWebAddressStaysOut() throws {
        var item = try #require({
            let store = ShelfStore()
            store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!)])
            return store.items.first
        }())
        item.source = .link(URL(string: "smb://server/share")!)

        #expect(ShareController.objects(for: [item]).isEmpty)
    }
}
