import Foundation

/// Polka's own duplicates of files, in its Copies folder: kept copies, and files that
/// apps hand over by promise.
///
/// Each copy sits in a folder of its own, `Copies/<UUID>/<file name>`, so it keeps its
/// real name when dragged out. Only folders named like that, directly inside Copies,
/// are ever deleted, so nothing outside Polka's own folder can be removed.
///
/// Nothing here touches the main actor, so copying can run in the background.
struct ShelfCopies {
    let folder: URL

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
            Log.storage.error("Refused to delete \(name, privacy: .public): not one of Polka's copy folders")
            return
        }
        do {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
        } catch {
            Log.storage.error("Could not delete a copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A UUID can't contain "/" or "..", so a name that is one can only mean a
    /// folder directly inside Copies.
    private static func isCopyFolderName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }
}
