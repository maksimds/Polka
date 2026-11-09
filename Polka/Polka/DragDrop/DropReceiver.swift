import AppKit
import UniformTypeIdentifiers

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

/// Reads file URLs and web URLs out of dropped item providers.
enum DropReceiver {
    /// Types the panel accepts. A file URL also conforms to `.url`.
    static let acceptedTypes: [UTType] = [.fileURL, .url]

    /// Starts loading every supported provider and calls `completion` once per item,
    /// on the main actor. Returns false if nothing in the drop was usable.
    static func receive(_ providers: [NSItemProvider],
                        completion: @escaping @MainActor (DroppedItem) -> Void) -> Bool {
        var accepted = false

        for provider in providers {
            let types = provider.registeredTypeIdentifiers.joined(separator: ", ")
            Log.drop.debug("Provider types: \(types, privacy: .public)")

            guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
                Log.drop.info("Skipped unsupported provider (types: \(types, privacy: .public))")
                continue
            }
            accepted = true

            _ = provider.loadObject(ofClass: URL.self) { url, error in
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let url else {
                        Log.drop.error("Could not read drop: \(message ?? "unknown error", privacy: .public)")
                        return
                    }
                    let item: DroppedItem = url.isFileURL ? .file(url) : .link(url)
                    Log.drop.info("Dropped \(item.label, privacy: .public)")
                    completion(item)
                }
            }
        }
        return accepted
    }
}
