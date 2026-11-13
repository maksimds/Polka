import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What "Paste" in the + menu would add (FR-19), read from the clipboard as the menu
/// opens, so the item can say what it is: "Paste 3 Files", "Paste Image".
enum Pasteable: Equatable {
    /// Files or folders copied in Finder. Stored like dropped ones.
    case files([URL])
    /// A picture: one copied in a browser, Slack or Preview, or a screenshot taken to
    /// the clipboard. Its bytes are only read once it's chosen (`PasteReader.image`).
    case image
    /// Web addresses, from a browser's "Copy Link", or text that's just an address.
    case links([URL])
    case text(String)

    var menuTitle: String {
        switch self {
        case .files(let urls):
            let folders = urls.filter(Self.isFolder).count
            if urls.count == 1 { return folders == 1 ? "Paste Folder" : "Paste File" }
            if folders == urls.count { return "Paste \(urls.count) Folders" }
            return folders == 0 ? "Paste \(urls.count) Files" : "Paste \(urls.count) Items"
        case .image:
            return "Paste Image"
        case .links(let urls):
            return urls.count == 1 ? "Paste Link" : "Paste \(urls.count) Links"
        case .text:
            return "Paste Text"
        }
    }

    /// A folder, but not a package like an app, which reads as one file, as in
    /// `ShelfItem.Draft`.
    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}

/// Reads the clipboard for "Paste". Real files come first, as in a drop, then a
/// picture, then links, then text.
enum PasteReader {
    /// Picture formats, best first: a screenshot taken to the clipboard offers both a
    /// PNG and a much larger TIFF of the same picture.
    static let imageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .webP, .pdf]

    /// What "Paste" would add, or nil when the clipboard holds nothing Polka can keep.
    static func contents(of pasteboard: NSPasteboard) -> Pasteable? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return .files(files) }

        let text = pasteboard.string(forType: .string).map(trimmed) ?? ""
        let textLink = LinkInput.link(inText: text)
        // Nothing but an address, or no text at all. Text that's more than that wins
        // over any picture or link that comes with it: Word and Numbers copy text with
        // a picture of it, and that's not what's wanted.
        let isJustAnAddress = text.isEmpty || textLink != nil

        // A browser's "Copy Image" also offers the picture's address. The picture is
        // what's wanted, as when it's dragged.
        if isJustAnAddress, hasImage(pasteboard) { return .image }
        if isJustAnAddress {
            let copiedLinks = (pasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: .URL) }
                .compactMap { URL(string: $0) }
                .filter(LinkInput.isWebAddress)
            let links = copiedLinks.isEmpty ? [textLink].compactMap { $0 } : copiedLinks
            if !links.isEmpty { return .links(links) }
        }
        return text.isEmpty ? nil : .text(text)
    }

    /// The picture on the clipboard, in its best format, for "Paste Image". Read only
    /// when it's chosen: a screenshot's TIFF can be tens of megabytes.
    static func image(from pasteboard: NSPasteboard) -> PastedImage? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in imageTypes {
                if let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
                    return PastedImage(data: data, type: type)
                }
            }
        }
        return nil
    }

    private static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        let available = Set(pasteboard.types?.map(\.rawValue) ?? [])
        return imageTypes.contains { available.contains($0.identifier) }
    }

    /// Text as it's kept: without blank lines above it or space after it, but with the
    /// first line's indent, which matters in code.
    static func trimmed(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        // Up to the start of the first line with something on it.
        if let firstVisible = text.firstIndex(where: { !$0.isWhitespace }),
           let lineStart = text[..<firstVisible].lastIndex(where: \.isNewline) {
            text = text[text.index(after: lineStart)...]
        }
        return String(text)
    }
}

/// A picture read from the clipboard, ready to be saved as a file.
struct PastedImage: Equatable, Sendable {
    struct Unreadable: Error {}

    let data: Data
    let type: UTType

    /// Formats saved just as they came, with their usual extensions. Anything else,
    /// such as a TIFF or a PDF, is turned into a PNG.
    private static let keptTypes: [(type: UTType, fileExtension: String)] =
        [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.heic, "heic")]

    /// The bytes to save and their file extension. Nil if the picture can't be read.
    /// Can take a moment for a large picture, so it's meant for a background thread.
    func encoded() -> (data: Data, fileExtension: String)? {
        if let kept = Self.keptTypes.first(where: { $0.type == type }) {
            return (data, kept.fileExtension)
        }
        return Self.png(from: data, type: type).map { ($0, "png") }
    }

    /// "Pasted Image 2026-11-13 at 10.42.15.png", named the way macOS names screenshots,
    /// so pasted pictures sort by when they were pasted.
    static func fileName(at date: Date, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted Image \(formatter.string(from: date)).\(fileExtension)"
    }

    static func png(from data: Data, type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        if type.conforms(to: .pdf) {
            guard let image = firstPage(ofPDF: data) else { return nil }
            let retina = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary
            CGImageDestinationAddImage(destination, image, retina)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            // Keeps what the picture says about itself, such as a Retina screenshot's
            // 144 dpi, so it opens at the size it was taken.
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The longest side a PDF is drawn at, in pixels.
    private static let maxPDFSide: CGFloat = 8192

    /// A PDF from the clipboard, like a shape copied in Keynote or an area selected in
    /// Preview: its first page, drawn at twice its size for Retina screens, or smaller
    /// if that would be huge. What's see-through stays see-through.
    private static func firstPage(ofPDF data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2, maxPDFSide / max(box.width, box.height))
        let width = Int((box.width * scale).rounded(.up))
        let height = Int((box.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
