import AppKit

/// What arrived in a drop. In M1 this is only logged; storage comes in M2.
enum DroppedItem: Equatable {
    case file(URL)
    case link(URL)

    var label: String {
        switch self {
        case .file(let url): return "File: \(url.lastPathComponent)"
        case .link(let url): return "Link: \(url.absoluteString)"
        }
    }
}

/// Reads file URLs and web URLs from a drag pasteboard.
enum DropReceiver {
    /// Pasteboard types the panel registers for. Finder provides `.fileURL`,
    /// browsers provide `.URL` for links.
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL]

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    static func items(from pasteboard: NSPasteboard) -> [DroppedItem] {
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Log.drop.debug("Drop pasteboard types: \(types, privacy: .public)")

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        if urls.isEmpty {
            Log.drop.info("Drop had no readable URLs (types: \(types, privacy: .public))")
        }

        return urls.map { url in
            let item: DroppedItem = url.isFileURL ? .file(url) : .link(url)
            Log.drop.info("Dropped \(item.label, privacy: .public)")
            return item
        }
    }
}
