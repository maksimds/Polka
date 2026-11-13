import Foundation

/// "Convert to PDF" (FR-18): which files it's offered for, and what the PDF is called.
/// Laying the pages out is AppKit work, in `PDFRenderer`.
enum PDFConversion {
    /// The documents Polka can lay out as pages, by extension: Word's, RTF (and RTFD,
    /// RTF with pictures), OpenDocument text and plain text. Only ".txt" counts as
    /// plain text, not code or Markdown, which are text underneath too.
    static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "txt"]

    /// Word's formats, which Quick Look's converter lays out with their pictures.
    static let wordExtensions: Set<String> = ["docx", "doc"]

    /// True for a file (not a folder or a link) whose name ends in one of
    /// `documentExtensions`. An RTFD is a package, so it counts as a file.
    static func canConvert(_ item: ShelfItem) -> Bool {
        item.kind == .file && documentExtensions.contains(item.url.pathExtension.lowercased())
    }

    /// The PDF's name for a document: "report.docx" becomes "report.pdf", and, when
    /// that's taken, "report 2.pdf", "report 3.pdf" and so on, the way Finder numbers
    /// copies. `attempt` counts from 1.
    static func pdfName(for fileName: String, attempt: Int = 1) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return attempt <= 1 ? "\(base).pdf" : "\(base) \(attempt).pdf"
    }
}
