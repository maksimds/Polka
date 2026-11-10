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
        /// Points at a duplicate kept by Polka, in its Copies folder.
        case copy
    }

    /// The file a kept copy was made from, so the item can go back to it.
    struct Original: Codable, Equatable {
        var path: String
        var bookmark: Data?
    }

    /// What the item points at.
    enum Source: Codable, Equatable {
        /// A file or folder on disk. `bookmark` finds it again after it moves.
        case file(path: String, bookmark: Data?)
        case link(URL)
    }

    /// What a link's preview fetch found (FR-6): the name the site gives itself and its icon.
    struct LinkPreview: Codable, Equatable {
        /// Raised whenever what a preview holds changes, so older ones are fetched again.
        static let currentVersion = 2

        /// When the fetch finished, whether or not it found anything.
        var fetchedAt: Date
        /// The site's own name from its `og:site_name` tag, if the page declares one.
        var siteName: String?
        /// The site's icon, saved in Polka's Previews folder.
        var iconFileName: String?
        /// Nil for previews saved before versions existed.
        var version: Int? = LinkPreview.currentVersion

        var isCurrent: Bool {
            version == Self.currentVersion
        }
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
    /// For links: what the preview fetch found. Nil until it has run, which also
    /// means shelves saved before previews existed still load.
    var linkPreview: LinkPreview? = nil
    /// For a kept copy: the original it was made from. Nil for references, and for
    /// files an app handed over as a promise, which never had an original on disk.
    var original: Original? = nil
}

extension ShelfItem {
    /// The file or web address the item points at.
    var url: URL {
        switch source {
        case .file(let path, _): return URL(fileURLWithPath: path)
        case .link(let url): return url
        }
    }

    var isTemporary: Bool {
        expiresAt != nil
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// The part of a new item that comes from what was dropped.
    /// The store fills in the rest (id, dates, position).
    struct Draft: Equatable {
        let kind: Kind
        let title: String
        let source: Source
        let storageMode: StorageMode

        /// `storageMode` is `.copy` for a file that already sits in Polka's Copies
        /// folder, such as one an app wrote there to keep a promise.
        init(fileURL url: URL, storageMode: StorageMode = .reference) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            // An app or other package is technically a folder, but it reads as one file.
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            kind = isFolder ? .folder : .file
            title = url.lastPathComponent
            source = .file(path: url.standardizedFileURL.path, bookmark: FileReference.bookmark(for: url))
            self.storageMode = storageMode
        }

        init(linkURL url: URL) {
            kind = .link
            // Named from the address right away; a name the site declares replaces it later.
            title = LinkNaming.title(for: url, siteName: nil)
            source = .link(url)
            storageMode = .reference
        }
    }

    /// Everything this item stands for when checking a drop for duplicates. A kept
    /// copy still stands for its original, so dropping the original again adds nothing.
    var dedupeKeys: [String] {
        var keys = [source.dedupeKey]
        if let original {
            keys.append(Source.file(path: original.path, bookmark: nil).dedupeKey)
        }
        return keys
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
