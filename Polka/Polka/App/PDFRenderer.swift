import AppKit
import WebKit

/// Lays a document out as PDF pages, for "Convert to PDF" (FR-18).
///
/// Word files (docx, doc) go through Quick Look's converter, the one that draws a Word
/// file when you press Space in Finder, because it keeps pictures, headers and links.
/// Polka reaches it through `qlmanage`, the tool Apple ships for testing Quick Look,
/// which can write a preview to disk as a web page. That isn't a promised API, so when
/// it gives nothing back, and for every other format, Polka uses Apple's own reader,
/// TextEdit's engine. That one reads RTF, RTFD, OpenDocument and plain text faithfully,
/// but drops a Word file's pictures and headers, and its links don't click.
///
/// Either way the text is then cut into pages of the document's own size and margins
/// with TextKit, one text container per page, and drawn into a PDF. Quick Look's web
/// page is one long flow, so a header shows once, at the top, not on every page.
enum PDFRenderer {
    /// A page's size and margins, in points.
    struct Page: Equatable {
        var size: CGSize
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat

        /// Where the text goes.
        var body: CGSize {
            CGSize(width: size.width - left - right, height: size.height - top - bottom)
        }

        /// For a document that doesn't say, like plain text: the Mac's paper size (US
        /// Letter or A4, from the region or the printer) with inch margins all round.
        @MainActor static var systemDefault: Page {
            let paper = NSPrintInfo.shared.paperSize
            let size = paper.width >= 144 && paper.height >= 144 ? paper : CGSize(width: 612, height: 792)
            return Page(size: size, top: 72, left: 72, bottom: 72, right: 72)
        }
    }

    enum Failure: Error {
        /// Neither Quick Look nor Apple's reader could read the document.
        case unreadable
        case cannotCreatePDF
    }

    /// How long Quick Look's converter, and reading its web page, may take.
    static let quickLookTimeout: TimeInterval = 30
    /// A guard against a document that never runs out of pages.
    static let maxPages = 2000

    /// Writes `source` as a PDF at `output`. `scratch` is an empty folder for Quick
    /// Look's web page, which the caller removes afterwards. Reading and drawing run
    /// off the main thread; only reading the web page needs it, and that's async.
    @MainActor
    static func render(_ source: URL, to output: URL, scratch: URL, defaultPage: Page) async throws {
        // Apple's reader goes first: it gives the page's size and margins, and the
        // text if Quick Look can't.
        let read = await Task.detached(priority: .userInitiated) { readDocument(source) }.value
        var text = read?.text.value
        var pictureSizes: [String: [CGSize]] = [:]
        if PDFConversion.wordExtensions.contains(source.pathExtension.lowercased()),
           let quickLook = await quickLookPage(for: source, in: scratch),
           let rich = await loadHTML(quickLook.url),
           // An empty page means Quick Look couldn't read it either.
           rich.length > 0 {
            text = rich
            pictureSizes = quickLook.pictureSizes
        }
        guard let text else { throw Failure.unreadable }
        let page = read?.page ?? defaultPage
        let title = source.deletingPathExtension().lastPathComponent
        let handedOver = HandedOver(text)
        try await Task.detached(priority: .userInitiated) {
            let prepared = preparingPictures(handedOver.value, sizes: pictureSizes, within: page.body)
            try draw(prepared, page: page, title: title, to: output)
        }.value
    }

    /// Text passed from one thread to another. Each one is made on one side and only
    /// read on the other after it's handed over, never by both at once, which is what
    /// makes passing it safe although `NSAttributedString` doesn't say it is.
    struct HandedOver: @unchecked Sendable {
        let value: NSAttributedString

        init(_ value: NSAttributedString) {
            self.value = value
        }
    }

    // MARK: - Apple's reader

