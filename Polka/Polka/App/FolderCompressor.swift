import Foundation

/// "Compress" (FR-26): a shelf folder's tiles in a zip, as Finder's Compress makes one
/// of a folder, and the zip on the shelf right after the folder, for dragging wherever
/// it's needed.
///
/// A shelf folder lives only in shelf.json, so there's no folder on disk to zip. Its
/// contents are laid out first in a copy folder of Polka's own (`FolderArchive` says
/// what goes in): files and folders are copied in, which on the same APFS disk is a
/// clone, instant and taking no extra space; links become .webloc files and text .txt
/// files. Then `ditto`, the tool behind Finder's Compress, zips that folder into
/// another copy folder, and the first is deleted. The zip is one of Polka's copies,
/// with no original, like a pasted picture: removing its tile deletes it. Nothing is
/// written anywhere else, and the files themselves are never changed.
@MainActor
final class FolderCompressor {
    enum Outcome: Equatable {
        /// The zip's new tile.
        case added(ShelfItem.ID)
        /// Nothing in the folder could go in: it's empty, or its files can't be found.
        case nothingToCompress
        case failed
    }

    struct Failure: Error {
        let status: Int32
    }

    private let store: ShelfStore
    private let copies: ShelfCopies

    init(store: ShelfStore, copies: ShelfCopies) {
        self.store = store
        self.copies = copies
    }

    /// Zips the folder's tiles in the background. Its tile says "Compressing…" until
    /// the zip is on the shelf. A folder already being compressed is left alone.
    func compress(_ folderID: ShelfItem.ID) async -> Outcome {
        guard let folder = store.folder(folderID), !store.compressingItemIDs.contains(folderID) else {
            return .failed
        }
        let missing = store.missingItemIDs
        let entries = FolderArchive.entries(for: store.items(in: folderID), isMissing: { missing.contains($0) })
        guard !entries.isEmpty else { return .nothingToCompress }

        store.setCompressing(folderID, true)
        defer { store.setCompressing(folderID, false) }
        let name = FolderArchive.archiveName(for: folder.displayName)
        let copies = self.copies
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Self.makeArchive(of: entries, named: name, copies: copies) }
        }.value

        switch result {
        case .success(let zip):
            Log.storage.info("Compressed a shelf folder of \(entries.count, privacy: .public) items")
            // Right after the folder, on the shelf; at the front if the folder went meanwhile.
            guard let added = store.add([ShelfItem.Draft(fileURL: zip, storageMode: .copy)], after: folderID).added.first else {
                if let folderName = copies.folderName(containing: zip.path) {
                    copies.removeFolder(named: folderName)
                }
                return .failed
            }
            return .added(added.id)
        case .failure(let error):
            Log.storage.error("""
                Couldn't compress a shelf folder: \(error.logCode, privacy: .public), \
                \(error.localizedDescription, privacy: .private)
                """)
            return .failed
        }
    }

    /// Lays the entries out in a folder called `name` inside a new copy folder, zips
    /// it as "`name`.zip" into another, and returns the zip. The layout is deleted
    /// either way, and so is a zip that didn't finish.
    nonisolated static func makeArchive(of entries: [FolderArchive.Entry],
                                        named name: String,
                                        copies: ShelfCopies) throws -> URL {
        let fileManager = FileManager.default
        let staging = try copies.makeFolder()
        defer { copies.removeFolder(named: staging.lastPathComponent) }
        let root = staging.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let destination = root.appendingPathComponent(entry.name)
            switch entry.content {
            case .file(let url):
                try fileManager.copyItem(at: url, to: destination)
            case .link(let url):
                try FolderArchive.weblocData(for: url).write(to: destination)
            case .text(let text):
                try Data(text.utf8).write(to: destination)
                TextPreviewFile.markAsUTF8(destination)
            }
        }

        let output = try copies.makeFolder()
        let zip = output.appendingPathComponent(name + ".zip")
        do {
            try zipFolder(root, to: zip)
        } catch {
            copies.removeFolder(named: output.lastPathComponent)
            throw error
        }
        return zip
    }

    /// `ditto -c -k --sequesterRsrc --keepParent`, what Finder's Compress does: a zip
    /// with the folder itself at its top, and each file's extended attributes and
    /// resource fork kept the Mac way, so a Mac unzips it just as it was.
    nonisolated private static func zipFolder(_ folder: URL, to zip: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(status: process.terminationStatus) }
    }
}
