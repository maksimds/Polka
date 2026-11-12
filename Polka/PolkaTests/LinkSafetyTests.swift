import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Polka

/// Links that aren't web addresses are never stored, opened or looked up, and what a
/// site sends for a link's preview is capped before anything decodes it. None of
/// these go online.
@MainActor
struct LinkSafetyTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private func linkItem(_ string: String, at sortOrder: Int) -> ShelfItem {
        ShelfItem(id: UUID(), kind: .link, title: string, source: .link(url(string)),
                  storageMode: .reference, createdAt: Date(), expiresAt: nil, sortOrder: sortOrder)
    }

    private func pasteboard(holding urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }

    /// Gives the fetcher's background work up to two seconds to finish.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Only web links

    @Test func onlyHTTPAndHTTPSAddressesWithAHostCount() {
        #expect(LinkInput.isWebAddress(url("https://example.com/a")))
        #expect(LinkInput.isWebAddress(url("HTTP://Example.com")))
        #expect(LinkInput.isWebAddress(url("http://192.168.1.10/")))

        #expect(!LinkInput.isWebAddress(url("smb://example.com/share")))
        #expect(!LinkInput.isWebAddress(url("vnc://example.com")))
        #expect(!LinkInput.isWebAddress(url("mailto:someone@example.com")))
        #expect(!LinkInput.isWebAddress(url("javascript:alert(1)")))
        #expect(!LinkInput.isWebAddress(url("someapp://do-something")))
        #expect(!LinkInput.isWebAddress(url("https:no-host")))
        #expect(!LinkInput.isWebAddress(URL(fileURLWithPath: "/Applications")))
    }

    @Test func aDroppedAddressThatIsNotAWebLinkIsRefused() {
        let share = url("smb://example.com/share")
        let page = url("https://example.com/page")

        let items = DropReceiver.items(from: pasteboard(holding: [share, page]))

        #expect(items == [.refusedLink(share), .link(page)])
    }

    @Test func aRefusedLinkIsNotStoredAndThePanelSaysWhy() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.state = .dropReady

        model.handleDrop([.refusedLink(url("smb://example.com/share"))])

        #expect(store.items.isEmpty)
        #expect(model.notice == "That link isn't a web address, so it wasn't added")
        #expect(model.state == .expanded)
    }

    @Test func theRestOfADropIsStillAdded() {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)

        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/a.txt")),
                          .refusedLink(url("smb://example.com/share")),
                          .refusedLink(url("someapp://do-something"))])

        #expect(store.items.map(\.title) == ["a.txt"])
        #expect(model.notice == "2 links aren't web addresses, so they weren't added")
    }

    /// A link saved before the rule, or written into shelf.json by hand.
    @Test func aSavedLinkThatIsNotAWebAddressIsNotOpened() {
        #expect(!ItemOpener.open(url("smb://example.com/share")))
        #expect(!ItemOpener.open(url("someapp://do-something")))
    }

    @Test func aSavedLinkThatIsNotAWebAddressIsNeverLookedUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ShelfStore(persistence: InMemoryShelfPersistence(items: [
            linkItem("smb://example.com/share", at: 0),
            linkItem("https://example.com/page", at: 1),
        ]))
        var fetched: [URL] = []
        let fetcher = LinkPreviewFetcher(store: store, previewsFolder: folder) { link in
            fetched.append(link)
            return .init(siteName: nil, icon: nil)
        }
        fetcher.start()
        try await waitUntil { store.items[1].linkPreview != nil }

        #expect(fetched == [url("https://example.com/page")])
        #expect(store.items[0].linkPreview == nil)
    }

    // MARK: - Download limits

    private func stream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
    }

    /// Never ends, like a server that keeps sending.
    private var endless: AsyncStream<UInt8> {
        AsyncStream(unfolding: { UInt8(ascii: "a") })
    }

    @Test func readingAPageStopsAtTheEndOfItsHead() async throws {
        let page = Array("<html><head><title>x</title></HEAD><body>lots more</body>".utf8)

        let head = try await LinkPreviewFetcher.readPageHead(stream(page))

        #expect(String(decoding: head, as: UTF8.self) == "<html><head><title>x</title></HEAD>")
    }

    /// The old reader went line by line, so a page with no line breaks grew without end.
    @Test func aPageThatNeverEndsItsHeadIsCutOff() async throws {
        let head = try await LinkPreviewFetcher.readPageHead(endless, limit: 1000)

        #expect(head.count == 1000)
    }

    @Test func anIconOverTheLimitIsDroppedEvenIfItNeverEnds() async throws {
        #expect(try await LinkPreviewFetcher.readIcon(endless, limit: 1000) == nil)
        #expect(try await LinkPreviewFetcher.readIcon(stream(Array(repeating: 1, count: 1001)), limit: 1000) == nil)
        #expect(try await LinkPreviewFetcher.readIcon(stream(Array(repeating: 1, count: 1000)), limit: 1000)?.count
                == 1000)
    }

    // MARK: - Decoding icons

    private func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// An image file of the given format holding each picture.
    private func file(_ type: UTType, holding pictures: [CGImage]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, pictures.count, nil)!
        for picture in pictures {
            CGImageDestinationAddImage(destination, picture, nil)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func aPNGIconIsDecoded() throws {
        let icon = try #require(LinkPreviewFetcher.decodeIcon(file(.png, holding: [picture(width: 180, height: 180)])))

        #expect(icon.size == NSSize(width: 180, height: 180))
    }

    @Test func theLargestSizeInAnICOFileIsUsed() throws {
        let ico = file(.ico, holding: [picture(width: 16, height: 16),
                                       picture(width: 64, height: 64),
                                       picture(width: 32, height: 32)])

        let icon = try #require(LinkPreviewFetcher.decodeIcon(ico))

        #expect(icon.size == NSSize(width: 64, height: 64))
    }

    /// A tiny file can describe a huge picture, which would take a lot of memory to decode.
    @Test func anIconWithTooManyPixelsIsRefused() {
        let wide = file(.png, holding: [picture(width: 3000, height: 1)])

        #expect(wide.count < 10_000)
        #expect(LinkPreviewFetcher.decodeIcon(wide) == nil)
    }

    @Test func anIconFileOverTheByteLimitIsRefused() {
        var padded = file(.png, holding: [picture(width: 16, height: 16)])
        #expect(LinkPreviewFetcher.decodeIcon(padded) != nil)

        // Image readers ignore what comes after the picture, so only the limit stops this.
        padded.append(Data(count: LinkPreviewFetcher.Limits.iconBytes))

        #expect(LinkPreviewFetcher.decodeIcon(padded) == nil)
    }

    @Test func onlyFormatsUsedForIconsAreDecoded() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32"/></svg>"#.utf8)
        let bounds = NSRect(x: 0, y: 0, width: 32, height: 32)
        let pdf = NSView(frame: bounds).dataWithPDF(inside: bounds)
        let tiff = file(.tiff, holding: [picture(width: 32, height: 32)])
        let html = Data("<html><body>not an icon</body></html>".utf8)

        for data in [svg, pdf, tiff, html] {
            #expect(LinkPreviewFetcher.decodeIcon(data) == nil)
        }
        // The old code handed everything to NSImage, which reads SVG with its own parser.
        #expect(NSImage(data: svg) != nil)
    }
}
