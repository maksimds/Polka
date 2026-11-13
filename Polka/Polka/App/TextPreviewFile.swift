import Foundation

/// Quick Look only shows files, and a text item has none, so showing one writes its text
/// to a plain text file in the temporary folder, which macOS clears out on its own.
/// The file is only for looking at: the shelf keeps the text itself, and the file is
/// written again each time it's shown.
enum TextPreviewFile {
    /// One folder per item, so each file can be named after its tile, which is what
    /// Quick Look shows as its title.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Text Previews", isDirectory: true)
    }

    /// Writes the text and returns the file, or nil if it couldn't be written.
    static func write(_ text: String, named name: String, id: ShelfItem.ID) -> URL? {
        let directory = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(fileName(for: name))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            Log.app.error("Couldn't write text for Quick Look: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            return nil
        }
        markAsUTF8(file)
        return file
    }

    /// The tile's name as a file name: "/" and ":" can't be in one, and a name starting
    /// with "." would hide the file.
    static func fileName(for name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        base = String(base.prefix(80))
        return (base.isEmpty ? "Text" : base) + ".txt"
    }

    /// Tells Quick Look the file is UTF-8. Without this note it guesses, and gets
    /// Cyrillic or accented text wrong. TextEdit reads the same note. The number is
    /// UTF-8's code among Core Foundation's encodings.
    private static func markAsUTF8(_ file: URL) {
        let value = "utf-8;134217984"
        _ = file.withUnsafeFileSystemRepresentation { path in
            value.withCString { setxattr(path, "com.apple.TextEncoding", $0, strlen($0), 0, 0) }
        }
    }
}
