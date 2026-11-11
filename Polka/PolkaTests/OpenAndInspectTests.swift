import AppKit
import Foundation
import Quartz
import Testing
@testable import Polka

/// Double-click to open (FR-9), and the files Quick Look and Get Info act on.
@MainActor
struct OpenAndInspectTests {
    private let copy = URL(fileURLWithPath: "/tmp/Polka/Copies/1/report.txt")

    /// A shelf with one file, made into a kept copy of `/tmp/originals/report.txt`.
    private func keptCopy() -> ShelfItem {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/originals/report.txt"))])
        store.useCopy(id: store.items[0].id, at: copy)
        return store.items[0]
    }

    // MARK: - What opens

    @Test func aReferenceOpensItsOwnFile() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.txt"))])

        #expect(store.items[0].urlToOpen(fileExists: { _ in true }).path == "/tmp/report.txt")
    }

    @Test func aKeptCopyOpensItsOriginalWhileItCanBeFound() {
        let item = keptCopy()

        #expect(item.urlToOpen(fileExists: { _ in true }).path == "/tmp/originals/report.txt")
    }

    @Test func aKeptCopyOpensTheCopyOnceTheOriginalIsGone() {
        let item = keptCopy()

        #expect(item.urlToOpen(fileExists: { _ in false }).path == copy.path)
    }

    @Test func aLinkOpensItsAddress() {
        let store = ShelfStore()
        let link = URL(string: "https://github.com/apple/swift")!
        store.add([ShelfItem.Draft(linkURL: link)])

        #expect(store.items[0].urlToOpen() == link)
    }

    // MARK: - What Quick Look and Get Info show

    /// Real files a, b and c, then a link, so missing files can be told apart.
    private func withShelf(_ body: (NotchViewModel, ShelfStore, [ShelfItem.ID], URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAndInspectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["a", "b", "c"].map { name in
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            return file
        }
        let store = ShelfStore()
        store.add(files.map { ShelfItem.Draft(fileURL: $0) }
                  + [ShelfItem.Draft(linkURL: URL(string: "https://example.com")!)])
        // Newest first, so put them back in a, b, c, link order.
        let ids = files.map { file in store.items.first { $0.url.lastPathComponent == file.lastPathComponent }!.id }
            + [store.items.first { $0.kind == .link }!.id]
        try body(NotchViewModel(store: store), store, ids, folder)
    }

    @Test func anUnselectedTileShowsOnlyItself() throws {
        try withShelf { model, _, ids, _ in
            model.click(ids[0], .only)

            #expect(model.filesToShow(from: ids[1]).map(\.lastPathComponent) == ["b"])
        }
    }

    @Test func aSelectedTileShowsTheWholeSelectionStartingWithIt() throws {
        try withShelf { model, _, ids, _ in
            model.click(ids[0], .only)
            model.click(ids[2], .toggle)

            #expect(model.filesToShow(from: ids[2]).map(\.lastPathComponent) == ["c", "a"])
        }
    }

    @Test func linksAndMissingFilesAreLeftOut() throws {
        try withShelf { model, store, ids, folder in
            try FileManager.default.removeItem(at: folder.appendingPathComponent("b"))
            store.refreshReferences()
            for id in ids { model.click(id, .toggle) }

            #expect(model.filesToShow(from: ids[0]).map(\.lastPathComponent) == ["a", "c"])
            #expect(model.urlToOpen(ids[1]) == nil)
        }
    }

    // MARK: - Quick Look finds Polka

    /// Polka's panels never become key, so Quick Look's search for a controller ends
    /// at the app delegate. With SwiftUI, that's SwiftUI's own delegate, which has to
    /// pass the question on to Polka's `AppDelegate`.
    @Test func theAppDelegateAnswersQuickLook() {
        let delegate = NSApp.delegate as? NSObject

        #expect(delegate?.responds(to: #selector(NSObject.acceptsPreviewPanelControl(_:))) == true)
        #expect(delegate?.responds(to: #selector(NSObject.beginPreviewPanelControl(_:))) == true)
    }
}
