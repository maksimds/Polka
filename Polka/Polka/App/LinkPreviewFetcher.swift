import AppKit
import Combine
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

/// Looks up each link's site name and icon in the background (FR-6), and saves the
/// icon in Polka's Previews folder so nothing is fetched again after a restart.
///
/// Requests go out as Polka, never disguised as a browser. A site that refuses them
/// (LinkedIn does) keeps the name taken from its address.
///
/// Whatever a site sends is untrusted, and Polka isn't sandboxed, so everything here
/// is capped (`Limits`): how long a download takes, how many bytes it brings, and
/// which image formats and sizes get decoded at all. A site that goes past a limit
/// gets the same fallbacks as one that refuses.
@MainActor
final class LinkPreviewFetcher {
    struct Preview {
        var siteName: String?
        var icon: NSImage?
    }

    typealias Fetch = @MainActor (URL) async throws -> Preview

    /// Longest side of a saved icon, in pixels.
    static let maxIconSide: CGFloat = 256

    private let store: ShelfStore
    private let previewsFolder: URL
    private let fetch: Fetch
    private let fileManager = FileManager.default
    private var inFlight = Set<ShelfItem.ID>()
    /// Links whose site couldn't be reached this session, for example while offline.
    /// They are tried again at the next launch rather than after every change.
    private var failed = Set<ShelfItem.ID>()
    private var watcher: AnyCancellable?

    init(store: ShelfStore, previewsFolder: URL, fetch: @escaping Fetch = LinkPreviewFetcher.fetchFromWeb) {
        self.store = store
        self.previewsFolder = previewsFolder
        self.fetch = fetch
    }

    func start() {
        // `$items` sends the new list just before the store updates, so this works from
        // the list it is given rather than `store.items`.
        watcher = store.$items.sink { [weak self] items in
            self?.fetchMissingPreviews(in: items)
            self?.removeUnusedIcons(keeping: items)
        }
    }

    private func fetchMissingPreviews(in items: [ShelfItem]) {
        for item in items {
            guard case .link(let url) = item.source,
                  LinkInput.isWebAddress(url),
                  item.linkPreview?.isCurrent != true,
                  !inFlight.contains(item.id),
                  !failed.contains(item.id) else { continue }
            inFlight.insert(item.id)
            Task { await self.fetchPreview(for: item.id, url: url) }
        }
    }

