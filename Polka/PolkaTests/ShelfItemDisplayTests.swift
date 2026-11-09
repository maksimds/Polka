import Foundation
import Testing
@testable import Polka

@MainActor
struct ShelfItemDisplayTests {
    private func item(_ draft: ShelfItem.Draft) -> ShelfItem {
        let store = ShelfStore()
        store.add([draft])
        return store.items[0]
    }

    @Test func aFileShowsItsExtensionAsItsType() {
        let draft = ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/report.final.pdf"))
        #expect(item(draft).typeLabel == "PDF")
    }

    @Test func aFileWithoutAnExtensionIsJustAFile() {
        let draft = ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/README"))
        #expect(item(draft).typeLabel == "File")
    }

    @Test func aFolderAndALinkAreNamedPlainly() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(item(ShelfItem.Draft(fileURL: folder)).typeLabel == "Folder")
        #expect(item(ShelfItem.Draft(linkURL: URL(string: "https://example.com")!)).typeLabel == "Link")
    }

    @Test func urlPointsBackAtWhatWasDropped() {
        let fileItem = item(ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt")))
        #expect(fileItem.url.isFileURL)
        #expect(fileItem.url.path == "/tmp/a.txt")

        let link = URL(string: "https://example.com/a?b=1")!
        #expect(item(ShelfItem.Draft(linkURL: link)).url == link)
    }
}
