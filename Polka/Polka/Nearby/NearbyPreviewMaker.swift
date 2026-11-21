import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The small pictures an offer brings (NS-6): a file's thumbnail from Quick Look, or a
/// link's saved site icon, each made into a PNG the other Mac's `NearbyPreviewImage`
/// takes: at most 256 pixels each way and 128 KB. Text has none; the other Mac draws
/// its page from the text itself.
enum NearbyPreviewMaker {
    /// The longest Quick Look gets for one file. A file it can't draw quickly goes
    /// without a picture, rather than holding the offer back.
    static let timeout: Duration = .seconds(3)

    /// A picture for each item that has one, by its place in the offer.
    static func previews(for items: [(source: ShelfItem, item: NearbyOutgoingItem)],
                         previewsFolder: URL?) async -> [Int: Data] {
        var previews: [Int: Data] = [:]
        for (index, pair) in items.enumerated() {
            let png: Data?
            switch pair.item {
            case let .file(url, _, _):
                png = await thumbnail(of: url)
            case .link:
                png = siteIcon(of: pair.source, in: previewsFolder)
            case .text:
                png = nil
            }
            if let png, NearbyPreviewImage.isAcceptable(png) { previews[index] = png }
        }
        return previews
    }

    /// Quick Look's thumbnail at 256 pixels, or 128 if that's over the size limit.
    static func thumbnail(of url: URL) async -> Data? {
        for pixels in [NearbyPreviewImage.maxSide, NearbyPreviewImage.maxSide / 2] {
            guard let image = await quickLook(url, pixels: pixels) else { return nil }
            if let png = png(image), png.count <= NearbyPreviewImage.maxBytes { return png }
        }
        return nil
    }

    private static func quickLook(_ url: URL, pixels: Int) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels / 2, height: pixels / 2),
                                                   scale: 2, representationTypes: .thumbnail)
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { QLThumbnailGenerator.shared.cancel(request) }
            return first
        }
    }

    /// The site icon saved for a link, scaled down to fit.
    static func siteIcon(of item: ShelfItem, in previewsFolder: URL?) -> Data? {
        guard let name = item.linkPreview?.iconFileName, let previewsFolder,
              let source = CGImageSourceCreateWithURL(previewsFolder.appendingPathComponent(name) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: NearbyPreviewImage.maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return png(image)
    }

    /// The image as a PNG, no larger than `NearbyPreviewImage.maxSide` each way.
    static func png(_ image: CGImage) -> Data? {
        guard let image = fitted(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The image itself if it fits, otherwise drawn smaller to fit.
    private static func fitted(_ image: CGImage) -> CGImage? {
        let side = NearbyPreviewImage.maxSide
        guard image.width > side || image.height > side else { return image }
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
