import Foundation
import Testing
@testable import Polka

/// Broken references (FR-15), using real files in a temporary folder so the real
/// bookmark behaviour is what gets tested.
@MainActor
struct FileReferenceTests {
    private let fileManager = FileManager.default

    /// A real, empty temporary folder, removed when `body` returns.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try body(folder)
    }

    private func makeFile(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("contents".utf8).write(to: url)
        return url
    }

    /// Compares paths the way the disk sees them (the temporary folder sits behind a symlink).
    private func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func path(of item: ShelfItem) -> String? {
        guard case .file(let path, _) = item.source else { return nil }
        return path
    }

    private func bookmark(of item: ShelfItem) -> Data? {
        guard case .file(_, let bookmark) = item.source else { return nil }
        return bookmark
    }

    // MARK: - Bookmarks

    @Test func aDroppedFileGetsABookmark() throws {
        try withTemporaryFolder { folder in
            let file = try makeFile("report.txt", in: folder)
            guard case .file(_, let bookmark) = ShelfItem.Draft(fileURL: file).source else {
                Issue.record("Expected a file source")
                return
            }
            #expect(bookmark != nil)
        }
    }

    @Test func aPathThatDoesNotExistGetsNoBookmark() {
        guard case .file(_, let bookmark) = ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/nope/missing.txt")).source else {
            Issue.record("Expected a file source")
            return
        }
        #expect(bookmark == nil)
    }

    // MARK: - Following and missing

    @Test func aFileThatStayedPutIsLeftAlone() throws {
        try withTemporaryFolder { folder in
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: try makeFile("report.txt", in: folder))])
            let before = store.items

            store.refreshReferences()

            #expect(store.items == before)
            #expect(store.missingItemIDs.isEmpty)
        }
    }

    @Test func aMovedFileIsFollowed() throws {
        try withTemporaryFolder { folder in
            let original = try makeFile("A/report.txt", in: folder)
            let persistence = InMemoryShelfPersistence()
            let store = ShelfStore(persistence: persistence)
            store.add([ShelfItem.Draft(fileURL: original)])
            let destination = folder.appendingPathComponent("B/report.txt")
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: original, to: destination)

            store.refreshReferences()

            #expect(store.missingItemIDs.isEmpty)
            #expect(path(of: store.items[0]).map(realPath) == realPath(destination.path))
            #expect(store.items[0].title == "report.txt")
            #expect(persistence.load() == store.items)
        }
    }

    @Test func aRenamedFileTakesItsNewName() throws {
        try withTemporaryFolder { folder in
            let original = try makeFile("draft.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            try fileManager.moveItem(at: original, to: folder.appendingPathComponent("final.txt"))

            store.refreshReferences()

            #expect(store.items[0].title == "final.txt")
            #expect(store.missingItemIDs.isEmpty)
        }
    }

    @Test func aDeletedFileIsUnavailableButStaysOnTheShelf() throws {
        try withTemporaryFolder { folder in
            let file = try makeFile("report.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])
            try fileManager.removeItem(at: file)

            store.refreshReferences()

            #expect(store.items.count == 1)
            #expect(store.missingItemIDs == [store.items[0].id])
        }
    }

    @Test func aFileInTheTrashIsUnavailable() throws {
        try withTemporaryFolder { folder in
            let file = try makeFile("report.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])
            // A stand-in Trash folder, so the test never touches the real one.
            let trash = folder.appendingPathComponent(".Trash", isDirectory: true)
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
            try fileManager.moveItem(at: file, to: trash.appendingPathComponent("report.txt"))

            store.refreshReferences()

            #expect(store.missingItemIDs == [store.items[0].id])
            #expect(path(of: store.items[0]) == file.standardizedFileURL.path)
        }
    }

    @Test func aFileThatComesBackIsAvailableAgain() throws {
        try withTemporaryFolder { folder in
            let file = try makeFile("report.txt", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])
            let saved = folder.appendingPathComponent("saved-elsewhere.bin")
            try fileManager.moveItem(at: file, to: saved)
            try fileManager.removeItem(at: saved)
            store.refreshReferences()
            #expect(store.missingItemIDs.count == 1)

            _ = try makeFile("report.txt", in: folder)
            store.refreshReferences()

            #expect(store.missingItemIDs.isEmpty)
        }
    }

    @Test func anOlderItemWithoutABookmarkGetsOneWhenFound() throws {
        try withTemporaryFolder { folder in
            let file = try makeFile("report.txt", in: folder)
            let saved = ShelfItem(id: UUID(), kind: .file, title: "report.txt",
                                  source: .file(path: file.path, bookmark: nil),
                                  storageMode: .reference, createdAt: Date(), expiresAt: nil, sortOrder: 0)
            let store = ShelfStore(persistence: InMemoryShelfPersistence(items: [saved]))

            store.refreshReferences()

            #expect(bookmark(of: store.items[0]) != nil)
            #expect(store.missingItemIDs.isEmpty)
        }
    }

    @Test func linksAreNeverUnavailable() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com")!)])

        store.refreshReferences()

        #expect(store.missingItemIDs.isEmpty)
    }
}
