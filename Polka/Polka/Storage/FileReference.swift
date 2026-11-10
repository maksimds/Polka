import Foundation

/// Finds a file item's original on disk, following it with its bookmark if it moved.
///
/// A bookmark is macOS's lasting reference to a file. Unlike a path, it still finds
/// the file after it is renamed or moved to another folder on the same disk.
enum FileReference {
    enum Location: Equatable {
        /// Still at its saved path; nothing to change.
        case unchanged
        /// Found, but the saved path or bookmark needs updating.
        case updated(path: String, bookmark: Data?)
        /// Deleted, in the Trash, or on a disk that isn't connected.
        case missing
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func locate(path: String, bookmark: Data?, fileManager: FileManager = .default) -> Location {
        if fileManager.fileExists(atPath: path) {
            // Items saved before bookmarks existed get one now.
            guard bookmark == nil, let newBookmark = Self.bookmark(for: URL(fileURLWithPath: path)) else {
                return .unchanged
            }
            return .updated(path: path, bookmark: newBookmark)
        }

        guard let bookmark else { return .missing }
        var isStale = false
        // Never mount a network or external disk, and never show UI, just to look.
        guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale),
              fileManager.fileExists(atPath: resolved.path),
              !isInTrash(resolved) else {
            return .missing
        }
        return .updated(path: resolved.standardizedFileURL.path,
                        bookmark: Self.bookmark(for: resolved) ?? bookmark)
    }

    /// A file in the Trash counts as deleted: it is on its way out, and dragging it
    /// somewhere would be surprising.
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
