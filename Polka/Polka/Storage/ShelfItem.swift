import Foundation

/// One entry on the shelf. The fields follow the PRD's "Data and storage" section.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case link
        /// A piece of plain text, pasted or dropped onto the shelf (FR-19).
        case text
    }

    /// Where an item came from, when that changes how Polka treats it.
    enum Origin: String, Codable {
        /// Saved by macOS into Polka's folder while "Save Screenshots to Polka" is on
        /// (FR-20). Its file goes to the Trash, not straight out, once no item uses it.
        case screenshot
    }

    /// The longest text a text item holds, in UTF-16 units (about 100 pages). The text
    /// lives in shelf.json, which is saved again after every change.
    static let maxTextLength = 200_000

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
        /// The text itself, kept in shelf.json.
        case text(String)
    }

    /// What a link's preview fetch found (FR-6): the name the site gives itself and its icon.
    struct LinkPreview: Codable, Equatable {
        /// Raised whenever what a preview holds changes, so older ones are fetched again.
        /// 3: icons are also looked for in the page's own icon tags.
        static let currentVersion = 3

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
    /// A name given with "Rename", shown on the tile instead of `title`. It's only the
    /// tile's label: the file keeps its own name and the link its address. Nil for the
    /// automatic name, which also means shelves saved before renaming existed still load.
    var customName: String? = nil
    /// Nil for items dropped, pasted or added from the + menu, which also means
    /// shelves saved before screenshots came to the shelf still load.
    var origin: Origin? = nil
    /// True for an item pinned to the shelf's first row ("Pin", FR-21). Nil when it
    /// isn't, which also means shelves saved before pinning existed still load.
    var pinned: Bool? = nil
}

extension ShelfItem {
    /// What the tile is called: the name given with "Rename", or else the automatic
    /// one, the file's name or the link's site and address. `title` keeps following
    /// the file and the site underneath, so clearing the name brings it straight back.
    var displayName: String {
        customName ?? title
    }

    /// The file or web address the item points at. Text points at nothing and gives
    /// `about:blank`, which Polka never opens (see `ItemOpener.open`).
    var url: URL {
        switch source {
        case .file(let path, _): return URL(fileURLWithPath: path)
        case .link(let url): return url
        case .text: return URL(string: "about:blank")!
        }
    }

    /// What opening the item opens, and what Quick Look and Get Info show: a kept
    /// copy's original while it can still be found, since that's the real file,
    /// otherwise the item's own file. A link's web address.
    func urlToOpen(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        if let original, fileExists(original.path) {
            return URL(fileURLWithPath: original.path)
        }
        return url
    }

    var isTemporary: Bool {
        expiresAt != nil
    }

    var isPinned: Bool {
        pinned == true
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
        var origin: Origin? = nil
        /// Set for an item that starts out temporary, such as a screenshot: how long
        /// it lasts from the moment it's added. Nil for a permanent one.
        var lifetime: TimeInterval? = nil

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

        /// Text as it was pasted or dropped. The tile is named after its first line.
        init(text: String) {
            kind = .text
            title = Self.title(forText: text)
            source = .text(text)
            storageMode = .reference
        }

        /// The longest automatic name a text item gets, before "…".
        static let maxTextTitleLength = 60

        /// The first line with something on it, spaces squeezed together, and cut short
        /// with "…" past `maxTextTitleLength` characters. "Text" if there's nothing.
        static func title(forText text: String) -> String {
            let firstLine = text.split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .first { !$0.isEmpty }
            guard let firstLine else { return "Text" }
            guard firstLine.count > maxTextTitleLength else { return firstLine }
            let cut = firstLine.prefix(maxTextTitleLength).trimmingCharacters(in: .whitespaces)
            return cut + "…"
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
        // The same text pasted twice is the same item, like the same link.
        case .text(let text): return "text:\(text)"
        }
    }
}
