import Foundation

/// Keeps the shelf in a JSON file, normally in Polka's Application Support folder.
///
/// Saves are atomic: the new file is written beside the old one and then swapped in,
/// so a crash mid-save never leaves half a file. A file that can't be read is moved
/// aside rather than overwritten, so one bad file can't wipe the shelf.
final class JSONFileShelfPersistence: ShelfPersistence {
    /// The file's top level. `version` leaves room to change the format later.
    private struct Contents: Codable {
        var version: Int
        var items: [ShelfItem]
    }

    /// Thrown by `save` after an unreadable file could not be moved aside.
    struct SavingBlocked: Error {}

    static let formatVersion = 1

    let fileURL: URL
    private let fileManager: FileManager
    /// Set when the existing file is unreadable and still in place, so it isn't replaced.
    private var isSavingBlocked = false

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [ShelfItem] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(Contents.self, from: data).items
        } catch {
            moveAside()
            throw error
        }
    }

    func save(_ items: [ShelfItem]) throws {
        guard !isSavingBlocked else { throw SavingBlocked() }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Contents(version: Self.formatVersion, items: items))
        try data.write(to: fileURL, options: .atomic)
    }

    /// Renames an unreadable file to `shelf-unreadable-<time>.json`, so the next save
    /// starts a fresh file and the old one is still there to inspect.
    private func moveAside() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(6)
        let name = "\(fileURL.deletingPathExtension().lastPathComponent)-unreadable-\(stamp)-\(suffix).json"
        let destination = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
            Log.storage.error("The shelf file could not be read and was kept as \(name, privacy: .public)")
        } catch {
            isSavingBlocked = true
            Log.storage.error("""
                The shelf file could not be read or moved aside, so Polka won't save over it: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
