import AppKit
import Foundation
import Testing
@testable import Polka

/// Link names and icons (FR-6). The fetcher gets a stand-in for the network, so these
/// tests never go online.
@MainActor
struct LinkPreviewTests {
    private let fileManager = FileManager.default
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeFolder() throws -> URL {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private func linkDraft(_ string: String) -> ShelfItem.Draft {
        ShelfItem.Draft(linkURL: url(string))
    }

    private func sampleImage(width: CGFloat, height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
    }

    /// Gives the fetcher's background work up to two seconds to finish.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Naming

    @Test func aLinkIsNamedSiteThenAddressPath() {
        #expect(LinkNaming.title(for: url("https://www.linkedin.com/in/williamhgates/"), siteName: nil)
                == "Linkedin/in/williamhgates")
        #expect(LinkNaming.title(for: url("https://github.com/apple/swift"), siteName: "GitHub") == "GitHub/apple/swift")
        #expect(LinkNaming.title(for: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), siteName: nil) == "Youtube/watch")
        #expect(LinkNaming.title(for: url("https://en.wikipedia.org/wiki/MacBook_Pro"), siteName: nil)
                == "Wikipedia/wiki/MacBook_Pro")
    }

    @Test func aHomePageIsJustTheSiteName() {
        #expect(LinkNaming.title(for: url("https://www.apple.com/"), siteName: "Apple") == "Apple")
        #expect(LinkNaming.title(for: url("https://figma.com"), siteName: nil) == "Figma")
    }

    @Test func theNameFromAnAddressSkipsSubdomainsAndCountryEndings() {
        #expect(LinkNaming.nameFromAddress(url("https://docs.google.com/a")) == "Google")
        #expect(LinkNaming.nameFromAddress(url("https://news.bbc.co.uk/x")) == "Bbc")
        #expect(LinkNaming.nameFromAddress(url("https://www.amazon.co.jp")) == "Amazon")
        #expect(LinkNaming.nameFromAddress(url("http://localhost:8080/a")) == "Localhost")
        #expect(LinkNaming.nameFromAddress(url("http://192.168.1.10/admin")) == "192.168.1.10")
    }

    @Test func anAddressWithoutAHostKeepsItsWholeAddress() {
        #expect(LinkNaming.title(for: url("mailto:someone@example.com"), siteName: nil) == "mailto:someone@example.com")
    }

    @Test func aDeclaredSiteNameIsReadFromThePage() {
        let html = #"<head><meta property="og:title" content="x"><meta property="og:site_name" content="GitHub" /></head>"#
        #expect(LinkNaming.declaredSiteName(inHTML: html) == "GitHub")

        let reversed = #"<meta content='Figma' property='og:site_name'>"#
        #expect(LinkNaming.declaredSiteName(inHTML: reversed) == "Figma")

        let withEntities = #"<META NAME="og:site_name" CONTENT="Ben &amp; Jerry's">"#
        #expect(LinkNaming.declaredSiteName(inHTML: withEntities) == "Ben & Jerry's")

        #expect(LinkNaming.declaredSiteName(inHTML: "<title>YouTube</title>") == nil)
        #expect(LinkNaming.declaredSiteName(inHTML: #"<meta property="og:site_name" content="  ">"#) == nil)
    }

    // MARK: - Store

    @Test func aDroppedLinkIsNamedFromItsAddressRightAway() {
        let store = ShelfStore()
        store.add([linkDraft("https://github.com/apple/swift")])

        #expect(store.items[0].title == "Github/apple/swift")
    }

    @Test func aDeclaredSiteNameReplacesTheOneFromTheAddress() {
        let store = ShelfStore(now: { start })
        store.add([linkDraft("https://github.com/apple/swift")])

        store.applyLinkPreview(id: store.items[0].id, siteName: " GitHub \n", iconFileName: "x-icon.png")

        #expect(store.items[0].title == "GitHub/apple/swift")
        #expect(store.items[0].linkPreview == ShelfItem.LinkPreview(fetchedAt: start, siteName: "GitHub",
                                                                    iconFileName: "x-icon.png"))
        #expect(store.items[0].linkPreview?.isCurrent == true)
    }

    @Test func noDeclaredNameKeepsTheNameFromTheAddress() {
        let store = ShelfStore()
        store.add([linkDraft("https://www.linkedin.com/in/someone")])

        store.applyLinkPreview(id: store.items[0].id, siteName: "  ", iconFileName: nil)

        #expect(store.items[0].title == "Linkedin/in/someone")
        #expect(store.items[0].linkPreview?.siteName == nil)
    }

    @Test func filesNeverTakeALinkPreview() {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt"))])

        store.applyLinkPreview(id: store.items[0].id, siteName: "Nope", iconFileName: nil)

        #expect(store.items[0].title == "a.txt")
        #expect(store.items[0].linkPreview == nil)
    }

    @Test func aShelfSavedBeforePreviewsExistedStillLoads() throws {
        let json = """
            {"createdAt":800000000,"id":"\(UUID().uuidString)","kind":"link","sortOrder":0,
             "source":{"link":{"_0":"https://example.com"}},"storageMode":"reference","title":"example.com"}
            """
        let item = try JSONDecoder().decode(ShelfItem.self, from: Data(json.utf8))

        #expect(item.linkPreview == nil)
        #expect(item.url == url("https://example.com"))
    }

    @Test func aPreviewFromTheEarlierVersionIsNotCurrent() throws {
        let json = #"{"fetchedAt":800000000,"imageFileName":"old.png"}"#
        let preview = try JSONDecoder().decode(ShelfItem.LinkPreview.self, from: Data(json.utf8))

        #expect(preview.version == nil)
        #expect(!preview.isCurrent)
    }

    // MARK: - Fetcher

    @Test func aFetchedIconIsSavedAndShown() async throws {
        let folder = try makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let store = ShelfStore()
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { _ in
            .init(siteName: "GitHub", icon: sampleImage(width: 512, height: 512))
        }
        fetcher.start()

        store.add([linkDraft("https://github.com/apple/swift")])
        try await waitUntil { store.items[0].linkPreview != nil }

        let item = store.items[0]
        #expect(item.title == "GitHub/apple/swift")
        let name = try #require(item.linkPreview?.iconFileName)
        #expect(name == "\(item.id.uuidString)-icon.png")
        let saved = try #require(NSBitmapImageRep(data: Data(contentsOf: folder.appendingPathComponent(name))))
        #expect(saved.pixelsWide == 256)
        #expect(saved.pixelsHigh == 256)
        #expect(ShelfItemImages(previewsFolder: folder).image(for: item).size == NSSize(width: 256, height: 256))
    }

    @Test func aSiteThatRefusesKeepsItsAddressNameAndGenericIcon() async throws {
        let folder = try makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let store = ShelfStore()
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { _ in
            .init(siteName: nil, icon: nil)
        }
        fetcher.start()

        store.add([linkDraft("https://www.linkedin.com/in/someone")])
        try await waitUntil { store.items[0].linkPreview != nil }

        #expect(store.items[0].title == "Linkedin/in/someone")
        #expect(store.items[0].linkPreview?.iconFileName == nil)
        #expect(try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func anUnreachableSiteIsNotRetriedUntilTheNextLaunch() async throws {
        let folder = try makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let store = ShelfStore()
        var calls = 0
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        fetcher.start()

        store.add([linkDraft("https://example.com/page")])
        try await waitUntil { calls == 1 }
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt"))])
        try await Task.sleep(for: .milliseconds(200))

        #expect(calls == 1)
        #expect(store.items.first { $0.kind == .link }?.linkPreview == nil)
        #expect(store.items.first { $0.kind == .link }?.title == "Example/page")
    }

    @Test func onlyLinksWithoutACurrentPreviewAreFetched() async throws {
        let folder = try makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        var current = ShelfItem(id: UUID(), kind: .link, title: "Example/done",
                                source: .link(url("https://example.com/done")),
                                storageMode: .reference, createdAt: start, expiresAt: nil, sortOrder: 0)
        current.linkPreview = ShelfItem.LinkPreview(fetchedAt: start, siteName: nil, iconFileName: nil)
        var outdated = ShelfItem(id: UUID(), kind: .link, title: "Old Page Title",
                                 source: .link(url("https://github.com/apple/swift")),
                                 storageMode: .reference, createdAt: start, expiresAt: nil, sortOrder: 1)
        outdated.linkPreview = ShelfItem.LinkPreview(fetchedAt: start, siteName: nil, iconFileName: nil, version: nil)
        let store = ShelfStore(persistence: InMemoryShelfPersistence(items: [current, outdated]))
        var fetched: [URL] = []
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { link in
            fetched.append(link)
            return .init(siteName: "GitHub", icon: nil)
        }
        fetcher.start()
        try await waitUntil { store.items[1].linkPreview?.isCurrent == true }

        #expect(fetched == [url("https://github.com/apple/swift")])
        #expect(store.items[1].title == "GitHub/apple/swift")
    }

    @Test func removingALinkDeletesOnlyItsSavedIconAndOldImages() async throws {
        let folder = try makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let leftover = folder.appendingPathComponent("\(UUID().uuidString).png")
        try Data("old preview image".utf8).write(to: leftover)
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        let store = ShelfStore()
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { _ in
            .init(siteName: nil, icon: sampleImage(width: 64, height: 64))
        }
        fetcher.start()
        store.add([linkDraft("https://example.com/a"), linkDraft("https://example.com/b")])
        try await waitUntil { store.items.allSatisfy { $0.linkPreview != nil } }

        store.remove(id: store.items[0].id)

        let remaining = try fileManager.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(remaining == ["\(store.items[0].id.uuidString)-icon.png", "notes.txt"].sorted())
    }
}
