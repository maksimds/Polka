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
    /// By icon file name. An icon file never changes, so neither does its style.
    private var siteIconStyles: [String: SiteIconStyle] = [:]
    /// By image, which is kept and reused for as long as it's shown.
    private let visibleBounds = NSCache<NSImage, NSValue>()

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

    // MARK: - Visible part

    /// The part of `image` that isn't see-through, as shares of its width and height,
    /// measured from the top left: what a tile counts as its picture. A folder or a
    /// document icon leaves see-through room around its drawing; a photo has none.
    /// Measured once per image.
    func visibleBounds(of image: NSImage) -> CGRect {
        if let known = visibleBounds.object(forKey: image) { return known.rectValue }
        let bounds = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(Self.visibleBounds(of:)) ?? Self.wholeImage
        visibleBounds.setObject(NSValue(rect: bounds), forKey: image)
        return bounds
    }

    /// All of an image, as shares of its width and height.
    nonisolated static let wholeImage = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The smallest rectangle around every pixel that's at least a tenth opaque, on a
    /// 64 × 64 copy, as shares of the image's width and height from the top left.
    /// All of it when nothing shows.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return wholeImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return wholeImage }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var left = side, top = side, right = -1, bottom = -1
        // Rows in memory run from the top of the image down.
        for row in 0..<side {
            for column in 0..<side where pixels[(row * side + column) * 4 + 3] >= 26 {
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right >= 0 else { return wholeImage }
        let scale = CGFloat(side)
        return CGRect(x: CGFloat(left) / scale,
                      y: CGFloat(top) / scale,
                      width: CGFloat(right - left + 1) / scale,
                      height: CGFloat(bottom - top + 1) / scale)
    }

    // MARK: - Site icons

    /// How a link's tile shows its site's icon, or nil when the link has no icon of
    /// its own. Worked out once per icon.
    func siteIconStyle(for item: ShelfItem) -> SiteIconStyle? {
        guard let key = Self.siteIconKey(for: item), let icon = siteIcon(for: item) else { return nil }
        if let known = siteIconStyles[key] { return known }
        let isLarge = Self.isLargeSiteIcon(icon)
        let style = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { Self.style(of: $0, isLarge: isLarge) } ?? (isLarge ? .tile : .logo)
        siteIconStyles[key] = style
        return style
    }

    /// Icons at least this wide are made for phone home screens; smaller ones are
    /// favicons.
    static let largeSiteIconWidth: CGFloat = 96

    static func isLargeSiteIcon(_ icon: NSImage) -> Bool {
        icon.size.width >= largeSiteIconWidth
    }

    /// More than this share of a large icon's outer edge is see-through: it's a bare
    /// logo, not a tile. A tile is solid to its edges (a few corner pixels at most, if
    /// it comes rounded); a logo stands on nothing.
    nonisolated private static let logoEdgeShare = 0.5

    /// A large icon is a tile when it's solid to its edges. Anything else, and every
    /// favicon, is a logo: dark ones go on the light card. A favicon never fills the
    /// square, even a solid one, since it's drawn for 16 to 64 pixels and would blur.
    nonisolated static func style(of image: CGImage, isLarge: Bool) -> SiteIconStyle {
        if isLarge, !hasSeeThroughEdge(image) {
            return .tile
        }
        return needsLightBackground(image) ? .darkLogo : .logo
    }

    /// True when more than `logoEdgeShare` of the image's outermost ring of pixels is
    /// see-through, measured on a 32 × 32 copy like `needsLightBackground`.
    nonisolated private static func hasSeeThroughEdge(_ image: CGImage) -> Bool {
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

        var edge = 0
        var seeThrough = 0
        for y in 0..<side {
            for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                edge += 1
                if pixels[(y * side + x) * 4 + 3] < 26 { seeThrough += 1 }
            }
        }
        return Double(seeThrough) / Double(edge) > logoEdgeShare
    }

    private func siteIcon(for item: ShelfItem) -> NSImage? {
        guard let preview = item.linkPreview, let name = preview.iconFileName,
              let key = Self.siteIconKey(for: item), let previewsFolder else { return nil }
        if let cached = siteIcons.object(forKey: key as NSString) { return cached }
        guard let image = NSImage(contentsOf: previewsFolder.appendingPathComponent(name)) else { return nil }
        siteIcons.setObject(image, forKey: key as NSString)
        return image
    }

    /// An icon file keeps its name when "Edit Address" points the link at another
    /// site, so the icon is remembered by its name and when it was fetched.
    private static func siteIconKey(for item: ShelfItem) -> String? {
        guard let preview = item.linkPreview, let name = preview.iconFileName else { return nil }
        return "\(name) \(preview.fetchedAt.timeIntervalSinceReferenceDate)"
    }

    private func makeIcon(for item: ShelfItem) -> NSImage {
        switch item.source {
        case .file(let path, _): return NSWorkspace.shared.icon(forFile: path)
        case .link: return NSWorkspace.shared.icon(for: .internetLocation)
        case .text(let text): return Self.textPage(for: text)
        case .shelfFolder: return Self.shelfFolderPicture
        }
    }

    // MARK: - Shelf folders

    /// A shelf folder's picture (FR-26): Finder's own folder icon in light grey glass,
    /// so it reads as a folder at a glance but isn't mistaken for a blue folder on
    /// disk. Made once, from the icon of whichever macOS this is.
    static let shelfFolderPicture: NSImage = {
        let side = ShelfFolderPicture.pixels
        guard let image = ShelfFolderPicture.make(from: NSWorkspace.shared.icon(for: .folder), pixels: side) else {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let points = CGFloat(side) / ShelfFolderPicture.scale
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }()

    // MARK: - Text

    /// A text item's page, shaped like a letter-size sheet, as tall as the picture square.
    nonisolated static let textPageSize = CGSize(width: 40, height: 52)

    /// A text item's picture: a small white page with the start of the text on it, the
    /// way Finder shows a text file. Being page-shaped, it gets its remove badge on the
    /// page's corner, like a document's thumbnail. It's drawn each time it's shown, so
    /// it's sharp at any scale.
    nonisolated static func textPage(for text: String) -> NSImage {
        // Plenty to fill the page; the rest wouldn't show.
        let start = String(text.prefix(400)).replacingOccurrences(of: "\t", with: "    ")
        return NSImage(size: textPageSize, flipped: true) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 5.5),
                .foregroundColor: NSColor(white: 0.2, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            let textArea = rect.insetBy(dx: 4, dy: 4.5)
            NSGraphicsContext.saveGraphicsState()
            // Lines that don't fit stop at the page's margin rather than run past it.
            NSBezierPath(rect: textArea).setClip()
            NSAttributedString(string: start, attributes: attributes)
                .draw(with: textArea, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}

/// How a link's tile shows its site's icon. How big it's drawn comes from the icon:
/// a favicon stays small, a large logo gets more room.
enum SiteIconStyle: Equatable {
    /// A large icon made as a tile, with its own background to the edges, like
    /// GitHub's: it fills the rounded square.
    case tile
    /// A logo on a see-through background, like Shopify's bag, or a favicon, like
    /// LinkedIn's: on dark glass, with room around it.
    case logo
    /// A logo or favicon that's dark: on the light card instead, since dark glass
    /// would hide it.
    case darkLogo
}

/// Turns Finder's folder icon into a shelf folder's light grey glass (FR-26), the way
/// Polka's other light glass looks (the remove badge, the light card): each part of the
/// folder keeps its own shading, the back and tab a little darker than the front, but
/// in grey, by brightness; a sharp line of light runs along every edge that faces up
/// and a touch of shade along every edge that faces down; a soft sheen lights the top;
/// and it's a little see-through, so a colored panel tints it. The icon's shadow stays
/// black.
enum ShelfFolderPicture {
    /// The picture square, as `ShelfItemTile.imageSide`.
    static let points: CGFloat = 52
    /// Drawn at four times the picture square and scaled down to the screen.
    static let scale: CGFloat = 4
    static let pixels = Int(points * scale)

    /// The greys the folder's darkest and brightest parts become.
    static let darkGrey = 0.66
    static let lightGrey = 0.94
    /// How opaque the glass is.
    static let opacity = 0.94
    /// How bright the light along the top edges is, how strong the sheen across the
    /// top, and how dark the shade along the bottom edges, each from 0 to 1.
    static let rimLight = 0.9
    static let sheen = 0.35
    static let shade = 0.12

    /// The brightness, from 0 to 1, of the blue icon's darkest and brightest parts,
    /// the back and the top of the front, which become `darkGrey` and `lightGrey`.
    private static let darkestIcon = 0.40
    private static let brightestIcon = 0.78

    /// `icon` drawn `pixels` wide and made glass. Nil if there's nothing to draw into.
    nonisolated static func make(from icon: NSImage, pixels side: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let count = side * side

        // The folder's own coverage and grey, apart from its shadow's.
        var folderAlpha = [Double](repeating: 0, count: count)
        var shadowAlpha = [Double](repeating: 0, count: count)
        var grey = [Double](repeating: 0, count: count)
        var top = side, bottom = 0
        for index in 0..<count {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0 else { continue }
            // Stored multiplied by their opacity.
            let red = Double(pixels[index * 4]) / 255 / alpha
            let green = Double(pixels[index * 4 + 1]) / 255 / alpha
            let blue = Double(pixels[index * 4 + 2]) / 255 / alpha
            // The shadow is black; the folder is bright blue.
            let shadow = min(max(1 - max(red, green, blue) / 0.47, 0), 1)
            let brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let share = min(max((brightness - darkestIcon) / (brightestIcon - darkestIcon), 0), 1)
            grey[index] = darkGrey + (lightGrey - darkGrey) * share
            folderAlpha[index] = alpha * (1 - shadow)
            shadowAlpha[index] = alpha * shadow
            if folderAlpha[index] > 0.5 {
                top = min(top, index / side)
                bottom = max(bottom, index / side)
            }
        }

        // The edges are found by comparing each pixel with the one 0.75 pt above or
        // below, as glass lettering finds its strokes' edges (`GlassGlyph`).
        let edge = max(Int((Glass.rimWidth * CGFloat(side) / points).rounded()), 1)
        let height = Double(max(bottom - top, 1))
        for index in 0..<count where folderAlpha[index] > 0 || shadowAlpha[index] > 0 {
            let row = index / side
            let alpha = folderAlpha[index]
            var value = grey[index]
            // Brightest at the top, gone by the middle.
            let depth = Double(row - top) / height
            value += sheen * max(0, 0.5 - depth) / 0.5 * (1 - value)
            let above = row >= edge ? folderAlpha[index - edge * side] : 0
            let below = row + edge < side ? folderAlpha[index + edge * side] : 0
            value += (1 - value) * max(0, alpha - above) * rimLight
            value *= 1 - max(0, alpha - below) * shade
            // The glass over its black shadow.
            let glass = alpha * opacity
            let total = glass + shadowAlpha[index] * (1 - glass)
            let stored = UInt8(min(max(value * glass, 0), 1) * 255)
            pixels[index * 4] = stored
            pixels[index * 4 + 1] = stored
            pixels[index * 4 + 2] = stored
            pixels[index * 4 + 3] = UInt8(min(max(total, 0), 1) * 255)
        }
        return context.makeImage()
    }
}
