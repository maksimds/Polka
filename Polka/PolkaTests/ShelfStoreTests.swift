import Foundation
import Testing
@testable import Polka

@MainActor
struct ShelfStoreTests {
    private func fileDraft(_ path: String) -> ShelfItem.Draft {
        ShelfItem.Draft(fileURL: URL(fileURLWithPath: path))
    }

    private func linkDraft(_ string: String) -> ShelfItem.Draft {
        ShelfItem.Draft(linkURL: URL(string: string)!)
    }

    /// A real, empty temporary folder, removed when `body` returns.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    // MARK: - Adding

    @Test func newItemIsAPermanentReferenceDatedByTheClock() {
        let date = Date(timeIntervalSince1970: 1_000)
        let store = ShelfStore(now: { date })

        store.add([fileDraft("/tmp/report.pdf")])

        let item = store.items[0]
        #expect(item.kind == .file)
        #expect(item.title == "report.pdf")
        #expect(item.source == .file(path: "/tmp/report.pdf", bookmark: nil))
        #expect(item.storageMode == .reference)
        #expect(item.createdAt == date)
        #expect(item.expiresAt == nil)
    }

    @Test func aRealFolderIsAFolderAndAPackageIsAFile() throws {
        try withTemporaryFolder { root in
            let folder = root.appendingPathComponent("Photos", isDirectory: true)
            let package = root.appendingPathComponent("Tool.app", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)

            #expect(ShelfItem.Draft(fileURL: folder).kind == .folder)
            #expect(ShelfItem.Draft(fileURL: package).kind == .file)
        }
    }

    @Test func linkTitleKeepsHostAndPath() {
        #expect(linkDraft("https://example.com/docs/page").title == "example.com/docs/page")
        #expect(linkDraft("https://example.com/").title == "example.com")
        #expect(linkDraft("mailto:someone@example.com").title == "mailto:someone@example.com")
        #expect(linkDraft("https://example.com/").kind == .link)
    }

    @Test func newestItemsComeFirstAndABatchKeepsItsOrder() {
        let store = ShelfStore()

        store.add([fileDraft("/tmp/old.txt")])
        store.add([fileDraft("/tmp/a.txt"), fileDraft("/tmp/b.txt")])

        #expect(store.items.map(\.title) == ["a.txt", "b.txt", "old.txt"])
        #expect(store.items.map(\.sortOrder) == [0, 1, 2])
    }

    // MARK: - Duplicates

    @Test func sameFileTwiceIsReportedAndNotAddedOrMoved() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/a.txt")])
        store.add([fileDraft("/tmp/b.txt")])

        let result = store.add([fileDraft("/tmp/a.txt")])

