import AppKit
import UniformTypeIdentifiers

/// What arrived in a drop.
enum DroppedItem: Equatable {
    case file(URL)
    case link(URL)
    /// A file the source app will write once asked, such as a photo from Photos, a
    /// Mail attachment or an image from a browser. There is no file on disk yet.
    case promise(NSFilePromiseReceiver)

    var label: String {
        switch self {
        case .file(let url): return "File: \(url.lastPathComponent)"
        case .link(let url): return "Link: \(url.absoluteString)"
        case .promise(let receiver): return "Promised file: \(receiver.fileTypes.joined(separator: ", "))"
        }
    }

    var promise: NSFilePromiseReceiver? {
        guard case .promise(let receiver) = self else { return nil }
        return receiver
    }
}

/// Reads file URLs, web URLs and file promises from a drag pasteboard.
enum DropReceiver {
    /// Pasteboard types the panel registers for. Finder provides `.fileURL`,
    /// browsers provide `.URL` for links, and apps like Photos and Mail promise files.
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self], options: nil)
    }

    /// Real files come first, then promised files, then links. A browser dragging an
    /// image offers both the image's address and a promise of the image itself, and
    /// the image is what's wanted. A promise of a bookmark file, though, means the link.
    static func items(from pasteboard: NSPasteboard) -> [DroppedItem] {
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Log.drop.debug("Drop pasteboard types: \(types, privacy: .public)")

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        let hasLinks = urls.contains { !$0.isFileURL }
        let wantedPromises = promises.filter { !(hasLinks && promisesOnlyAWebLocation($0)) }

        let items: [DroppedItem]
        if !urls.contains(where: \.isFileURL), !wantedPromises.isEmpty {
            items = wantedPromises.map { .promise($0) }
        } else {
            items = urls.map { $0.isFileURL ? .file($0) : .link($0) }
        }

        if items.isEmpty {
            Log.drop.info("Drop had nothing Polka can store (types: \(types, privacy: .public))")
        }
        for item in items {
            Log.drop.info("Dropped \(item.label, privacy: .public)")
        }
        return items
    }

    /// True for a promise of a .webloc or .url file: a saved link, not a document.
    private static func promisesOnlyAWebLocation(_ receiver: NSFilePromiseReceiver) -> Bool {
        let fileTypes = receiver.fileTypes
        return !fileTypes.isEmpty && fileTypes.allSatisfy { identifier in
            // Older apps give a file extension instead of a type identifier.
            guard let type = UTType(identifier) ?? UTType(filenameExtension: identifier) else { return false }
            return type.conforms(to: .internetLocation) || type.conforms(to: .internetShortcut)
        }
    }
}