    private func fetchPreview(for id: ShelfItem.ID, url: URL) async {
        defer { inFlight.remove(id) }
        let preview: Preview
        do {
            preview = try await fetch(url)
        } catch {
            failed.insert(id)
            Log.app.info("""
                Couldn't reach \(url.host ?? "a link", privacy: .public) for its preview: \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        var iconFileName: String?
        if let icon = preview.icon {
            let name = "\(id.uuidString)-icon.png"
            do {
                try Self.savePNG(icon, to: previewsFolder.appendingPathComponent(name))
                iconFileName = name
            } catch {
                Log.app.error("Could not save a site icon: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Saving and recording happen back to back on the main actor, so the cleanup
        // below never sees the new icon before the item points at it.
        store.applyLinkPreview(id: id, siteName: preview.siteName, iconFileName: iconFileName)
    }

    /// Deletes saved icons whose link is no longer on the shelf, including images left
    /// by older versions. Only PNGs named after an item, inside the Previews folder,
    /// are ever touched.
    private func removeUnusedIcons(keeping items: [ShelfItem]) {
        let inUse = Set(items.compactMap { $0.linkPreview?.iconFileName })
        guard let names = try? fileManager.contentsOfDirectory(atPath: previewsFolder.path) else { return }
        for name in names where Self.isSavedByPolka(name) && !inUse.contains(name) {
            try? fileManager.removeItem(at: previewsFolder.appendingPathComponent(name))
        }
    }

    private static func isSavedByPolka(_ name: String) -> Bool {
        name.hasSuffix(".png") && UUID(uuidString: String(name.prefix(36))) != nil
    }

    // MARK: - Limits

    /// How much a site can make Polka download and decode.
    enum Limits {
        /// The top of a page, where the site name is. Reading stops here even if
        /// `</head>` never comes.
        static let pageHeadBytes = 600_000
        /// One icon file. Real ones are a few kilobytes.
        static let iconBytes = 1_000_000
        /// An icon's longest side, in pixels. Checked before decoding, since a tiny
        /// file can describe an enormous picture.
        static let iconPixels = 2048
        /// The longest wait for the next bytes...
        static let idleSeconds: TimeInterval = 15
        /// ...and the longest a whole download may take, so a site sending a byte
        /// every few seconds can't keep it open for good.
        static let totalSeconds: TimeInterval = 20
        /// Icon files tried per link when LinkPresentation finds none, so a page
        /// listing dozens of icons can't send Polka after all of them.
        static let iconCandidates = 3
    }

    /// Formats a site icon is decoded from, told by what its bytes are, not by what
    /// the site claims. ImageIO reads many more, almost none of them used for icons,
    /// and each one left out is decoder code a site can't reach. SVG isn't here:
    /// ImageIO doesn't read it, and AppKit's own reader is a whole XML parser.
    static let iconTypes: Set<String> = Set([UTType.ico, .png, .jpeg, .gif, .bmp, .webP].map(\.identifier))

    /// A session of its own rather than the shared one: every download gets a total
    /// time limit, not just one on waiting, and nothing it fetches is cached on disk
    /// or kept after Polka quits.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Limits.idleSeconds
        configuration.timeoutIntervalForResource = Limits.totalSeconds
        return URLSession(configuration: configuration)
    }()

    // MARK: - Fetching and saving

    /// The site's declared name, read from the top of the page, and its icon. Throws only
    /// when the site can't be reached at all (or runs out of time), so the link is
    /// tried again at the next launch.
    static func fetchFromWeb(_ url: URL) async throws -> Preview {
        async let pageHead = fetchPageHead(url)
        let suggested = await fetchLinkPresentationIcon(for: url)
        let head = try await pageHead
        var icon = suggested
        if icon == nil {
            icon = await fetchFirstIcon(from: iconCandidates(inHTML: head?.html ?? "", pageURL: head?.url ?? url))
        }
        return Preview(siteName: head.flatMap { LinkNaming.declaredSiteName(inHTML: $0.html) }, icon: icon)
    }

    /// The top of a page, and the address it came from after any redirects, which is
    /// where the addresses in it start from.
    struct PageHead {
        let html: String
        let url: URL
    }

    /// The page up to the end of its `<head>`, where the site name and icon tags are.
    /// Nil when the site answers but won't serve the page.
    nonisolated private static func fetchPageHead(_ url: URL) async throws -> PageHead? {
        var request = URLRequest(url: url, timeoutInterval: Limits.idleSeconds)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        // Whatever the page has after its head isn't needed, so the download stops.
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let html = String(decoding: try await readPageHead(bytes), as: UTF8.self)
        return PageHead(html: html, url: response.url ?? url)
    }

    /// The bytes of a page up to and including `</head>` (in any case), or its first
    /// `limit` bytes, whichever comes first. Counted in bytes rather than lines, so a
    /// page that never starts a new line can't grow without end.
    nonisolated static func readPageHead<Bytes: AsyncSequence>(_ bytes: Bytes,
                                                               limit: Int = Limits.pageHeadBytes) async throws -> Data
    where Bytes.Element == UInt8 {
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count >= limit || (byte == UInt8(ascii: ">") && endsWithHeadClose(head)) { break }
        }
        return head
    }

    nonisolated private static let headClose = Array("</head>".utf8)

    nonisolated private static func endsWithHeadClose(_ data: Data) -> Bool {
        guard data.count >= headClose.count else { return false }
        return zip(data.suffix(headClose.count), headClose).allSatisfy { byte, expected in
            // Letters are compared as lowercase, so "</HEAD>" counts too.
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte) == expected
        }
    }

    /// The icon Apple's LinkPresentation framework picks for the page. It arrives as
    /// plain bytes and goes through `decodeIcon`. Nil when it finds none, or can't
    /// load the page at all, as with Notion's pages.
    private static func fetchLinkPresentationIcon(for url: URL) async -> NSImage? {
        let provider = LPMetadataProvider()
        // LinkPresentation's timeout is for the whole lookup.
        provider.timeout = Limits.totalSeconds
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let data = await loadIconData(from: metadata.iconProvider) else { return nil }
        return decodeIcon(data)
    }

    /// Where else to look for an icon, best first: the page's Apple touch icons (usually
    /// a large PNG), then its other icons, in the order the page lists them, then the
    /// site's /favicon.ico. Only web addresses, each once, and at most `iconCandidates`.
    /// A Safari pinned-tab `mask-icon` isn't an icon, and a `data:` icon is skipped.
    static func iconCandidates(inHTML html: String, pageURL: URL) -> [URL] {
        var touchIcons: [URL] = []
        var icons: [URL] = []
        let fullRange = NSRange(html.startIndex..., in: html)
        let tags = (try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive))?
            .matches(in: html, range: fullRange) ?? []
        for match in tags {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let rel = attribute("rel", in: tag), let href = attribute("href", in: tag),
                  let address = URL(string: LinkNaming.decodingEntities(href), relativeTo: pageURL)?.absoluteURL
            else { continue }
            let kinds = Set(rel.lowercased().split(whereSeparator: \.isWhitespace))
            if kinds.contains("apple-touch-icon") || kinds.contains("apple-touch-icon-precomposed") {
                touchIcons.append(address)
            } else if kinds.contains("icon") {
                icons.append(address)
            }
        }

        var siteFavicon = URLComponents()
        siteFavicon.scheme = pageURL.scheme
        siteFavicon.host = pageURL.host
        siteFavicon.port = pageURL.port
        siteFavicon.path = "/favicon.ico"

        var candidates: [URL] = []
        for address in touchIcons + icons + [siteFavicon.url].compactMap({ $0 })
        where LinkInput.isWebAddress(address) && !candidates.contains(address) {
            candidates.append(address)
        }
        return Array(candidates.prefix(Limits.iconCandidates))
    }

    /// An attribute's value in one HTML tag, quoted either way or not at all.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?<=[\s"'])"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Tries each address in turn and returns the first icon that passes `decodeIcon`.
    private static func fetchFirstIcon(from candidates: [URL]) async -> NSImage? {
        for address in candidates {
            if let data = await fetchIconFile(address), let icon = decodeIcon(data) {
                return icon
            }
        }
        return nil
    }

    nonisolated private static func fetchIconFile(_ address: URL) async -> Data? {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: URLRequest(url: address,
                                                                        timeoutInterval: Limits.idleSeconds))
        } catch {
            return nil
        }
        defer { bytes.task.cancel() }
        // A site that says up front the file is too big isn't downloaded at all.
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(Limits.iconBytes) else { return nil }
        return try? await readIcon(bytes)
    }

    /// A whole icon file, or nil once it goes past `limit` bytes.
    nonisolated static func readIcon<Bytes: AsyncSequence>(_ bytes: Bytes,
                                                           limit: Int = Limits.iconBytes) async throws -> Data?
    where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { return nil }
            data.append(byte)
        }
        return data
    }

    /// The icon file LinkPresentation found, as bytes, so it gets the same checks as a
    /// favicon instead of being decoded by whatever reads it first.
    private static func loadIconData(from provider: NSItemProvider?) async -> Data? {
        guard let provider,
              let type = provider.registeredTypeIdentifiers.first(where: {
                  UTType($0)?.conforms(to: .image) == true
              }) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Decodes an icon file once it passes every check: at most `iconBytes`, one of
    /// `iconTypes`, and no side over `iconPixels`. Nil otherwise, and the tile keeps
    /// its generic icon. An .ico holds several sizes; the largest allowed one is used.
    static func decodeIcon(_ data: Data) -> NSImage? {
        guard data.count <= Limits.iconBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              iconTypes.contains(type) else { return nil }
        // Reading an image's size only reads its header. An animated GIF counts each
        // frame as an image, so only the first few are looked at.
        var best: (index: Int, width: Int, height: Int)?
        for index in 0..<min(CGImageSourceGetCount(source), 16) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, max(width, height) <= Limits.iconPixels else { continue }
            if best.map({ width * height > $0.width * $0.height }) ?? true {
                best = (index, width, height)
            }
        }
        guard let best, let image = CGImageSourceCreateImageAtIndex(source, best.index, nil) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: best.width, height: best.height))
    }

    /// Writes the image as a PNG no larger than `maxIconSide`. A .ico file holds several
    /// sizes, so the largest one is used.
    static func savePNG(_ image: NSImage, to url: URL) throws {
        let largest = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        var size = image.size
        if let largest, largest.pixelsWide > 0, largest.pixelsHigh > 0 {
            size = NSSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        }
        guard size.width > 0, size.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        let scale = min(1, maxIconSide / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width,
                                            pixelsHigh: height,
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
