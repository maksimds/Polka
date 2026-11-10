import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons, thumbnails and site icons for shelf items, kept in memory so reopening the
/// panel is instant.
@MainActor
final class ShelfItemImages {
    private let previewsFolder: URL?
    private let icons = NSCache<NSUUID, NSImage>()
    private let thumbnails = NSCache<NSUUID, NSImage>()
    private let siteIcons = NSCache<NSString, NSImage>()

    init(previewsFolder: URL? = nil) {
        self.previewsFolder = previewsFolder
    }

    /// The best image ready right now: a file's thumbnail or a link's site icon if
    /// there is one, otherwise the generic icon.
    func image(for item: ShelfItem) -> NSImage {
        let key = item.id as NSUUID
        if let thumbnail = thumbnails.object(forKey: key) { return thumbnail }
        if let siteIcon = siteIcon(for: item) { return siteIcon }
        if let icon = icons.object(forKey: key) { return icon }
        let icon = makeIcon(for: item)
        icons.setObject(icon, forKey: key)
        return icon
    }

    /// Asks Quick Look for a preview of the file's contents.
    /// Returns nil when there is none, and the tile keeps showing the icon.
    func loadThumbnail(for item: ShelfItem, side: CGFloat) async -> NSImage? {
        guard item.kind == .file else { return nil }
        let key = item.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }

        let request = QLThumbnailGenerator.Request(fileAt: item.url,
                                                   size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        thumbnails.setObject(result.nsImage, forKey: key)
        return result.nsImage
    }

    private func siteIcon(for item: ShelfItem) -> NSImage? {
        guard let name = item.linkPreview?.iconFileName, let previewsFolder else { return nil }
        if let cached = siteIcons.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: previewsFolder.appendingPathComponent(name)) else { return nil }
        siteIcons.setObject(image, forKey: name as NSString)
        return image
    }

    private func makeIcon(for item: ShelfItem) -> NSImage {
        switch item.source {
        case .file(let path, _): return NSWorkspace.shared.icon(forFile: path)
        case .link: return NSWorkspace.shared.icon(for: .internetLocation)
        }
    }
}
