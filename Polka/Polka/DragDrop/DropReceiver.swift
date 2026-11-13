import AppKit
import UniformTypeIdentifiers

/// What arrived in a drop.
enum DroppedItem: Equatable {
    case file(URL)
    case link(URL)
    /// A file the source app will write once asked, such as a photo from Photos, a
    /// Mail attachment or an image from a browser. There is no file on disk yet.
    case promise(NSFilePromiseReceiver)
    /// An address that isn't a web link, such as `smb:` or an app's own scheme. It's
    /// never stored (see `LinkInput.isWebAddress`); the panel says why instead.
    case refusedLink(URL)
    /// Selected text dragged from a page or a document.
    case text(String)

    var label: String {
        switch self {
        case .file(let url): return "File: \(url.lastPathComponent)"
        case .link(let url): return "Link: \(url.absoluteString)"
        case .promise(let receiver): return "Promised file: \(receiver.fileTypes.joined(separator: ", "))"
        case .refusedLink(let url): return "Not a web link (\(url.scheme ?? "no scheme"))"
        case .text(let text): return "Text, \(text.count) characters"
        }
    }

    var text: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    var promise: NSFilePromiseReceiver? {
        guard case .promise(let receiver) = self else { return nil }
        return receiver
    }

    var isRefusedLink: Bool {
        guard case .refusedLink = self else { return false }
        return true
    }
}

/// Reads file URLs, web URLs, file promises and text from a drag pasteboard.
enum DropReceiver {
    /// Pasteboard types the panel registers for. Finder provides `.fileURL`,
    /// browsers provide `.URL` for links, apps like Photos and Mail promise files, and
    /// selected text comes as `.string`.
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self, NSString.self], options: nil)
    }

    /// Real files come first, then promised files, then links, then text. A browser
    /// dragging an image offers both the image's address and a promise of the image
    /// itself, and the image is what's wanted. A promise of a bookmark file, though,
    /// means the link. Text that's nothing but a web address is the link too.
    ///
    /// Only web links are kept. A web page decides what its draggable elements carry,
    /// so a drag can bring any address at all; anything else comes back as a
    /// `refusedLink`, so the panel can say why nothing was added.
    static func items(from pasteboard: NSPasteboard) -> [DroppedItem] {
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Log.drop.debug("Drop pasteboard types: \(types, privacy: .public)")

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        let hasLinks = urls.contains { !$0.isFileURL }
        let wantedPromises = promises.filter { !(hasLinks && promisesOnlyAWebLocation($0)) }

        var items: [DroppedItem]
        if !urls.contains(where: \.isFileURL), !wantedPromises.isEmpty {
            items = wantedPromises.map { .promise($0) }
        } else {
            items = urls.map { url in
                if url.isFileURL { return .file(url) }
                return LinkInput.isWebAddress(url) ? .link(url) : .refusedLink(url)
            }
        }
        if items.isEmpty, let string = pasteboard.string(forType: .string) {
            let text = PasteReader.trimmed(string)
            if let link = LinkInput.link(inText: text) {
                items = [.link(link)]
            } else if !text.isEmpty {
                items = [.text(text)]
            }
        }

        if items.isEmpty {
            Log.drop.info("Drop had nothing Polka can store (types: \(types, privacy: .public))")
        }
        for item in items {
            Log.drop.info("Dropped \(item.label, privacy: .private)")
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
