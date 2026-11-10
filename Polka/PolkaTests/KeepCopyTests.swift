import Foundation
import Testing
@testable import Polka

/// "Keep a copy" (M3 step 5), with real files in a temporary folder that stands in
/// for Polka's Application Support folder.
@MainActor
struct KeepCopyTests {
    private let fileManager = FileManager.default
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A temporary folder holding `Originals` (the user's files) and `Copies`
    /// (Polka's), removed when `body` returns.
    private func withFolders(_ body: (_ originals: URL, _ copies: ShelfCopies) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try await body(originals, ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true)))
    }

    private func makeFile(_ name: String, in folder: URL, contents: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func path(of item: ShelfItem) -> String? {
        guard case .file(let path, _) = item.source else { return nil }
        return path
    }

    /// Gives background work up to two seconds to finish.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - The Copies folder

    @Test func aCopyKeepsItsNameInAFolderOfItsOwn() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)

            let copy = try copies.copy(original)

            #expect(copy.lastPathComponent == "report.txt")
            #expect(copies.folderName(containing: copy.path) != nil)
            #expect(copies.folderNames().count == 1)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "original")
            #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        }
    }

    @Test func aFolderCanBeCopiedToo() async throws {
        try await withFolders { originals, copies in
            let folder = originals.appendingPathComponent("Project", isDirectory: true)
            _ = try makeFile("notes.txt", in: folder)

            let copy = try copies.copy(folder)

            #expect(fileManager.fileExists(atPath: copy.appendingPathComponent("notes.txt").path))
        }
    }

    @Test func aFailedCopyLeavesNothingBehind() async throws {
        try await withFolders { originals, copies in
            let missing = originals.appendingPathComponent("gone.txt")

            #expect(throws: (any Error).self) { try copies.copy(missing) }
            #expect(copies.folderNames().isEmpty)
        }
    }

    @Test func onlyPathsInsidePolkasCopyFoldersCount() async throws {
        try await withFolders { originals, copies in
            let name = UUID().uuidString
            let inside = copies.folder.appendingPathComponent(name).appendingPathComponent("a.txt").path

            #expect(copies.folderName(containing: inside) == name)
            #expect(copies.folderName(containing: copies.folder.appendingPathComponent(name).path) == nil)
            #expect(copies.folderName(containing: copies.folder.appendingPathComponent("Other/a.txt").path) == nil)
            #expect(copies.folderName(containing: originals.appendingPathComponent("a.txt").path) == nil)
            #expect(copies.folderName(containing: "\(copies.folder.path)/\(name)/../../Originals/a.txt") == nil)
        }
    }

    @Test func deletingRefusesAnythingButACopyFolder() async throws {
        try await withFolders { originals, copies in
            let notes = try makeFile("notes.txt", in: copies.folder)
            let other = try makeFile("Other/keep.txt", in: copies.folder)
            let original = try makeFile("report.txt", in: originals)

            copies.removeFolder(named: "Other")
            copies.removeFolder(named: "notes.txt")
            copies.removeFolder(named: "../Originals")
            copies.removeFolder(named: "")

            #expect(fileManager.fileExists(atPath: notes.path))
            #expect(fileManager.fileExists(atPath: other.path))
            #expect(fileManager.fileExists(atPath: original.path))
            #expect(fileManager.fileExists(atPath: copies.folder.path))
        }
    }

    // MARK: - The store

    @Test func usingACopyPointsTheItemAtItAndRemembersTheOriginal() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let persistence = InMemoryShelfPersistence()
            let store = ShelfStore(persistence: persistence)
            store.add([ShelfItem.Draft(fileURL: original)])
            let copy = try copies.copy(original)

            #expect(store.useCopy(id: store.items[0].id, at: copy))

            let item = store.items[0]
            #expect(item.storageMode == .copy)
            #expect(path(of: item) == copy.standardizedFileURL.path)
            #expect(item.original?.path == original.standardizedFileURL.path)
            #expect(item.original?.bookmark != nil)
            #expect(item.title == "report.txt")
            #expect(persistence.load() == store.items)
        }
    }

    @Test func aKeptCopyGoesBackToItsOriginal() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let id = store.items[0].id
            store.useCopy(id: id, at: try copies.copy(original))

            #expect(store.useOriginal(id: id))

            #expect(store.items[0].storageMode == .reference)
            #expect(path(of: store.items[0]) == original.standardizedFileURL.path)
            #expect(store.items[0].original == nil)
        }
    }

    @Test func withoutItsOriginalAKeptCopyStays() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let id = store.items[0].id
            let copy = try copies.copy(original)
            store.useCopy(id: id, at: copy)
            try fileManager.removeItem(at: original)

            #expect(!store.useOriginal(id: id))

            #expect(store.items[0].storageMode == .copy)
            #expect(path(of: store.items[0]) == copy.standardizedFileURL.path)
            // The copy is what's left, so the item is still available.
            store.refreshReferences()
            #expect(store.missingItemIDs.isEmpty)
        }
    }

    @Test func aMovedOriginalIsFollowedAndGoneBackTo() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("A/report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let id = store.items[0].id
            store.useCopy(id: id, at: try copies.copy(original))
            let moved = originals.appendingPathComponent("B/final.txt")
            try fileManager.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: original, to: moved)

            store.refreshReferences()
            #expect(store.items[0].original.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
                    == moved.resolvingSymlinksInPath().path)

            #expect(store.useOriginal(id: id))
            #expect(store.items[0].title == "final.txt")
        }
    }

    @Test func droppingTheOriginalOfAKeptCopyAddsNothing() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            store.useCopy(id: store.items[0].id, at: try copies.copy(original))

            let result = store.add([ShelfItem.Draft(fileURL: original)])

            #expect(result.added.isEmpty)
            #expect(result.duplicates.count == 1)
        }
    }

    @Test func aShelfSavedBeforeCopiesExistedStillLoads() throws {
        let json = """
            {"version": 1, "items": [{"id": "\(UUID().uuidString)", "kind": "file", "title": "a.txt",
              "source": {"file": {"path": "/tmp/a.txt"}}, "storageMode": "reference",
              "createdAt": 0, "sortOrder": 0}]}
            """
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("shelf.json")
        try Data(json.utf8).write(to: file)

        let items = try JSONFileShelfPersistence(fileURL: file).load()

        #expect(items.count == 1)
        #expect(items[0].original == nil)
    }

    // MARK: - Copying and cleaning up

    @Test func keepingACopyCopiesTheFileAndLeavesTheOriginal() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()

            #expect(await keeper.keepCopy(of: store.items[0].id))

            let copyPath = try #require(path(of: store.items[0]))
            #expect(copies.folderName(containing: copyPath) != nil)
            #expect(try String(contentsOfFile: copyPath, encoding: .utf8) == "original")
            #expect(fileManager.fileExists(atPath: original.path))
            #expect(store.copyingItemIDs.isEmpty)
        }
    }

    @Test func aLinkHasNothingToCopy() async throws {
        try await withFolders { _, copies in
            let store = ShelfStore()
            store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com")!)])
            let keeper = CopyKeeper(store: store, copies: copies)

            #expect(await keeper.keepCopy(of: store.items[0].id) == false)
            #expect(copies.folderNames().isEmpty)
        }
    }

    @Test func removingAKeptCopyDeletesTheCopyButNeverTheOriginal() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            #expect(await keeper.keepCopy(of: store.items[0].id))
            #expect(copies.folderNames().count == 1)

            store.remove(id: store.items[0].id)

            #expect(copies.folderNames().isEmpty)
            #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        }
    }

    @Test func goingBackToTheOriginalDeletesTheCopy() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            #expect(await keeper.keepCopy(of: store.items[0].id))

            #expect(store.useOriginal(id: store.items[0].id))

            #expect(copies.folderNames().isEmpty)
            #expect(fileManager.fileExists(atPath: original.path))
        }
    }

    @Test func anExpiredCopyIsDeleted() async throws {
        try await withFolders { originals, copies in
            var clock = start
            let store = ShelfStore(now: { clock })
            store.add([ShelfItem.Draft(fileURL: try makeFile("a.txt", in: originals)),
                       ShelfItem.Draft(fileURL: try makeFile("b.txt", in: originals))])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            for item in store.items {
                #expect(await keeper.keepCopy(of: item.id))
            }
            store.makeTemporary(id: store.items[0].id, lifetime: 60)

            clock = start.addingTimeInterval(60)
            store.removeExpired()

            #expect(store.items.map(\.title) == ["b.txt"])
            let remaining = try #require(path(of: store.items[0]))
            #expect(copies.folderNames() == [copies.folderName(containing: remaining)].compactMap { $0 })
        }
    }

    @Test func leftoverFoldersAreClearedAtLaunchAndUsedOnesKept() async throws {
        try await withFolders { originals, copies in
            let used = try makeFile("\(UUID().uuidString)/report.txt", in: copies.folder)
            let leftover = try makeFile("\(UUID().uuidString)/half-copied.mov", in: copies.folder)
            let notOurs = try makeFile("notes.txt", in: copies.folder)
            let saved = ShelfItem(id: UUID(), kind: .file, title: "report.txt",
                                  source: .file(path: used.path, bookmark: nil),
                                  storageMode: .copy, createdAt: start, expiresAt: nil, sortOrder: 0,
                                  original: ShelfItem.Original(path: originals.appendingPathComponent("report.txt").path))
            let store = ShelfStore(persistence: InMemoryShelfPersistence(items: [saved]))

            CopyKeeper(store: store, copies: copies).start()

            #expect(fileManager.fileExists(atPath: used.path))
            #expect(!fileManager.fileExists(atPath: leftover.deletingLastPathComponent().path))
            #expect(fileManager.fileExists(atPath: notOurs.path))
        }
    }

    @Test func leftoversAreKeptWhenTheShelfCouldNotBeRead() async throws {
        try await withFolders { _, copies in
            let leftover = try makeFile("\(UUID().uuidString)/photo.heic", in: copies.folder)
            let store = ShelfStore(persistence: UnreadablePersistence())
            #expect(store.loadFailed)

            CopyKeeper(store: store, copies: copies).start()

            #expect(fileManager.fileExists(atPath: leftover.path))
        }
    }

    // MARK: - The menu item

    @Test func theMenuItemKeepsACopyAndGoesBack() async throws {
        try await withFolders { originals, copies in
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: try makeFile("report.txt", in: originals))])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let model = NotchViewModel(store: store, copies: keeper)
            let id = store.items[0].id
            #expect(model.canKeepCopies)

            model.toggleKeepCopy(id)
            try await waitUntil { store.items[0].storageMode == .copy }
            #expect(store.items[0].storageMode == .copy)
            #expect(copies.folderNames().count == 1)

            model.toggleKeepCopy(id)
            #expect(store.items[0].storageMode == .reference)
            #expect(copies.folderNames().isEmpty)
            #expect(model.notice == nil)
        }
    }

    @Test func uncheckingWithoutTheOriginalSaysSoAndKeepsTheCopy() async throws {
        try await withFolders { originals, copies in
            let original = try makeFile("report.txt", in: originals)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let keeper = CopyKeeper(store: store, copies: copies)
            keeper.start()
            let model = NotchViewModel(store: store, copies: keeper)
            #expect(await keeper.keepCopy(of: store.items[0].id))
            try fileManager.removeItem(at: original)

            model.toggleKeepCopy(store.items[0].id)

            #expect(store.items[0].storageMode == .copy)
            #expect(copies.folderNames().count == 1)
            #expect(model.notice == "Can't find the original of report.txt, so the copy stays")
        }
    }

    @Test func withoutACopiesFolderThereIsNoMenuItem() {
        #expect(!NotchViewModel(store: ShelfStore()).canKeepCopies)
    }
}

private struct UnreadablePersistence: ShelfPersistence {
    struct Failure: Error {}

    func load() throws -> [ShelfItem] { throw Failure() }
    func save(_ items: [ShelfItem]) throws {}
}
