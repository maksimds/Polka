import Foundation

/// Polka's own files, in its Copies folder: kept copies, files that apps hand over by
/// promise, pictures pasted from the clipboard, and screenshots.
///
/// Each copy sits in a folder of its own, `Copies/<UUID>/<file name>`, so it keeps its
/// real name when dragged out. Only folders named like that, directly inside Copies,
/// are ever deleted or sent to the Trash, so nothing outside Polka's own folder can be
/// removed.
///
/// Nothing here touches the main actor, so copying can run in the background.
struct ShelfCopies {
    let folder: URL
    /// Sends a file to the Trash. Tests put a folder of their own in its place, so
    /// they never fill the real Trash.
    var moveToTrash: @Sendable (URL) throws -> Void = { file in
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }

    /// A new, empty folder for one copy.
    func makeFolder() throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Duplicates a file or folder into a new copy folder and returns where the copy is.
    /// If the copy fails partway, its folder is removed so nothing half-copied stays.
    func copy(_ original: URL) throws -> URL {
        let destinationFolder = try makeFolder()
        let destination = destinationFolder.appendingPathComponent(original.lastPathComponent)
        do {
            // On the same APFS disk this is a clone: instant, and it takes no extra space
            // until one of the two files changes.
            try FileManager.default.copyItem(at: original, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destinationFolder)
            throw error
        }
        return destination
    }

    /// Saves `data` as a file called `name` in a new copy folder and returns where it is.
    /// If writing fails, the folder is removed again.
    func write(_ data: Data, named name: String) throws -> URL {
        let destinationFolder = try makeFolder()
        let destination = destinationFolder.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destinationFolder)
            throw error
        }
        return destination
    }

    /// Moves a file into a new copy folder, keeping its name, and returns where it is
    /// now. On the same disk this is a rename, so it's instant whatever the size.
    func moveIn(_ file: URL) throws -> URL {
        let destinationFolder = try makeFolder()
        let destination = destinationFolder.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destinationFolder)
            throw error
        }
        return destination
    }

    /// The name of the copy folder a path sits in, or nil if the path isn't inside one.
    func folderName(containing path: String) -> String? {
        let root = folder.standardizedFileURL.pathComponents
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // The path must be something inside a copy folder, not the folder itself.
        guard components.count > root.count + 1,
              Array(components.prefix(root.count)) == root else { return nil }
        let name = components[root.count]
        return Self.isCopyFolderName(name) ? name : nil
    }

    /// Every copy folder on disk.
    func folderNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(Self.isCopyFolderName)
    }

    /// Deletes one copy folder and what's in it. Any other name is refused.
    func removeFolder(named name: String) {
        guard Self.isCopyFolderName(name) else {
            Log.storage.error("Refused to delete \(name, privacy: .private): not one of Polka's copy folders")
            return
        }
        do {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
        } catch {
            Log.storage.error("Could not delete a copy: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Sends what one copy folder holds to the Trash, where it can still be found and
    /// put back, then deletes the folder. Any other name is refused. If something can't
    /// go to the Trash, the folder stays rather than being deleted with it.
    func trashFolder(named name: String) {
        guard Self.isCopyFolderName(name) else {
            Log.storage.error("Refused to trash \(name, privacy: .private): not one of Polka's copy folders")
            return
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for file in contents {
                try moveToTrash(file)
            }
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.storage.error("Could not move a copy to the Trash: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
        }
    }

    /// A UUID can't contain "/" or "..", so a name that is one can only mean a
    /// folder directly inside Copies.
    private static func isCopyFolderName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }
}
