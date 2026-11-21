import AppKit
import Testing
@testable import Polka

/// Cmd-C over the shelf and the tile's "Copy": which tiles go on the clipboard, and
/// what each one is there. Each test copies to a pasteboard of its own, so the real
/// clipboard is left alone.
@MainActor
struct CopyTests {
    /// Real files a and b, then a link and a text, handed back in a, b, link, text order.
    private func withShelf(_ body: (NotchViewModel, ShelfStore, [ShelfItem.ID], URL, NSPasteboard) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["a", "b"].map { name in
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            return file
        }
        let store = ShelfStore()
        store.add(files.map { ShelfItem.Draft(fileURL: $0) }
                  + [ShelfItem.Draft(linkURL: URL(string: "https://example.com/page")!), ShelfItem.Draft(text: "note")])
        let ids = files.map { file in store.items.first { $0.url.lastPathComponent == file.lastPathComponent }!.id }
            + [store.items.first { $0.kind == .link }!.id, store.items.first { $0.kind == .text }!.id]
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CopyTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(NotchViewModel(store: store), store, ids, folder, pasteboard)
    }

    // MARK: - Cmd-C

    @Test func cmdCWithNothingSelectedCopiesNothing() throws {
        try withShelf { model, _, _, _, pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("before", forType: .string)

            #expect(!model.copySelection(to: pasteboard))
            // The clipboard keeps what it had.
            #expect(pasteboard.string(forType: .string) == "before")
            #expect(model.copyPulses.isEmpty)
        }
    }

    @Test func cmdCCopiesAFileAsTheFileItself() throws {
        try withShelf { model, _, ids, folder, pasteboard in
            model.click(ids[0], .only)

            #expect(model.copySelection(to: pasteboard))
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            #expect(urls?.map(\.lastPathComponent) == ["a"])
            #expect(urls?.first?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        }
    }

    @Test func aLinkIsCopiedAsItsAddress() throws {
        try withShelf { model, _, ids, _, pasteboard in
            model.click(ids[2], .only)
            model.copySelection(to: pasteboard)

            #expect(pasteboard.string(forType: .URL) == "https://example.com/page")
            // Text fields take it too.
            #expect(pasteboard.string(forType: .string) == "https://example.com/page")
        }
    }

    @Test func textIsCopiedAsPlainText() throws {
        try withShelf { model, _, ids, _, pasteboard in
            model.click(ids[3], .only)
            model.copySelection(to: pasteboard)

            #expect(pasteboard.string(forType: .string) == "note")
        }
    }

    @Test func aSelectionGoesOnAsOneItemEachInShelfOrder() throws {
        try withShelf { model, store, ids, _, pasteboard in
            for id in ids { model.click(id, .toggle) }
            model.copySelection(to: pasteboard)

            #expect(pasteboard.pasteboardItems?.count == 4)
            let order = store.items.map(\.id).filter { ids.contains($0) }
            #expect(model.copyPulses.keys.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } == order)
        }
    }

    @Test func missingFilesStayBehind() throws {
        try withShelf { model, store, ids, folder, pasteboard in
            try FileManager.default.removeItem(at: folder.appendingPathComponent("b"))
            store.refreshReferences()
            model.click(ids[1], .only)

            // Only a missing file selected: nothing to copy, so Cmd-C beeps.
            #expect(!model.copySelection(to: pasteboard))

            for id in ids { model.click(id, .toggle) }
            model.copySelection(to: pasteboard)
            #expect(Set(model.copyPulses.keys) == [ids[0], ids[2], ids[3]])
            #expect(model.copyableSelectionCount == 3)
        }
    }

    // MARK: - The menu's Copy

    @Test func anUnselectedTileCopiesOnlyItself() throws {
        try withShelf { model, _, ids, _, pasteboard in
            model.click(ids[0], .only)
            model.copy(from: ids[2], to: pasteboard)

            #expect(pasteboard.pasteboardItems?.count == 1)
            #expect(pasteboard.string(forType: .URL) == "https://example.com/page")
        }
    }

    @Test func aSelectedTileCopiesTheWholeSelection() throws {
        try withShelf { model, _, ids, _, pasteboard in
            model.click(ids[0], .only)
            model.click(ids[3], .toggle)
            model.copy(from: ids[3], to: pasteboard)

            #expect(pasteboard.pasteboardItems?.count == 2)
            #expect(Set(model.copyPulses.keys) == [ids[0], ids[3]])
        }
    }

    /// Each copy pulses the tile again, so copying twice shows twice.
    @Test func eachCopyCountsForThePulse() throws {
        try withShelf { model, _, ids, _, pasteboard in
            model.click(ids[0], .only)
            model.copySelection(to: pasteboard)
            model.copySelection(to: pasteboard)

            #expect(model.copyPulses[ids[0]] == 2)
        }
    }
}
