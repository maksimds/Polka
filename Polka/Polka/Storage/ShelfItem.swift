import Foundation

/// One entry on the shelf. The fields follow the PRD's "Data and storage" section.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case link
    }

    enum StorageMode: String, Codable {
        /// Points at the original file. The default.
        case reference
        /// Points at a duplicate kept by Polka.
        case copy
    }

    /// What the item points at.
    enum Source: Codable, Equatable {
        /// A file or folder on disk. `bookmark` lets M3 find a file after it moves.
        case file(path: String, bookmark: Data?)
        case link(URL)
    }

    let id: UUID
    var kind: Kind
    var title: String
    var source: Source
    var storageMode: StorageMode
    let createdAt: Date
    /// Nil for permanent items, otherwise the time the item is removed.
    var expiresAt: Date?
    /// Position in the grid. Zero is the first tile.
    var sortOrder: Int
}

extension ShelfItem {
    /// The part of a new item that comes from what was dropped.
    /// The store fills in the rest (id, dates, position).
    struct Draft: Equatable {
        let kind: Kind
        let title: String
        let source: Source

        init(fileURL url: URL) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            // An app or other package is technically a folder, but it reads as one file.
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            kind = isFolder ? .folder : .file
            title = url.lastPathComponent
            source = .file(path: url.standardizedFileURL.path, bookmark: nil)
        }

        init(linkURL url: URL) {
            kind = .link
            title = Self.linkTitle(for: url)
            source = .link(url)
        }

        /// Host plus path, so two links from one site stay distinguishable.
        /// Page titles are an open question for M3.
        private static func linkTitle(for url: URL) -> String {
            guard let host = url.host else { return url.absoluteString }
            return url.path == "/" ? host : host + url.path
        }
    }
}

extension ShelfItem.Source {
    /// Two sources with the same key point at the same file or link.
    var dedupeKey: String {
        switch self {
        case .file(let path, _): return "file:\(path)"
        case .link(let url): return "link:\(url.absoluteString)"
        }
    }
}
