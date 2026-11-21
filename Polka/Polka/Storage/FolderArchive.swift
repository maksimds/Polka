import Foundation

/// What "Compress" puts in a shelf folder's zip (FR-26), worked out from its tiles
/// without touching the disk: each file or folder as itself, under its real name (the
/// file a drag out would drop, a kept copy's original while it can be found); each
/// link as a .webloc file, as Finder makes when a link is dragged into a folder; and
/// each text as a .txt file, both named after the tile. Files that can't be found stay
/// out, as they stay behind in a drag. Two entries never share a name: the second
/// gets a number, as in Finder ("notes 2.txt").
enum FolderArchive {
    enum Content: Equatable {
        /// A file or folder on disk, copied in as it is.
        case file(URL)
        /// A link's address, written as a .webloc file.
        case link(URL)
        /// A text item, written as a UTF-8 .txt file.
        case text(String)
    }

    struct Entry: Equatable {
        let name: String
        let content: Content
    }

    /// The longest a name made from a tile gets, before its extension, in characters,
    /// well inside the 255 bytes a file name can have.
    static let maxBaseLength = 80

    /// The entries for `items`, in their order. `isMissing` says which files can't be
    /// found right now; `fileExists` checks the file that would go in.
    static func entries(for items: [ShelfItem],
                        isMissing: (ShelfItem.ID) -> Bool,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Entry] {
        var taken = Set<String>()
        var entries: [Entry] = []
        for item in items {
            let planned: (name: String, content: Content)
            switch item.source {
            case .file:
                let url = item.urlToOpen(fileExists: fileExists)
                guard !isMissing(item.id), fileExists(url.path) else { continue }
                planned = (url.lastPathComponent, .file(url))
            case .link(let url):
                planned = (fileName(for: item.displayName, fallback: "Link") + ".webloc", .link(url))
            case .text(let text):
                planned = (fileName(for: item.displayName, fallback: "Text") + ".txt", .text(text))
            case .shelfFolder:
                continue
            }
            let name = freeName(planned.name, taken: taken)
            taken.insert(name.lowercased())
            entries.append(Entry(name: name, content: planned.content))
        }
        return entries
    }

    /// A tile's or folder's name as a file name: "/" and ":" can't be in one, a name
    /// starting with "." would hide the file, and line breaks become spaces.
    static func fileName(for name: String, fallback: String) -> String {
        var base = name.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        base = String(base.prefix(maxBaseLength)).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? fallback : base
    }

    /// What the zip of a folder named `folderName` is called, and the folder inside it.
    static func archiveName(for folderName: String) -> String {
        fileName(for: folderName, fallback: ShelfStore.newFolderName)
    }

    /// The .webloc file for a link: a property list with its address, as Finder
    /// writes one.
    static func weblocData(for url: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                           format: .xml,
                                           options: 0)
    }

    /// `name`, or with " 2", " 3" and so on before its extension, whichever no entry
    /// has yet. Case doesn't count, as on a Mac disk.
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let url = URL(fileURLWithPath: name)
        let fileExtension = url.pathExtension
        let base = fileExtension.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let candidate = fileExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(fileExtension)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
