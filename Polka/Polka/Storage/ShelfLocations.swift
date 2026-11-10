import Foundation

/// Where Polka keeps its own files, normally
/// `~/Library/Application Support/com.maksimds.Polka/`.
struct ShelfLocations {
    let folder: URL

    var shelfFile: URL {
        folder.appendingPathComponent("shelf.json")
    }

    /// Saved link preview images, one per link, named after the item's id.
    var previewsFolder: URL {
        folder.appendingPathComponent("Previews", isDirectory: true)
    }

    static func standard(fileManager: FileManager = .default) throws -> ShelfLocations {
        let support = try fileManager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
        let folderName = Bundle.main.bundleIdentifier ?? "com.maksimds.Polka"
        return ShelfLocations(folder: support.appendingPathComponent(folderName, isDirectory: true))
    }
}
