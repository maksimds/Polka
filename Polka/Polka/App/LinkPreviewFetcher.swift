import AppKit
import Combine
import LinkPresentation

/// Looks up each link's site name and icon in the background (FR-6), and saves the
/// icon in Polka's Previews folder so nothing is fetched again after a restart.
///
/// Requests go out as Polka, never disguised as a browser. A site that refuses them
/// (LinkedIn does) keeps the name taken from its address.
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

    // MARK: - Fetching and saving

    /// The site's declared name, read from the top of the page, and its icon. Throws only
    /// when the site can't be reached at all, so the link is tried again at the next launch.
    static func fetchFromWeb(_ url: URL) async throws -> Preview {
        async let pageHead = fetchPageHead(url)
        let icon = await fetchIcon(for: url)
        let head = try await pageHead
        return Preview(siteName: head.flatMap(LinkNaming.declaredSiteName(inHTML:)), icon: icon)
    }

    /// The page up to the end of its `<head>`, where the site name lives. Nil when the
    /// site answers but won't serve the page.
    private static func fetchPageHead(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var head = ""
        var length = 0
        for try await line in bytes.lines {
            head += line + "\n"
            length += line.utf8.count
            if length > 600_000 || line.range(of: "</head>", options: .caseInsensitive) != nil { break }
        }
        return head
    }

    /// The icon Apple's LinkPresentation framework finds for the page, or else the
    /// site's own /favicon.ico.
    private static func fetchIcon(for url: URL) async -> NSImage? {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        if let metadata = try? await provider.startFetchingMetadata(for: url),
           let icon = await loadImage(from: metadata.iconProvider) {
            return icon
        }
        return await fetchFavicon(for: url)
    }

    private static func fetchFavicon(for url: URL) async -> NSImage? {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = "/favicon.ico"
        guard let faviconURL = components.url,
              let result = try? await URLSession.shared.data(from: faviconURL),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: result.0)
    }

    private static func loadImage(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
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