    /// The type to read each document as. Named rather than guessed, since a file that
    /// looks like HTML inside would otherwise go to the HTML reader, which only works
    /// on the main thread.
    private static let readerTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML,
        "doc": .docFormat,
        "rtf": .rtf,
        "rtfd": .rtfd,
        "odt": .openDocument,
    ]

    /// The document's text, and its page if it says what that is. Nil if it can't be read.
    private static func readDocument(_ url: URL) -> (text: HandedOver, page: Page?)? {
        let type = url.pathExtension.lowercased()
        if type == "txt" {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = NSAttributedString(string: plainText(from: data), attributes: [.font: plainTextFont])
            return (HandedOver(text), nil)
        }
        guard let documentType = readerTypes[type] else { return nil }
        var attributes: NSDictionary?
        guard let text = try? NSAttributedString(url: url,
                                                 options: [.documentType: documentType],
                                                 documentAttributes: &attributes) else { return nil }
        let pageAttributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        return (HandedOver(text), page(from: pageAttributes))
    }

    /// The page size and margins a document asks for, or nil if it doesn't say or
    /// they make no sense (less than an inch left for the text).
    static func page(from attributes: [NSAttributedString.DocumentAttributeKey: Any]) -> Page? {
        guard let size = (attributes[.paperSize] as? NSValue)?.sizeValue,
              size.width.isFinite, size.height.isFinite,
              size.width <= 14_400, size.height <= 14_400 else { return nil }
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        let page = Page(size: size,
                        top: margin(.topMargin) ?? 72,
                        left: margin(.leftMargin) ?? 72,
                        bottom: margin(.bottomMargin) ?? 72,
                        right: margin(.rightMargin) ?? 72)
        guard min(page.top, page.left, page.bottom, page.right) >= 0,
              page.body.width >= 72, page.body.height >= 72 else { return nil }
        return page
    }

    /// TextEdit's font for plain text: the fixed-pitch font, Menlo 11 unless changed.
    private static var plainTextFont: NSFont {
        NSFont.userFixedPitchFont(ofSize: 0) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    /// A text file's contents: UTF-8 when it is, otherwise whatever encoding Foundation
    /// recognizes (UTF-16 with its byte-order mark, an older single-byte one).
    static func plainText(from data: Data) -> String {
        var text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var converted: NSString?
            _ = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted,
                                        usedLossyConversion: nil)
            text = (converted as String?) ?? String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    // MARK: - Quick Look's converter

    /// Quick Look's preview of a Word file, written out as a web page, and the size
    /// each of its pictures is shown at.
    struct QuickLookPage {
        let url: URL
        /// Point sizes by picture file, in the order the pictures appear. Reading the
        /// page keeps only each picture's pixel size, so these are put back after.
        let pictureSizes: [String: [CGSize]]
    }

    private static let quickLookTool = URL(fileURLWithPath: "/usr/bin/qlmanage")

    /// Asks Quick Look's converter for `source` as a web page, written into `folder`.
    /// Nil if it writes none, crashes, or takes longer than `quickLookTimeout`. It runs
    /// as its own process, so a document that breaks it doesn't take Polka with it.
    static func quickLookPage(for source: URL, in folder: URL) async -> QuickLookPage? {
        guard FileManager.default.isExecutableFile(atPath: quickLookTool.path) else { return nil }
        let process = Process()
        process.executableURL = quickLookTool
        // -p: a preview rather than a thumbnail; -o: written to `folder`, not shown.
        process.arguments = ["-p", "-o", folder.path, source.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited: Bool = await withCheckedContinuation { continuation in
            // A crash, or being stopped for taking too long, ends with a signal.
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationReason == .exit)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                Log.storage.error("Quick Look's converter didn't start: \(error.logCode, privacy: .public)")
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + quickLookTimeout) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
        guard exited else {
            Log.storage.info("Quick Look's converter stopped without finishing")
            return nil
        }
        let written = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let preview = written.first(where: { $0.pathExtension == "qlpreview" }) else { return nil }
        let page = preview.appendingPathComponent("Preview.html")
        guard let html = try? String(contentsOf: page, encoding: .utf8) else { return nil }
        let safe = withoutRemoteLoads(html)
        do {
            try safe.write(to: page, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return QuickLookPage(url: page, pictureSizes: pictureSizes(in: safe))
    }

    /// Reads Quick Look's web page, with its pictures, links and tables. This is WebKit
    /// underneath, so it starts on the main thread and finishes later.
    @MainActor
    private static func loadHTML(_ page: URL) async -> NSAttributedString? {
        await withCheckedContinuation { continuation in
            NSAttributedString.loadFromHTML(fileURL: page,
                                            options: [.readAccessURL: page.deletingLastPathComponent(),
                                                      .timeout: quickLookTimeout]) { text, _, error in
                if let error {
                    Log.storage.error("Couldn't read Quick Look's page: \(error.logCode, privacy: .public)")
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// Attributes that make a page load something, besides a link's `href`, which is
    /// only followed when clicked.
    private static let loadingAttributes: Set<String> = [
        "src", "srcset", "href", "background", "poster", "data", "lowsrc", "dynsrc", "longdesc",
        "xlink:href", "action", "formaction", "ping", "manifest", "codebase", "archive", "cite",
    ]

    /// Quick Look's page only points at the pictures it writes next to it, and leaves
    /// out the address of a picture a document links to on the web rather than holds.
    /// Reading the page would fetch anything on the web it did point at, though (a
    /// Content-Security-Policy tag doesn't stop that), so in case a later macOS lets
    /// one through, everything the page would load from elsewhere is taken out first:
    /// scripts, stylesheets and frames, and any address that isn't a local file or
    /// data. Links stay.
    static func withoutRemoteLoads(_ html: String) -> String {
        var html = html
        html = replacing(#"<script\b[\s\S]*?</script\s*>"#, in: html, with: "")
        html = replacing(#"<(?:link|base|iframe|frame|object|embed|applet)\b[^>]*>"#, in: html, with: "")
        html = replacing(#"<meta\b[^>]*\bhttp-equiv\b[^>]*>"#, in: html, with: "")
        html = replacing(#"@import\b[^;]*;?"#, in: html, with: "")
        html = replacing(#"url\(\s*['"]?\s*(?!(?:data|file):)(?:[a-z][a-z0-9+.\-]*:|//)[^)]*\)"#, in: html, with: "url()")

        // Every tag but <a>: blank any address it would load from elsewhere.
        let tag = regex(#"<(?!a\b)([a-z][a-z0-9:-]*)\b([^>]*)>"#)
        let attribute = regex(#"([^\s=/>"']+)(\s*=\s*)("[^"]*"|'[^']*'|[^\s"'>]+)"#)
        var result = ""
        var rest = html.startIndex
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(match.range, in: html),
                  let attributes = Range(match.range(at: 2), in: html) else { continue }
            result += html[rest..<attributes.lowerBound]
            let text = String(html[attributes])
            var cleaned = ""
            var cursor = text.startIndex
            for found in attribute.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let name = Range(found.range(at: 1), in: text),
                      let value = Range(found.range(at: 3), in: text) else { continue }
                let unquoted = text[value].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                cleaned += text[cursor..<value.lowerBound]
                if loadingAttributes.contains(text[name].lowercased()), loadsFromElsewhere(unquoted) {
                    cleaned += "\"\""
                } else {
                    cleaned += text[value]
                }
                cursor = value.upperBound
            }
            cleaned += text[cursor...]
            result += cleaned
            result += html[attributes.upperBound..<whole.upperBound]
            rest = whole.upperBound
        }
        result += html[rest...]
        return result
    }

    /// True for an address with a scheme other than `file:` or `data:`, or one that
    /// starts with `//`, which takes the scheme of the page.
    private static func loadsFromElsewhere(_ address: String) -> Bool {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("//") { return true }
        guard address.range(of: #"^[a-z][a-z0-9+.\-]*:"#, options: .regularExpression) != nil else { return false }
        return !address.hasPrefix("file:") && !address.hasPrefix("data:")
    }

    /// The point size each picture is shown at. Quick Look sizes a picture with a
    /// class of its own (`.s7.s7.s7 {width:240; height:120;}`), in points.
    static func pictureSizes(in html: String) -> [String: [CGSize]] {
        var classSizes: [String: CGSize] = [:]
        let rule = regex(#"\.([a-z_][\w-]*)(?:\.\1)*\s*\{([^}]*)\}"#)
        for match in rule.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let name = Range(match.range(at: 1), in: html),
                  let body = Range(match.range(at: 2), in: html),
                  let size = size(inStyle: String(html[body])) else { continue }
            classSizes[String(html[name])] = size
        }
        var sizes: [String: [CGSize]] = [:]
        let image = regex(#"<img\b[^>]*>"#)
        for match in image.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let source = value(of: "src", in: tag), !source.isEmpty else { continue }
            let size = value(of: "style", in: tag).flatMap(size(inStyle:))
                ?? value(of: "class", in: tag)?.split(separator: " ").lazy.compactMap { classSizes[String($0)] }.first
            if let size {
                sizes[source.removingPercentEncoding ?? source, default: []].append(size)
            }
        }
        return sizes
    }

    /// The width and height a style gives, both of them, or nil.
    private static func size(inStyle style: String) -> CGSize? {
        func number(_ key: String) -> CGFloat? {
            let pattern = regex(#"(?:^|[;\s{])"# + key + #"\s*:\s*([0-9]*\.?[0-9]+)"#)
            guard let match = pattern.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
                  let range = Range(match.range(at: 1), in: style),
                  let value = Double(style[range]), value > 0 else { return nil }
            return CGFloat(value)
        }
        guard let width = number("width"), let height = number("height") else { return nil }
        return CGSize(width: width, height: height)
    }

    /// An attribute's value in a tag, in double quotes as Quick Look writes them.
    private static func value(of attribute: String, in tag: String) -> String? {
        let pattern = regex(#"\b"# + attribute + #"\s*=\s*"([^"]*)""#)
        guard let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed, so a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: text,
                                                range: NSRange(text.startIndex..., in: text),
                                                withTemplate: template)
    }

    // MARK: - Pages

    /// Puts pictures back at the size the document shows them (`sizes`, by file name),
    /// and shrinks any too big for a page to fit, keeping their shape. A picture that
    /// fits on no page would stop the text from flowing past it.
    static func preparingPictures(_ text: NSAttributedString,
                                  sizes: [String: [CGSize]],
                                  within body: CGSize) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var sizes = sizes
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let wrapper = attachment.fileWrapper
            let image = wrapper?.regularFileContents.flatMap(NSImage.init(data:))
            var size: CGSize?
            if let name = wrapper?.preferredFilename ?? wrapper?.filename,
               var waiting = sizes[name], !waiting.isEmpty {
                size = waiting.removeFirst()
                sizes[name] = waiting
            }
            let shown = size ?? natural(attachment, image: image)
            guard shown.width > 0, shown.height > 0 else { return }
            let scale = min(1, body.width / shown.width, body.height / shown.height)
            // A picture shown at its own size and fitting on the page stays as it is.
            guard size != nil || scale < 1 else { return }
            let fitted = CGSize(width: shown.width * scale, height: shown.height * scale)
            if let image {
                // The page's reader draws a picture at its pixel size whatever it's
                // told, so it's given a fresh attachment that's just the image.
                let sized = NSTextAttachment()
                sized.image = image
                sized.bounds = CGRect(origin: .zero, size: fitted)
                result.addAttribute(.attachment, value: sized, range: range)
            } else {
                attachment.bounds = CGRect(origin: .zero, size: fitted)
            }
        }
        return result
    }

    /// The size an attachment takes as it is.
    private static func natural(_ attachment: NSTextAttachment, image: NSImage?) -> CGSize {
        if attachment.bounds.size != .zero { return attachment.bounds.size }
        if let cell = attachment.attachmentCell { return cell.cellSize() }
        return image?.size ?? .zero
    }

    /// Cuts `text` into pages and draws them into a PDF at `output`. Web and mail links
    /// stay clickable; any other kind is left as plain text, as Polka does for links.
    private static func draw(_ text: NSAttributedString, page: Page, title: String, to output: URL) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: page.body)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            // Something that fits on no page would add empty pages forever, so the
            // pages stop at the first one that takes nothing.
            if layout.glyphRange(for: container).length == 0, !containers.isEmpty {
                layout.removeTextContainer(at: containers.count)
                break
            }
            containers.append(container)
        } while NSMaxRange(layout.glyphRange(for: containers[containers.count - 1])) < layout.numberOfGlyphs
            && containers.count < maxPages

        var mediaBox = CGRect(origin: .zero, size: page.size)
        let info = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Polka"] as CFDictionary
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, info) else {
            throw Failure.cannotCreatePDF
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = NSPoint(x: page.left, y: page.top)
        for container in containers {
            let glyphs = layout.glyphRange(for: container)
            context.beginPDFPage(nil)
            context.saveGState()
            // TextKit draws from the top down; a PDF page counts up from the bottom.
            context.translateBy(x: 0, y: page.size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            // In the light appearance, so text with the system's text color is black
            // on the white page even in Dark Mode.
            let drawPage = {
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            }
            if let light = NSAppearance(named: .aqua) {
                light.performAsCurrentDrawingAppearance(drawPage)
            } else {
                drawPage()
            }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            addLinks(in: glyphs, of: container, layout: layout, storage: storage, page: page, to: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Makes each web or mail link on the page clickable in the PDF.
    private static func addLinks(in glyphs: NSRange,
                                 of container: NSTextContainer,
                                 layout: NSLayoutManager,
                                 storage: NSTextStorage,
                                 page: Page,
                                 to context: CGContext) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, LinkInput.isWebAddress(url) || url.scheme?.lowercased() == "mailto" else { return }
            let linkGlyphs = NSIntersectionRange(layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                                 glyphs)
            guard linkGlyphs.length > 0 else { return }
            layout.enumerateEnclosingRects(forGlyphRange: linkGlyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let area = CGRect(x: page.left + rect.minX,
                                  y: page.size.height - page.top - rect.maxY,
                                  width: rect.width,
                                  height: rect.height)
                context.setURL(url as CFURL, for: area)
            }
        }
    }
}
