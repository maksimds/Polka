import AppKit
import PDFKit
import Testing
@testable import Polka

/// "Convert to PDF" (FR-18), with real documents in a temporary folder that stands in
/// for yours, and another for Polka's Copies folder.
@MainActor
struct PDFConversionTests {
    private let fileManager = FileManager.default
    private let letter = PDFRenderer.Page(size: CGSize(width: 612, height: 792), top: 72, left: 72, bottom: 72, right: 72)

    /// Finds the test bundle, where the sample Word file is.
    private final class BundleToken {}

    /// A temporary folder holding `Documents` (yours) and `Copies` (Polka's), removed
    /// when `body` returns.
    private func withFolders(_ body: (_ documents: URL, _ copies: ShelfCopies) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path)
            try? fileManager.removeItem(at: root)
        }
        try await body(documents, ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true)))
    }

    private func makeRTF(_ text: String, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let data = try string.data(from: NSRange(location: 0, length: string.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url)
        return url
    }

    private func makeStore(_ urls: [URL], storageMode: ShelfItem.StorageMode = .reference, sort: ShelfSort = .none) -> ShelfStore {
        let store = ShelfStore(sort: sort)
        // Added one at a time to the front, so the first URL ends up first.
        for url in urls.reversed() {
            store.add([ShelfItem.Draft(fileURL: url, storageMode: storageMode)])
        }
        return store
    }

    private func path(of item: ShelfItem) -> String? {
        guard case .file(let path, _) = item.source else { return nil }
        return path
    }

    private func item(_ id: ShelfItem.ID, in store: ShelfStore) -> ShelfItem? {
        store.items.first { $0.id == id }
    }

    // MARK: - Names and types

    @Test func thePDFIsNamedAfterTheFile() {
        #expect(PDFConversion.pdfName(for: "report.docx") == "report.pdf")
        #expect(PDFConversion.pdfName(for: "Q3 report.final.doc") == "Q3 report.final.pdf")
        #expect(PDFConversion.pdfName(for: "notes.TXT") == "notes.pdf")
    }

    @Test func aTakenNameGetsTheNextNumberAsInFinder() {
        #expect(PDFConversion.pdfName(for: "report.docx", attempt: 1) == "report.pdf")
        #expect(PDFConversion.pdfName(for: "report.docx", attempt: 2) == "report 2.pdf")
        #expect(PDFConversion.pdfName(for: "report.docx", attempt: 3) == "report 3.pdf")
    }

    @Test func onlyDocumentFilesCanBeConverted() throws {
        try withTemporaryFolder { folder in
            let names = ["a.docx", "b.DOCX", "c.doc", "d.rtf", "e.odt", "f.txt", "g.md", "h.swift", "i.pdf", "j.pages"]
            let store = makeStore(names.map { folder.appendingPathComponent($0) })
            let convertible = store.items.filter(PDFConversion.canConvert).map(\.title)
            #expect(convertible == ["a.docx", "b.DOCX", "c.doc", "d.rtf", "e.odt", "f.txt"])

            // A folder that happens to end in ".txt" isn't a document, and neither is a link.
            let folderNamedLikeText = folder.appendingPathComponent("notes.txt", isDirectory: true)
            try fileManager.createDirectory(at: folderNamedLikeText, withIntermediateDirectories: true)
            store.add([ShelfItem.Draft(fileURL: folderNamedLikeText),
                       ShelfItem.Draft(linkURL: URL(string: "https://example.com/page.docx")!)])
            #expect(store.items.filter(PDFConversion.canConvert).count == 6)
        }
    }

    @Test func anRTFDPackageCountsAsADocument() throws {
        try withTemporaryFolder { folder in
            let package = folder.appendingPathComponent("story.rtfd", isDirectory: true)
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            let store = makeStore([package])
            #expect(store.items.first.map(PDFConversion.canConvert) == true)
        }
    }

    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        try body(folder)
    }

    // MARK: - Where the new tile lands

    @Test func aNewItemCanLandRightAfterAnother() {
        let store = makeStore(["/x/a.docx", "/x/b.docx", "/x/c.docx"].map(URL.init(fileURLWithPath:)))
        let middle = store.items[1].id
        let added = store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/x/b.pdf"))], after: middle)
        #expect(added.added.count == 1)
        #expect(store.items.map(\.title) == ["a.docx", "b.docx", "b.pdf", "c.docx"])
        #expect(store.items.map(\.sortOrder) == [0, 1, 2, 3])
    }

    @Test func anItemWhoseNeighborIsGoneLandsAtTheFront() {
        let store = makeStore(["/x/a.docx", "/x/b.docx"].map(URL.init(fileURLWithPath:)))
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/x/c.pdf"))], after: UUID())
        #expect(store.items.map(\.title) == ["c.pdf", "a.docx", "b.docx"])
    }

    @Test func aSortedShelfPutsItInItsSortedSpot() {
        let store = makeStore(["/x/a.docx", "/x/m.docx", "/x/z.docx"].map(URL.init(fileURLWithPath:)), sort: .name)
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/x/b.pdf"))], after: store.items[2].id)
        #expect(store.items.map(\.title) == ["a.docx", "b.pdf", "m.docx", "z.docx"])
    }

    // MARK: - Reading

    @Test func pageSizeAndMarginsComeFromTheDocument() {
        let a4: [NSAttributedString.DocumentAttributeKey: Any] = [
            .paperSize: NSValue(size: NSSize(width: 595.3, height: 841.9)),
            .leftMargin: NSNumber(value: 56.7), .rightMargin: NSNumber(value: 56.7),
            .topMargin: NSNumber(value: 56.7), .bottomMargin: NSNumber(value: 56.7),
        ]
        let page = PDFRenderer.page(from: a4)
        #expect(page?.size == CGSize(width: 595.3, height: 841.9))
        #expect(page?.left == 56.7)
        #expect(page?.top == 56.7)
    }

    @Test func pageSizesThatMakeNoSenseAreIgnored() {
        #expect(PDFRenderer.page(from: [:]) == nil)
        // Margins that leave no room for the text.
        #expect(PDFRenderer.page(from: [.paperSize: NSValue(size: NSSize(width: 200, height: 200)),
                                        .leftMargin: NSNumber(value: 90), .rightMargin: NSNumber(value: 90)]) == nil)
        #expect(PDFRenderer.page(from: [.paperSize: NSValue(size: NSSize(width: 1e9, height: 792))]) == nil)
    }

    @Test func plainTextIsReadInItsOwnEncoding() {
        #expect(PDFRenderer.plainText(from: Data("Привет, мир".utf8)) == "Привет, мир")
        // UTF-8 with a byte-order mark, which isn't part of the text.
        #expect(PDFRenderer.plainText(from: Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8)) == "Hi")
        // UTF-16 with its byte-order mark, as Windows Notepad saved it.
        let utf16 = "Grüße".data(using: .utf16)!
        #expect(PDFRenderer.plainText(from: utf16) == "Grüße")
    }

    // MARK: - Quick Look's page

    @Test func whatThePageWouldLoadFromElsewhereIsTakenOutButLinksStay() {
        let html = """
            <html><head><meta charset="utf-8"><link rel="stylesheet" href="https://x.example/s.css">
            <meta http-equiv="refresh" content="0;url=https://x.example/"><base href="https://x.example/">
            <style>.s1 {background:url(https://x.example/bg.png); color:red;} @import "https://x.example/i.css";</style>
            <script>fetch("https://x.example/")</script></head>
            <body><p style="color:#0563c1"><a href="https://example.com/">example.com</a></p>
            <img src="Attachment1.png" class="s7"><img src="https://x.example/pixel.png">
            <img SRC='//x.example/p.png'><img srcset="https://x.example/a.png 2x">
            <img src="data:image/png;base64,AAAA"><iframe src="https://x.example/f"></iframe></body></html>
            """
        let safe = PDFRenderer.withoutRemoteLoads(html)
        #expect(!safe.contains("x.example"))
        #expect(safe.contains(#"<a href="https://example.com/">"#))
        #expect(safe.contains(#"src="Attachment1.png""#))
        #expect(safe.contains("data:image/png;base64,AAAA"))
        #expect(safe.contains(#"<meta charset="utf-8">"#))
        #expect(safe.contains("color:red"))
        #expect(safe.contains(#"style="color:#0563c1""#))
    }

    @Test func pictureSizesComeFromQuickLooksClasses() {
        let html = """
            <style type="text/css">.s1.s1.s1 {width: 481; min-height: 844; padding-left: 56;}</style>
            <style type="text/css">.s7.s7.s7 {width:240; height:120;}</style>
            <p class="s3"><img src="Attachment1.png" class="s7"></p>
            <p><img src="Attachment2.png" style="width:30; height:15"></p>
            <p><img class="s7"></p>
            """
        let sizes = PDFRenderer.pictureSizes(in: html)
        #expect(sizes["Attachment1.png"] == [CGSize(width: 240, height: 120)])
        #expect(sizes["Attachment2.png"] == [CGSize(width: 30, height: 15)])
        #expect(sizes.count == 2)
    }

    @Test func picturesAreShownAtTheirSizeAndShrunkToFitAPage() throws {
        let image = NSImage(size: NSSize(width: 100, height: 50), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:]))
        func attachment(named name: String) -> NSAttributedString {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = name
            return NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        }
        let text = NSMutableAttributedString()
        text.append(attachment(named: "small.png"))
        text.append(attachment(named: "huge.png"))
        let prepared = PDFRenderer.preparingPictures(text,
                                                     sizes: ["small.png": [CGSize(width: 240, height: 120)],
                                                             "huge.png": [CGSize(width: 2000, height: 1000)]],
                                                     within: CGSize(width: 500, height: 700))
        var bounds: [CGSize] = []
        prepared.enumerateAttribute(.attachment, in: NSRange(location: 0, length: prepared.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                bounds.append(attachment.bounds.size)
            }
        }
        #expect(bounds == [CGSize(width: 240, height: 120), CGSize(width: 500, height: 250)])
    }

    // MARK: - Converting

    @Test func aDocumentGetsAPDFNextToItAndATileRightAfterIt() async throws {
        try await withFolders { documents, copies in
            let first = try makeRTF("First document", named: "first.rtf", in: documents)
            let notes = try makeRTF("Meeting notes for Thursday", named: "notes.rtf", in: documents)
            let store = makeStore([first, notes])
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            let outcome = await converter.convert([store.items[0].id])

            let pdf = documents.appendingPathComponent("first.pdf")
            #expect(outcome.failed.isEmpty)
            #expect(outcome.keptInPolka.isEmpty)
            #expect(PDFDocument(url: pdf)?.string?.contains("First document") == true)
            #expect(store.items.map(\.title) == ["first.rtf", "first.pdf", "notes.rtf"])
            #expect(store.items[1].storageMode == .reference)
            #expect(store.convertingItemIDs.isEmpty)
            // The draft and scratch folders are gone again.
            #expect(copies.folderNames().isEmpty)
        }
    }

    @Test func anExistingPDFIsNeverOverwritten() async throws {
        try await withFolders { documents, copies in
            let report = try makeRTF("The new report", named: "report.rtf", in: documents)
            try Data("old".utf8).write(to: documents.appendingPathComponent("report.pdf"))
            try Data("older".utf8).write(to: documents.appendingPathComponent("report 2.pdf"))
            let store = makeStore([report])
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            _ = await converter.convert([store.items[0].id])

            #expect(try String(contentsOf: documents.appendingPathComponent("report.pdf"), encoding: .utf8) == "old")
            #expect(try String(contentsOf: documents.appendingPathComponent("report 2.pdf"), encoding: .utf8) == "older")
            let made = documents.appendingPathComponent("report 3.pdf")
            #expect(PDFDocument(url: made)?.string?.contains("The new report") == true)
            #expect(store.items.map(\.title) == ["report.rtf", "report 3.pdf"])
        }
    }

    /// Quick Look's converter is what keeps a Word file's pictures; Apple's own reader
    /// drops them. If this fails, a macOS update has probably changed `qlmanage`.
    @Test func aWordFileKeepsItsPictureLinkAndPageThroughQuickLook() async throws {
        let sample = try #require(Bundle(for: BundleToken.self).url(forResource: "WordSample", withExtension: "docx"))
        try await withFolders { documents, copies in
            let document = documents.appendingPathComponent("WordSample.docx")
            try fileManager.copyItem(at: sample, to: document)
            let store = makeStore([document])
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            let outcome = await converter.convert([store.items[0].id])
            #expect(outcome.failed.isEmpty)

            let pdf = try #require(PDFDocument(url: documents.appendingPathComponent("WordSample.pdf")))
            let firstPage = try #require(pdf.page(at: 0))
            // The document's own A4 page, not the default Letter.
            #expect(abs(firstPage.bounds(for: .mediaBox).width - 595.3) < 1)
            #expect(pdf.pageCount >= 2)
            #expect(pdf.string?.contains("Word-style document") == true)
            #expect(pdf.string?.contains("HEADER TEXT") == true)
            #expect(firstPage.annotations.contains {
                ($0.url ?? ($0.action as? PDFActionURL)?.url)?.absoluteString == "https://example.com/"
            })
            #expect(hasBluePicture(firstPage))
        }
    }

    /// The sample's picture is a block of #2881DB. The page is drawn into an sRGB
    /// bitmap of its own: PDFKit's thumbnails use the display's color profile once a
    /// page's text has been read, which shifts the colors.
    private func hasBluePicture(_ page: PDFPage) -> Bool {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width / 2), height = Int(box.height / 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let (red, green, blue) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            if red < 80, (100...190).contains(green), blue > 180 {
                return true
            }
        }
        return false
    }

    @Test func aFileThatOnlyLivesInPolkaGetsItsPDFKeptThere() async throws {
        try await withFolders { _, copies in
            // Like a file Mail handed over: it only exists in a copy folder.
            let promised = try makeRTF("From Mail", named: "attachment.rtf", in: try copies.makeFolder())
            let store = makeStore([promised], storageMode: .copy)
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            let outcome = await converter.convert([store.items[0].id])

            #expect(outcome.keptInPolka.isEmpty)
            let pdf = try #require(store.items.first { $0.title == "attachment.pdf" })
            #expect(pdf.storageMode == .copy)
            #expect(copies.folderName(containing: try #require(path(of: pdf))) != nil)
            // The document's folder and the PDF's own; the scratch folder is gone.
            #expect(copies.folderNames().count == 2)
        }
    }

    @Test func aFolderThatCantBeWrittenToLeavesThePDFInPolka() async throws {
        try await withFolders { documents, copies in
            let letterFile = try makeRTF("Locked", named: "letter.rtf", in: documents)
            let store = makeStore([letterFile])
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: documents.path)
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            let outcome = await converter.convert([store.items[0].id])

            #expect(outcome.keptInPolka == ["letter.pdf"])
            let pdf = try #require(store.items.first { $0.title == "letter.pdf" })
            #expect(pdf.storageMode == .copy)
            #expect(!fileManager.fileExists(atPath: documents.appendingPathComponent("letter.pdf").path))
            #expect(NotchViewModel.conversionMessage(for: outcome)
                    == "Couldn't save letter.pdf next to its document, so Polka keeps it")
        }
    }

    @Test func anUnreadableDocumentLeavesNothingBehind() async throws {
        try await withFolders { documents, copies in
            let broken = documents.appendingPathComponent("broken.docx")
            try Data("this is not a Word file".utf8).write(to: broken)
            let store = makeStore([broken])
            let converter = PDFConverter(store: store, copies: copies, defaultPage: { letter })

            let outcome = await converter.convert([store.items[0].id])

            #expect(outcome.failed == ["broken.docx"])
            #expect(outcome.added.isEmpty)
            #expect(store.items.count == 1)
            #expect(try fileManager.contentsOfDirectory(atPath: documents.path) == ["broken.docx"])
            #expect(copies.folderNames().isEmpty)
            #expect(store.convertingItemIDs.isEmpty)
        }
    }

    // MARK: - The menu and messages

    @Test func theMenuCountsOnlyTheDocumentsInTheSelection() {
        let store = makeStore(["/x/a.docx", "/x/photo.png", "/x/b.rtf", "/x/c.txt"].map(URL.init(fileURLWithPath:)))
        let model = NotchViewModel(store: store)
        let ids = store.items.map(\.id)
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)
        model.click(ids[2], .toggle)
        #expect(model.convertibleSelectionCount == 2)
        #expect(model.documentsToConvert(from: ids[2]) == [ids[0], ids[2]])
        // A tile outside the selection converts alone.
        #expect(model.documentsToConvert(from: ids[3]) == [ids[3]])
    }

    @Test func messagesSayWhatWentWrong() {
        var outcome = PDFConverter.Outcome()
        #expect(NotchViewModel.conversionMessage(for: outcome) == nil)
        outcome.keptInPolka = ["a.pdf", "b.pdf"]
        #expect(NotchViewModel.conversionMessage(for: outcome)
                == "Couldn't save 2 PDFs next to their documents, so Polka keeps them")
        outcome.failed = ["Q3 Report"]
        #expect(NotchViewModel.conversionMessage(for: outcome) == "Couldn't convert Q3 Report to PDF")
        outcome.failed = ["a", "b", "c"]
        #expect(NotchViewModel.conversionMessage(for: outcome) == "Couldn't convert 3 files to PDF")
    }
}
