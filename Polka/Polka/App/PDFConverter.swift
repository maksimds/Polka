import Foundation

/// "Convert to PDF" (FR-18): makes a PDF of each document and puts it on the shelf
/// right after it.
///
/// The PDF is saved next to the file the tile opens, like Finder's "Convert Image",
/// so it stays on disk when the tile is removed. A file that only lives in Polka's
/// folder (a promised file, or a kept copy whose original is gone) gets its PDF kept
/// there too, as one of Polka's copies, and so does one whose folder can't be written
/// to. A name that's taken gets the next number ("report 2.pdf"); nothing is ever
/// overwritten, and the document itself is never changed.
///
/// Each PDF is drawn into a new copy folder first, and only then moved out, so a
/// half-written PDF never shows up in your folders, and the only files Polka deletes
/// are in its own folder.
@MainActor
final class PDFConverter {
    /// What happened to a batch, for the panel's message.
    struct Outcome: Equatable {
        /// The new PDF items, in the order they were made.
        var added: [ShelfItem.ID] = []
        /// The names of the documents that couldn't be converted.
        var failed: [String] = []
        /// PDFs Polka keeps in its own folder because the document's folder couldn't
        /// be written to.
        var keptInPolka: [String] = []
    }

    private let store: ShelfStore
    private let copies: ShelfCopies
    private let defaultPage: @MainActor () -> PDFRenderer.Page
    /// How many numbered names to try before giving up on the document's folder.
    nonisolated private static let maxNameAttempts = 1000

    init(store: ShelfStore,
         copies: ShelfCopies,
         defaultPage: @escaping @MainActor () -> PDFRenderer.Page = { .systemDefault }) {
        self.store = store
        self.copies = copies
        self.defaultPage = defaultPage
    }

    /// Converts the documents one after another. Each tile shows "Converting…" from
    /// the start until its PDF is on the shelf. A document already being converted is
    /// skipped.
    func convert(_ ids: [ShelfItem.ID]) async -> Outcome {
        let ids = ids.filter { !store.convertingItemIDs.contains($0) }
        for id in ids {
            store.setConverting(id, true)
        }
        var outcome = Outcome()
        for id in ids {
            // Removed from the shelf while it waited: nothing to put a PDF next to.
            if let item = store.items.first(where: { $0.id == id }) {
                await convert(item, into: &outcome)
            }
            store.setConverting(id, false)
        }
        return outcome
    }

    private func convert(_ item: ShelfItem, into outcome: inout Outcome) async {
        let document = item.urlToOpen()
        let staging: URL
        let scratch: URL
        do {
            staging = try copies.makeFolder()
            scratch = try copies.makeFolder()
        } catch {
            Log.storage.error("No folder to make a PDF in: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            outcome.failed.append(item.displayName)
            return
        }
        defer { copies.removeFolder(named: scratch.lastPathComponent) }

        let pdf = staging.appendingPathComponent(PDFConversion.pdfName(for: document.lastPathComponent))
        do {
            try await PDFRenderer.render(document, to: pdf, scratch: scratch, defaultPage: defaultPage())
        } catch {
            Log.storage.error("Couldn't convert \(item.title, privacy: .private) to PDF: \(error.logCode, privacy: .public)")
            copies.removeFolder(named: staging.lastPathComponent)
            outcome.failed.append(item.displayName)
            return
        }

        // A document that lives in Polka's folder has no folder of yours to go next to.
        let livesInPolka = copies.folderName(containing: document.path) != nil
        let placed = livesInPolka ? nil : await Self.move(pdf, nextTo: document)
        let draft: ShelfItem.Draft
        if let placed {
            copies.removeFolder(named: staging.lastPathComponent)
            draft = ShelfItem.Draft(fileURL: placed)
        } else {
            if !livesInPolka {
                outcome.keptInPolka.append(pdf.lastPathComponent)
            }
            draft = ShelfItem.Draft(fileURL: pdf, storageMode: .copy)
        }
        Log.storage.info("Converted \(item.title, privacy: .private) to PDF")
        outcome.added += store.add([draft], after: item.id).added.map(\.id)
    }

    /// Moves the PDF into the document's folder under the first free name ("report.pdf",
    /// then "report 2.pdf"...). Nil, leaving it where it was, if the folder can't be
    /// written to: a locked disk, or access refused. Off the main thread, since writing
    /// to Desktop, Documents or Downloads can wait on macOS asking you for access.
    nonisolated private static func move(_ pdf: URL, nextTo document: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let folder = document.deletingLastPathComponent()
            for attempt in 1...maxNameAttempts {
                let name = PDFConversion.pdfName(for: document.lastPathComponent, attempt: attempt)
                let destination = folder.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) { continue }
                do {
                    // Refuses to replace a file that appeared since the check.
                    try fileManager.moveItem(at: pdf, to: destination)
                    return destination
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                } catch {
                    Log.storage.error("Couldn't save a PDF next to its document: \(error.logCode, privacy: .public)")
                    return nil
                }
            }
            return nil
        }.value
    }
}
