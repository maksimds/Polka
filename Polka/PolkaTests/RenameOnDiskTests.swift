import AppKit
import Foundation
import Testing
@testable import Polka

/// The tile's Rename submenu beyond the label: "Rename File" and "Rename Folder"
/// change the name on disk, and "Edit Address" changes a link's web address.
@MainActor
struct RenameOnDiskTests {
    private let fileManager = FileManager.default

    /// A real, empty temporary folder, removed when `body` returns.
    private func withTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try await body(folder)
    }

    @discardableResult
    private func makeFile(_ name: String, in folder: URL, contents: String = "contents") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func names(in folder: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func plan(for store: ShelfStore) throws -> FileRenamer.Plan {
        try #require(FileRenamer.Plan(item: store.items[0]))
    }

    // MARK: - The rules

    private func problem(_ name: String, replacing oldName: String, isFolder: Bool = false) -> FileRenaming.Problem? {
        FileRenaming.problem(with: name, replacing: oldName, isFolder: isFolder)
    }

    @Test func aNewNameWithTheSameExtensionIsFine() {
        #expect(problem("Q3 report.pdf", replacing: "report.pdf") == nil)
        // The extension's case alone may change, as Finder allows without asking.
        #expect(problem("report.PDF", replacing: "report.pdf") == nil)
        #expect(problem("Makefile.old", replacing: "Makefile", isFolder: true) == nil)
    }

    @Test func aChangedExtensionIsRefused() {
        #expect(problem("report.txt", replacing: "report.pdf") == .extensionChanged(from: "pdf"))
        #expect(problem("report", replacing: "report.pdf") == .extensionChanged(from: "pdf"))
        #expect(problem("README.md", replacing: "README") == .extensionChanged(from: ""))
    }

    /// A dot inside a name isn't an extension unless macOS knows the type it names.
    @Test func numbersAfterADotAreJustPartOfTheName() {
        #expect(FileRenaming.realExtension(of: "Notes v1.2") == "")
        #expect(problem("Notes v1.3", replacing: "Notes v1.2") == nil)
    }

    @Test func aFolderCanEndInAnything() {
        #expect(problem("Projects.v2", replacing: "Projects", isFolder: true) == nil)
        #expect(problem("Photos.pdf", replacing: "Photos", isFolder: true) == nil)
    }

    @Test func separatorsHiddenNamesAndLongNamesAreRefused() {
        #expect(problem("a:b.pdf", replacing: "report.pdf") == .separator)
        #expect(problem("a/b.pdf", replacing: "report.pdf") == .separator)
        #expect(problem(".report.pdf", replacing: "report.pdf") == .hidden)
        #expect(problem(String(repeating: "a", count: 252) + ".pdf", replacing: "report.pdf") == .tooLong)
        // 85 Cyrillic letters are 170 bytes, well within the limit.
        #expect(problem(String(repeating: "я", count: 85) + ".pdf", replacing: "report.pdf") == nil)
    }

    @Test func whatsTypedIsCleanedLikeALabel() {
        #expect(FileRenaming.cleaned("  Q3\nreport.pdf ") == "Q3 report.pdf")
    }

    // MARK: - On disk

    @Test func aFileIsRenamedNextToWhereItWas() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            let outcome = FileRenamer.perform(try plan(for: store), to: "Q3 report.pdf")

            let renamed = folder.appendingPathComponent("Q3 report.pdf").path
            #expect(outcome == .renamed(name: "Q3 report.pdf", path: renamed, originalPath: nil))
            #expect(try names(in: folder) == ["Q3 report.pdf"])
        }
    }

    @Test func aNameAlreadyTakenIsRefusedAndNothingIsReplaced() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder, contents: "mine")
            try makeFile("final.pdf", in: folder, contents: "theirs")
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            let outcome = FileRenamer.perform(try plan(for: store), to: "final.pdf")

            #expect(outcome == .refused("The name final.pdf is already taken, so report.pdf keeps its name"))
            #expect(try String(contentsOf: folder.appendingPathComponent("final.pdf"), encoding: .utf8) == "theirs")
            #expect(try names(in: folder) == ["final.pdf", "report.pdf"])
        }
    }

    /// The disk sees "report" and "Report" as the same file, which isn't "taken".
    @Test func onlyTheCaseCanChange() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            let outcome = FileRenamer.perform(try plan(for: store), to: "Report.pdf")

            #expect(outcome == .renamed(name: "Report.pdf",
                                        path: folder.appendingPathComponent("Report.pdf").path,
                                        originalPath: nil))
            #expect(try names(in: folder) == ["Report.pdf"])
        }
    }

    @Test func nothingTypedOrTheSameNameChangesNothing() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            #expect(FileRenamer.perform(try plan(for: store), to: "  ") == .unchanged)
            #expect(FileRenamer.perform(try plan(for: store), to: "report.pdf") == .unchanged)
            #expect(try names(in: folder) == ["report.pdf"])
        }
    }

    @Test func aRefusedNameLeavesTheFileAlone() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])

            let outcome = FileRenamer.perform(try plan(for: store), to: "report.txt")

            #expect(outcome == .refused(FileRenaming.message(for: .extensionChanged(from: "pdf"), oldName: "report.pdf")))
            #expect(try names(in: folder) == ["report.pdf"])
        }
    }

    @Test func aFolderIsRenamedWithWhatsInIt() async throws {
        try await withTemporaryFolder { folder in
            let inner = folder.appendingPathComponent("Projects", isDirectory: true)
            try fileManager.createDirectory(at: inner, withIntermediateDirectories: true)
            try makeFile("a.txt", in: inner)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: inner)])
            #expect(store.items[0].kind == .folder)

            _ = FileRenamer.perform(try plan(for: store), to: "Projects 2026")

            #expect(try names(in: folder) == ["Projects 2026"])
            #expect(try names(in: folder.appendingPathComponent("Projects 2026")) == ["a.txt"])
        }
    }

    /// A kept copy: the original is the real file, and the copy follows its name so a
    /// drag out drops it under the new one.
    @Test func aKeptCopyRenamesItsOriginalAndItsCopy() async throws {
        try await withTemporaryFolder { folder in
            let originals = folder.appendingPathComponent("Originals", isDirectory: true)
            let copyFolder = folder.appendingPathComponent("Copy", isDirectory: true)
            try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: copyFolder, withIntermediateDirectories: true)
            let original = try makeFile("draft.txt", in: originals)
            let copy = try makeFile("draft.txt", in: copyFolder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: original)])
            let id = store.items[0].id
            #expect(store.useCopy(id: id, at: copy))

            let plan = try plan(for: store)
            #expect(plan.isOriginal)
            let outcome = FileRenamer.perform(plan, to: "essay.txt")

            let newOriginal = originals.appendingPathComponent("essay.txt").path
            let newCopy = copyFolder.appendingPathComponent("essay.txt").path
            #expect(outcome == .renamed(name: "essay.txt", path: newCopy, originalPath: newOriginal))
            #expect(try names(in: originals) == ["essay.txt"])
            #expect(try names(in: copyFolder) == ["essay.txt"])

            store.fileRenamed(id: id, to: "essay.txt", path: newCopy, originalPath: newOriginal)
            #expect(store.items[0].original?.path == newOriginal)
            #expect(store.items[0].url.path == newCopy)
            #expect(store.items[0].displayName == "essay.txt")
        }
    }

    /// A screenshot, a pasted picture or a promised file only lives in Polka's folder.
    @Test func aCopyWithNoOriginalRenamesTheCopy() async throws {
        try await withTemporaryFolder { folder in
            let copy = try makeFile("Screenshot.png", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: copy, storageMode: .copy)])

            let plan = try plan(for: store)
            #expect(!plan.isOriginal)
            let outcome = FileRenamer.perform(plan, to: "Login bug.png")

            #expect(outcome == .renamed(name: "Login bug.png",
                                        path: folder.appendingPathComponent("Login bug.png").path,
                                        originalPath: nil))
        }
    }

    @Test func linksAndTextHaveNoFileToRename() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!),
                   ShelfItem.Draft(text: "Hello")])
        #expect(FileRenamer.Plan(item: store.items[0]) == nil)
        #expect(FileRenamer.Plan(item: store.items[1]) == nil)
    }

    // MARK: - The store

    @Test func aRenamedFileClearsTheLabelAndIsFollowed() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])
            let id = store.items[0].id
            store.rename(id: id, to: "Numbers")
            let renamed = folder.appendingPathComponent("Q3.pdf")
            try fileManager.moveItem(at: file, to: renamed)

            store.fileRenamed(id: id, to: "Q3.pdf", path: renamed.path, originalPath: nil)

            #expect(store.items[0].customName == nil)
            #expect(store.items[0].displayName == "Q3.pdf")
            #expect(store.items[0].url.path == renamed.path)
            // The bookmark points at the new name, so nothing looks missing afterwards.
            store.refreshReferences()
            #expect(store.missingItemIDs.isEmpty)
            #expect(store.items[0].url.path == renamed.path)
        }
    }

    // MARK: - Edit Address

    @Test func aNewAddressIsNamedFromItselfAndLooksUpItsSiteAgain() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/a")!)])
        let id = store.items[0].id
        store.applyLinkPreview(id: id, siteName: "Example", iconFileName: "\(id.uuidString)-icon.png")
        store.rename(id: id, to: "Mine")

        let change = store.changeAddress(id: id, to: URL(string: "https://github.com/apple/swift")!)

        #expect(change == .changed)
        #expect(store.items[0].url.absoluteString == "https://github.com/apple/swift")
        #expect(store.items[0].title == "Github/apple/swift")
        #expect(store.items[0].linkPreview == nil)
        // The label names the tile, not the address.
        #expect(store.items[0].displayName == "Mine")
    }

    @Test func anAddressAnotherTileHasIsRefused() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/a")!),
                   ShelfItem.Draft(linkURL: URL(string: "https://example.com/b")!)])
        let first = store.items.first { $0.url.absoluteString.hasSuffix("/a") }!

        #expect(store.changeAddress(id: first.id, to: URL(string: "https://example.com/b")!) == .duplicate)
        #expect(store.changeAddress(id: first.id, to: URL(string: "https://example.com/a")!) == .unchanged)
        #expect(store.items.first { $0.id == first.id }?.url.absoluteString == "https://example.com/a")
    }

    // MARK: - The view model

    @Test func eachKindOnlyStartsOnTilesItFits() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!),
                   ShelfItem.Draft(text: "Hello"),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf"))])
        // The file doesn't exist, so it's missing.
        store.refreshReferences()
        let model = NotchViewModel(store: store)
        model.state = .expanded
        let link = store.items.first { $0.kind == .link }!.id
        let text = store.items.first { $0.kind == .text }!.id
        let file = store.items.first { $0.kind == .file }!.id

        model.beginRenaming(text, .file)
        #expect(model.renamingItemID == nil)
        model.beginRenaming(text, .address)
        #expect(model.renamingItemID == nil)
        model.beginRenaming(file, .file)
        #expect(model.renamingItemID == nil)
        model.beginRenaming(file, .label)
        #expect(model.renamingItemID == file)
        model.cancelRenaming(file)

        model.beginRenaming(link, .address)
        #expect(model.renamingItemID == link)
        #expect(model.renameKind == .address)
    }

    @Test func aTypedAddressIsReadLikeTheLinkField() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/")!)])
        let model = NotchViewModel(store: store)
        model.state = .expanded
        let id = store.items[0].id

        model.beginRenaming(id, .address)
        model.finishRenaming(id, as: "not an address")
        #expect(model.notice == "That isn't a web address, so the link didn't change")
        #expect(store.items[0].url.absoluteString == "https://example.com/")

        model.beginRenaming(id, .address)
        model.finishRenaming(id, as: "Apple.com/mac")
        #expect(store.items[0].url.absoluteString == "https://apple.com/mac")
    }

    @Test func finishingRenamesTheFileAndARefusalSaysWhy() async throws {
        try await withTemporaryFolder { folder in
            let file = try makeFile("report.pdf", in: folder)
            let store = ShelfStore()
            store.add([ShelfItem.Draft(fileURL: file)])
            let model = NotchViewModel(store: store)
            model.state = .expanded
            let id = store.items[0].id

            model.beginRenaming(id, .file)
            model.finishRenaming(id, as: "report.txt")
            try await waitUntil { model.notice != nil }
            #expect(model.notice?.contains("“.pdf”") == true)
            #expect(try names(in: folder) == ["report.pdf"])

            model.beginRenaming(id, .file)
            model.finishRenaming(id, as: "Q3.pdf")
            try await waitUntil { store.items[0].title == "Q3.pdf" }
            #expect(try names(in: folder) == ["Q3.pdf"])
            #expect(store.items[0].displayName == "Q3.pdf")
            // A label edit afterwards is still only the label.
            model.beginRenaming(id, .label)
            #expect(model.renameKind == .label)
            model.finishRenaming(id, as: "Numbers")
            #expect(try names(in: folder) == ["Q3.pdf"])
        }
    }

    // MARK: - Link previews

    /// A preview of the old address that arrives after "Edit Address" belongs to no
    /// tile, and the new address gets a preview of its own.
    @Test func anEditedAddressGetsItsOwnPreview() async throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let store = ShelfStore()
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { url in
            if url.host == "old.example.com" {
                try await Task.sleep(for: .milliseconds(300))
                return .init(siteName: "Old Site", icon: nil)
            }
            return .init(siteName: "New Site", icon: nil)
        }
        fetcher.start()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://old.example.com/")!)])
        let id = store.items[0].id

        store.changeAddress(id: id, to: URL(string: "https://new.example.com/page")!)
        try await waitUntil { store.items[0].linkPreview != nil }
        try await Task.sleep(for: .milliseconds(400))

        #expect(store.items[0].linkPreview?.siteName == "New Site")
        #expect(store.items[0].title == "New Site/page")
    }
}
