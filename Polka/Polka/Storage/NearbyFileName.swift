import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The name a file from another Mac is saved under. It comes from that Mac, so it's
/// treated as hostile: it could try to reach outside the folder it's written into
/// (`../../Library/LaunchAgents/x.plist`), hide its real type behind invisible
/// formatting (a right-to-left override making `.app` read as `.pdf`), or be too long
/// for the disk.
enum NearbyFileName {
    /// What a name with nothing left becomes.
    static let fallback = "File"
    /// The most a file name can take on APFS, in UTF-8 bytes.
    static let maxBytes = 255

    /// The name, safe to write inside a folder of Polka's own: only its last part
    /// (after any `/`), with `:` replaced (Finder shows it as `/`), control and
    /// invisible formatting characters removed, no dots or spaces at the start (so it's
    /// never hidden, nor `.` or `..`), and at most `maxBytes` long, cut before its
    /// extension so the extension stays. `fallback` if nothing is left.
    static func clean(_ raw: String) -> String {
        let lastPart = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in lastPart.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator:
                continue
            default:
                scalars.append(scalar == ":" ? "-" : scalar)
            }
        }
        var name = String(scalars)
        while let first = name.first, first == "." || first.isWhitespace {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return fallback }
        return shortened(name)
    }

    /// Cut to `maxBytes`, keeping a short extension whole.
    private static func shortened(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.utf8.count <= 16
        let suffix = keepsExtension ? "." + ext : ""
        var base = keepsExtension ? String(name.dropLast(suffix.count)) : name
        while base.utf8.count + suffix.utf8.count > maxBytes, !base.isEmpty {
            base.removeLast()
        }
        let cut = base.trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? fallback + suffix : cut + suffix
    }

    /// True for a file that can run something when opened: an app, a script, a program,
    /// an installer or a disk image. The offer marks these, since a name alone says
    /// little about what opening it does. Worked out from the extension, as macOS knows
    /// it, not from anything the other Mac said.
    static func mayRun(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if alsoRuns.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return runnableTypes.contains { type.conforms(to: $0) }
    }

    private static let runnableTypes: [UTType] = [
        .application, .applicationBundle, .executable, .script, .shellScript, .diskImage,
    ] + ["com.apple.installer-package-archive", "com.apple.installer-meta-package"].compactMap(UTType.init)

    /// Extensions macOS opens by running something, whatever type it calls them.
    private static let alsoRuns: Set<String> = [
        "command", "tool", "terminal", "jar", "workflow", "action", "scpt", "scptd",
        "applescript", "pkg", "mpkg", "dmg", "app", "osax", "prefpane", "saver",
        "webloc", "inetloc", "fileloc", "url", "shortcut",
    ]
}

/// The picture an offer brings for a file or link. It's decoded only after the person
/// asks to see it (Show Preview), and before that only checked by its bytes: a PNG, at
/// most `maxSide` pixels each way and `maxBytes` long, read from its header. Image
/// decoders have been the way into real zero-click attacks, and an offer opens the
/// panel by itself.
enum NearbyPreviewImage {
    static let maxSide = 256
    static let maxBytes = 131_072

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isAcceptable(_ data: Data) -> Bool {
        size(of: data) != nil
    }

    /// The picture, for after Show Preview: only if it passes `isAcceptable` again, and
    /// only through ImageIO's PNG reader, whatever the bytes might pass for otherwise.
    static func decode(_ data: Data) -> CGImage? {
        guard let size = size(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == size.width, image.height == size.height else { return nil }
        return image
    }

    /// The width and height its header gives, if it's a PNG within the limits.
    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard data.count <= maxBytes, data.count >= 33 else { return nil }
        let bytes = [UInt8](data.prefix(24))
        // The signature, then the first chunk, which must be IHDR, 13 bytes long.
        guard Array(bytes[0..<8]) == signature,
              bytes[8..<12].elementsEqual([0, 0, 0, 13]),
              bytes[12..<16].elementsEqual(Array("IHDR".utf8)) else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        guard (1...maxSide).contains(width), (1...maxSide).contains(height) else { return nil }
        return (width, height)
    }
}
