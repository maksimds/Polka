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
    ///
    /// A dark drawing on a transparent background (a black logo or symbol, say) would
    /// vanish against the black shelf. Those are asked for again in icon mode, where
    /// Quick Look draws them on a white page with a thin border, as Finder shows them.
    /// Everything else keeps the plain thumbnail, since icon mode also frames photos.
    func loadThumbnail(for item: ShelfItem, side: CGFloat) async -> NSImage? {
        guard item.kind == .file else { return nil }
        let key = item.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }

        guard var result = await thumbnail(of: item.url, side: side, iconMode: false) else { return nil }
        if Self.needsLightBackground(result.cgImage),
           let onPage = await thumbnail(of: item.url, side: side, iconMode: true) {
            result = onPage
        }
        thumbnails.setObject(result.nsImage, forKey: key)
        return result.nsImage
    }

    private func thumbnail(of url: URL, side: CGFloat, iconMode: Bool) async -> QLThumbnailRepresentation? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        request.iconMode = iconMode
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    }

    // MARK: - Dark images

    /// At least this share of the image is see-through...
    nonisolated private static let seeThroughShare = 0.2
    /// ...and what's visible is at most this bright (0 is black, 1 is white).
    nonisolated private static let darkLuminance = 0.35

    /// True for a partly see-through image whose visible part is dark, which would
    /// all but disappear on the black shelf. Measured on a 32 × 32 copy, which is
    /// plenty to tell and takes no time.
    nonisolated static func needsLightBackground(_ image: CGImage) -> Bool {
        let side = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var seeThrough = 0
        var coverage = 0.0
        // Colors are stored already multiplied by their opacity, so summing them gives
        // a brightness in which faint pixels count for less.
        var brightness = 0.0
        for pixel in 0..<(side * side) {
            let red = Double(pixels[pixel * 4])
            let green = Double(pixels[pixel * 4 + 1])
            let blue = Double(pixels[pixel * 4 + 2])
            let alpha = Double(pixels[pixel * 4 + 3])
            if alpha < 26 { seeThrough += 1 }
            coverage += alpha
            brightness += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        // Nothing visible at all: there's nothing a background would help show.
        guard coverage > 0 else { return false }
        return Double(seeThrough) / Double(side * side) >= seeThroughShare
            && brightness / coverage <= darkLuminance
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