        #expect(result.added.isEmpty)
        #expect(result.duplicates.map(\.title) == ["a.txt"])
        #expect(store.items.map(\.title) == ["b.txt", "a.txt"])
    }

    @Test func sameLinkTwiceIsReported() {
        let store = ShelfStore()
        store.add([linkDraft("https://example.com/a")])

        let result = store.add([linkDraft("https://example.com/a")])

        #expect(result.added.isEmpty)
        #expect(result.duplicates.count == 1)
        #expect(store.items.count == 1)
    }

    @Test func differentSpellingsOfOnePathAreTheSameFile() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/folder/a.txt")])

        let result = store.add([fileDraft("/tmp/other/../folder/a.txt")])

        #expect(result.duplicates.count == 1)
        #expect(store.items.count == 1)
    }

    @Test func aFileAndALinkAreNeverDuplicatesOfEachOther() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/a.txt")])

        let result = store.add([ShelfItem.Draft(linkURL: URL(fileURLWithPath: "/tmp/a.txt"))])

        #expect(result.duplicates.isEmpty)
        #expect(store.items.count == 2)
    }

    @Test func aBatchAddsNewItemsAndReportsTheRest() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/existing.txt")])

        let result = store.add([
            fileDraft("/tmp/new.txt"),
            fileDraft("/tmp/existing.txt"),
            fileDraft("/tmp/new.txt"),
        ])

        #expect(result.added.map(\.title) == ["new.txt"])
        #expect(result.added.map(\.sortOrder) == [0])
        #expect(result.duplicates.map(\.title) == ["existing.txt", "new.txt"])
        #expect(store.items.map(\.title) == ["new.txt", "existing.txt"])
    }

    // MARK: - Removing

    @Test func removeTakesOutOneItemAndRenumbers() throws {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/a.txt"), fileDraft("/tmp/b.txt"), fileDraft("/tmp/c.txt")])

        let removed = store.remove(id: store.items[1].id)

        #expect(removed)
        #expect(store.items.map(\.title) == ["a.txt", "c.txt"])
        #expect(store.items.map(\.sortOrder) == [0, 1])
    }

    @Test func removingAnUnknownIDChangesNothing() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/a.txt")])

        #expect(!store.remove(id: UUID()))
        #expect(store.items.count == 1)
    }

    @Test func removingAnItemLeavesTheOriginalFileOnDisk() throws {
        try withTemporaryFolder { root in
            let file = root.appendingPathComponent("keep-me.txt")
            try Data("original".utf8).write(to: file)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            store.remove(id: store.items[0].id)

            #expect(store.items.isEmpty)
            #expect(try Data(contentsOf: file) == Data("original".utf8))
        }
    }

    @Test func aRemovedFileCanBeAddedAgain() {
        let store = ShelfStore()
        store.add([fileDraft("/tmp/a.txt")])
        store.remove(id: store.items[0].id)

        let result = store.add([fileDraft("/tmp/a.txt")])

        #expect(result.added.count == 1)
        #expect(result.duplicates.isEmpty)
    }

    // MARK: - Persistence

    @Test func addAndRemoveAreSaved() {
        let persistence = InMemoryShelfPersistence()
        let store = ShelfStore(persistence: persistence)

        store.add([fileDraft("/tmp/a.txt"), fileDraft("/tmp/b.txt")])
        #expect(persistence.load() == store.items)

        store.remove(id: store.items[0].id)
        #expect(persistence.load() == store.items)
        #expect(persistence.load().map(\.title) == ["b.txt"])
    }

    @Test func aNewStoreLoadsSavedItemsInGridOrder() {
        let persistence = InMemoryShelfPersistence()
        let first = ShelfStore(persistence: persistence)
        first.add([fileDraft("/tmp/a.txt"), fileDraft("/tmp/b.txt")])
        persistence.save(first.items.reversed())

        let second = ShelfStore(persistence: persistence)

        #expect(second.items.map(\.title) == ["a.txt", "b.txt"])
    }

    @Test func aStoreSurvivesPersistenceFailures() {
        let store = ShelfStore(persistence: FailingPersistence())
        #expect(store.items.isEmpty)

        store.add([fileDraft("/tmp/a.txt")])

        #expect(store.items.count == 1)
    }

    @Test func itemsSurviveAJSONRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let items = [
            ShelfItem(id: UUID(), kind: .file, title: "a.txt",
                      source: .file(path: "/tmp/a.txt", bookmark: Data([1, 2, 3])),
                      storageMode: .copy, createdAt: date, expiresAt: date, sortOrder: 0),
            ShelfItem(id: UUID(), kind: .link, title: "example.com",
                      source: .link(URL(string: "https://example.com")!),
                      storageMode: .reference, createdAt: date, expiresAt: nil, sortOrder: 1),
        ]

        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([ShelfItem].self, from: data)

        #expect(decoded == items)
    }
}

private struct FailingPersistence: ShelfPersistence {
    struct Failure: Error {}

    func load() throws -> [ShelfItem] { throw Failure() }
    func save(_ items: [ShelfItem]) throws { throw Failure() }
}
