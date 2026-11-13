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

    /// Polka's own duplicates: kept copies and files that apps hand over by promise.
    var copiesFolder: URL {
        folder.appendingPathComponent("Copies", isDirectory: true)
    }

    /// Where macOS saves screenshots while "Save Screenshots to Polka" is on. Each one
    /// is moved on into a copy folder as soon as it arrives. The name is what the
    /// Screenshot toolbar's Options menu shows as the save location.
    var screenshotsFolder: URL {
        folder.appendingPathComponent("Polka Screenshots", isDirectory: true)
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
