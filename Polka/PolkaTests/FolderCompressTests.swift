import Foundation
import Testing
@testable import Polka

/// A shelf folder's "Compress" (FR-26): its tiles in a zip, as Finder's Compress makes
/// one, on the shelf right after the folder.
@MainActor
struct FolderCompressTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polka-compress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ source: ShelfItem.Source, kind: ShelfItem.Kind, title: String,
                      customName: String? = nil) -> ShelfItem {
        ShelfItem(id: UUID(), kind: kind, title: title, source: source, storageMode: .reference,
                  createdAt: Date(), expiresAt: nil, sortOrder: 0, customName: customName)
    }

    // MARK: - What goes in

    @Test func filesGoInUnderTheirRealNamesLinksAsWeblocsAndTextAsTxt() {
        let file = item(.file(path: "/tmp/report.pdf", bookmark: nil), kind: .file, title: "report.pdf",
                        customName: "Q3 numbers")
        let link = item(.link(URL(string: "https://github.com/apple/swift")!), kind: .link, title: "GitHub/apple/swift")
        let text = item(.text("hello"), kind: .text, title: "hello")

        let entries = FolderArchive.entries(for: [file, link, text], isMissing: { _ in false }, fileExists: { _ in true })

        #expect(entries.map(\.name) == ["report.pdf", "GitHub-apple-swift.webloc", "hello.txt"])
        #expect(entries[0].content == .file(URL(fileURLWithPath: "/tmp/report.pdf")))
        #expect(entries[1].content == .link(URL(string: "https://github.com/apple/swift")!))
        #expect(entries[2].content == .text("hello"))
    }

    @Test func filesThatCantBeFoundStayOut() {
        let missing = item(.file(path: "/tmp/gone.pdf", bookmark: nil), kind: .file, title: "gone.pdf")
        let unmarked = item(.file(path: "/tmp/also-gone.pdf", bookmark: nil), kind: .file, title: "also-gone.pdf")

        let entries = FolderArchive.entries(for: [missing, unmarked],
                                            isMissing: { $0 == missing.id },
                                            fileExists: { $0 != "/tmp/also-gone.pdf" })

        #expect(entries.isEmpty)
    }

    @Test func twoEntriesNeverShareANameAsInFinder() {
        let first = item(.text("one"), kind: .text, title: "notes")
        let second = item(.text("two"), kind: .text, title: "Notes")
        let third = item(.text("three"), kind: .text, title: "notes")

        let names = FolderArchive.entries(for: [first, second, third], isMissing: { _ in false }).map(\.name)

        #expect(names == ["notes.txt", "Notes 2.txt", "notes 3.txt"])
    }

    @Test func namesMadeFromTilesAreSafeFileNames() {
        #expect(FolderArchive.fileName(for: "a/b:c", fallback: "Text") == "a-b-c")
        #expect(FolderArchive.fileName(for: "..hidden", fallback: "Text") == "hidden")
        #expect(FolderArchive.fileName(for: "two\nlines", fallback: "Text") == "two lines")
        #expect(FolderArchive.fileName(for: "   ", fallback: "Link") == "Link")
        #expect(FolderArchive.fileName(for: String(repeating: "x", count: 300), fallback: "Text").count
                == FolderArchive.maxBaseLength)
        #expect(FolderArchive.archiveName(for: "") == ShelfStore.newFolderName)
    }

    @Test func aWeblocHoldsTheAddressAsFinderWritesIt() throws {
        let url = URL(string: "https://example.com/a?b=c")!

        let data = try FolderArchive.weblocData(for: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]

        #expect(plist == ["URL": "https://example.com/a?b=c"])
    }

    // MARK: - The zip

    @Test func aFoldersZipHoldsItsTilesAndLandsRightAfterIt() async throws {
        let workspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let copiesFolder = workspace.appendingPathComponent("Copies", isDirectory: true)
        let original = workspace.appendingPathComponent("report.txt")
        try Data("the report".utf8).write(to: original)

        let store = ShelfStore()
        store.add([ShelfItem.Draft(text: "on the shelf")])
        let folder = store.createFolder()
        store.rename(id: folder.id, to: "Work")
        store.add([ShelfItem.Draft(fileURL: original),
                   ShelfItem.Draft(linkURL: URL(string: "https://example.com/page")!),
                   ShelfItem.Draft(text: "Привет")], in: folder.id)
        let compressor = FolderCompressor(store: store, copies: ShelfCopies(folder: copiesFolder))

        let outcome = await compressor.compress(folder.id)

        guard case .added(let zipID) = outcome else {
            Issue.record("Expected a zip, got \(outcome)")
            return
        }
        let zip = try #require(store.items.first { $0.id == zipID })
        #expect(zip.title == "Work.zip")
        #expect(zip.storageMode == .copy)
        #expect(zip.folderID == nil)
        #expect(store.items(in: nil).map(\.title) == ["Work", "Work.zip", "on the shelf"])
        #expect(store.compressingItemIDs.isEmpty)
        // Only the zip's own copy folder is left; the layout it was made from is gone.
        let copyFolders = try FileManager.default.contentsOfDirectory(atPath: copiesFolder.path)
        #expect(copyFolders.count == 1)
        // The original is untouched.
        #expect(try String(contentsOf: original, encoding: .utf8) == "the report")

        // Unzipped, it's the folder with its tiles in it.
        let unzipped = workspace.appendingPathComponent("unzipped", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.url.path, unzipped.path]
        try ditto.run()
        ditto.waitUntilExit()
        let inside = unzipped.appendingPathComponent("Work", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: inside.path).sorted()
        #expect(names == ["Example-page.webloc", "report.txt", "Привет.txt"])
        #expect(try String(contentsOf: inside.appendingPathComponent("report.txt"), encoding: .utf8) == "the report")
        #expect(try String(contentsOf: inside.appendingPathComponent("Привет.txt"), encoding: .utf8) == "Привет")
    }

    @Test func anEmptyFolderHasNothingToCompress() async throws {
        let workspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = ShelfStore()
        let folder = store.createFolder()
        let compressor = FolderCompressor(store: store,
                                          copies: ShelfCopies(folder: workspace.appendingPathComponent("Copies")))

        #expect(await compressor.compress(folder.id) == .nothingToCompress)
        #expect(store.items.count == 1)
    }

    @Test func theOpenShelfScrollsToTheNewZip() async throws {
        let workspace = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = ShelfStore()
        let folder = store.createFolder()
        store.add([ShelfItem.Draft(text: "note")], in: folder.id)
        let compressor = FolderCompressor(store: store,
                                          copies: ShelfCopies(folder: workspace.appendingPathComponent("Copies")))
        let model = NotchViewModel(store: store, compressor: compressor)
        model.state = .expanded

        model.compress(folder.id)
        for _ in 0..<200 where model.itemToShow == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let zip = try #require(store.items.first { $0.title.hasSuffix(".zip") })
        #expect(model.itemToShow == zip.id)
        #expect(model.canCompress)
    }
}
