import Foundation
import Testing
@testable import Polka

/// "Rename" in a tile's right-click menu: a name of the tile's own, which changes
/// only its label, never the file or the link.
@MainActor
struct RenameTests {
    private let fileManager = FileManager.default

    private func storeWithFile(_ name: String = "report.pdf") -> ShelfStore {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\(name)"))])
        return store
    }

    /// A real, empty temporary folder, removed when `body` returns.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try body(folder)
    }

    private func makeFile(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("contents".utf8).write(to: url)
        return url
    }

    // MARK: - The store

    @Test func aNewNameChangesOnlyTheLabel() {
        let store = storeWithFile()
        let before = store.items[0]

        store.rename(id: before.id, to: "Q3 numbers")

        let after = store.items[0]
        #expect(after.displayName == "Q3 numbers")
        #expect(after.title == "report.pdf")
        #expect(after.source == before.source)
        #expect(after.url == before.url)
    }

    @Test func aLinkKeepsItsAddress() {
        let store = ShelfStore()
        let url = URL(string: "https://github.com/apple/swift-evolution/blob/main/proposals/0001.md")!
        store.add([ShelfItem.Draft(linkURL: url)])

        store.rename(id: store.items[0].id, to: "Proposal 1")

        #expect(store.items[0].displayName == "Proposal 1")
        #expect(store.items[0].url == url)
    }

    @Test func anEmptyNameBringsBackTheAutomaticOne() {
        let store = storeWithFile()
        let id = store.items[0].id
        store.rename(id: id, to: "Q3 numbers")

        store.rename(id: id, to: "   ")

        #expect(store.items[0].customName == nil)
        #expect(store.items[0].displayName == "report.pdf")
    }

    @Test func typingTheAutomaticNameIsTheSameAsNoName() {
        let store = storeWithFile()
        let id = store.items[0].id
        store.rename(id: id, to: "Q3 numbers")

        store.rename(id: id, to: "report.pdf")

        #expect(store.items[0].customName == nil)
    }

    @Test func spaceAroundIsTrimmedAndLineBreaksBecomeSpaces() {
        let store = storeWithFile()

        store.rename(id: store.items[0].id, to: "  Q3\nnumbers  ")

        #expect(store.items[0].displayName == "Q3 numbers")
    }

    @Test func twoTilesCanShareAName() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt")),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/b.txt"))])

        store.rename(id: store.items[0].id, to: "Notes")
        store.rename(id: store.items[1].id, to: "Notes")

        #expect(store.items.map(\.displayName) == ["Notes", "Notes"])
    }

    @Test func theNameIsSavedAndComesBackAfterARelaunch() {
        let persistence = InMemoryShelfPersistence()
        let first = ShelfStore(persistence: persistence)
        first.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"))])

        first.rename(id: first.items[0].id, to: "Q3 numbers")

        let second = ShelfStore(persistence: persistence)
        #expect(second.items[0].displayName == "Q3 numbers")
    }

    @Test func aShelfSavedBeforeRenamingExistedStillLoads() throws {
        let json = """
            {"createdAt":800000000,"id":"\(UUID().uuidString)","kind":"file","sortOrder":0,
             "source":{"file":{"path":"/tmp/a.txt"}},"storageMode":"reference","title":"a.txt"}
            """
        let item = try JSONDecoder().decode(ShelfItem.self, from: Data(json.utf8))

        #expect(item.customName == nil)
        #expect(item.displayName == "a.txt")
    }

    @Test func theNameStaysWhenTheFileIsRenamedOnDisk() throws {
        try withTemporaryFolder { folder in
            let original = try makeFile("draft.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            store.rename(id: store.items[0].id, to: "Essay")
            try fileManager.moveItem(at: original, to: folder.appendingPathComponent("final.txt"))

            store.refreshReferences()

            #expect(store.items[0].title == "final.txt")
            #expect(store.items[0].displayName == "Essay")
            // Cleared, the tile goes back to the file's new name.
            store.rename(id: store.items[0].id, to: "")
            #expect(store.items[0].displayName == "final.txt")
        }
    }

    @Test func theNameStaysWhenTheSiteNameArrives() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/a")!)])
        let id = store.items[0].id
        store.rename(id: id, to: "Mine")

        store.applyLinkPreview(id: id, siteName: "Example Site", iconFileName: nil)

        #expect(store.items[0].title == "Example Site/a")
        #expect(store.items[0].displayName == "Mine")
    }

    @Test func theNameStaysThroughKeepingACopyAndGoingBack() throws {
        try withTemporaryFolder { folder in
            let original = try makeFile("draft.txt", in: folder)
            let copy = try makeFile("copy-of-draft.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let id = store.items[0].id
            store.rename(id: id, to: "Essay")

            #expect(store.useCopy(id: id, at: copy))
            #expect(store.items[0].displayName == "Essay")
            #expect(store.useOriginal(id: id))
            #expect(store.items[0].displayName == "Essay")
        }
    }

    @Test func sortingByNameUsesTheGivenName() {
        let store = ShelfStore(sort: .name)
        store.add(["apple.txt", "banana.txt", "cherry.txt"].map {
            ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)"))
        })
        let cherry = store.items[2].id

        store.rename(id: cherry, to: "Aardvark")

        #expect(store.items.map(\.displayName) == ["Aardvark", "apple.txt", "banana.txt"])
    }

    // MARK: - The view model

    private func makeModel() -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt")),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/b.txt"))])
        let model = NotchViewModel(store: store)
        model.state = .expanded
        return (model, store)
    }

    @Test func renamingSelectsTheTileAlone() {
        let (model, store) = makeModel()
        let (first, second) = (store.items[0].id, store.items[1].id)
        model.click(first, .only)
        model.click(second, .toggle)

        model.beginRenaming(first)

        #expect(model.renamingItemID == first)
        #expect(model.selection == [first])
    }

    @Test func renamingOnlyStartsOnTheOpenShelf() {
        let (model, store) = makeModel()
        model.state = .collapsed

        model.beginRenaming(store.items[0].id)

        #expect(model.renamingItemID == nil)
    }

    @Test func finishingKeepsTheNameAndEndsTheEdit() {
        let (model, store) = makeModel()
        let id = store.items[0].id
        model.beginRenaming(id)

        model.finishRenaming(id, as: "Notes")

        #expect(model.renamingItemID == nil)
        #expect(store.items[0].displayName == "Notes")
        // Still selected, as in Finder.
        #expect(model.selection == [id])
    }

    @Test func cancellingKeepsTheOldName() {
        let (model, store) = makeModel()
        let id = store.items[0].id
        model.beginRenaming(id)

        model.cancelRenaming(id)

        #expect(model.renamingItemID == nil)
        #expect(store.items[0].displayName == "a.txt")
    }

    /// The field reports its end more than once in some paths, and late in others.
    @Test func anEditThatAlreadyEndedChangesNothing() {
        let (model, store) = makeModel()
        let (first, second) = (store.items[0].id, store.items[1].id)
        model.beginRenaming(first)
        model.finishRenaming(first, as: "Notes")
        model.beginRenaming(second)

        model.finishRenaming(first, as: "Late")
        model.cancelRenaming(first)

        #expect(store.items[0].displayName == "Notes")
        #expect(model.renamingItemID == second)
    }

    @Test func closingThePanelEndsTheEdit() {
        let (model, store) = makeModel()
        model.beginRenaming(store.items[0].id)

        model.state = .collapsed

        #expect(model.renamingItemID == nil)
        #expect(store.items[0].displayName == "a.txt")
    }

    // MARK: - The field

    private func selected(_ name: String, extension fileExtension: String?) -> String {
        let range = TileNameEditor.initialSelection(of: name, fileExtension: fileExtension)
        return (name as NSString).substring(with: range)
    }

    @Test func aFilesNameIsSelectedWithoutItsExtension() {
        #expect(selected("report.pdf", extension: "pdf") == "report")
        #expect(selected("archive.tar.gz", extension: "gz") == "archive.tar")
        #expect(selected("Photo.JPG", extension: "jpg") == "Photo")
    }

    @Test func anythingElseIsSelectedWhole() {
        // A given name without the extension, a folder, a link, and a name that's
        // only the extension.
        #expect(selected("Q3 numbers", extension: "pdf") == "Q3 numbers")
        #expect(selected("Projects.v2", extension: nil) == "Projects.v2")
        #expect(selected("GitHub/apple/swift", extension: nil) == "GitHub/apple/swift")
        #expect(selected(".pdf", extension: "pdf") == ".pdf")
        #expect(selected("Makefile", extension: "") == "Makefile")
    }
}
