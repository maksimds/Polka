import Foundation
import UniformTypeIdentifiers

/// The rules for "Rename File" and "Rename Folder", which change the name on disk,
/// not just the tile's label. Finder asks before some of these (a hidden name, a new
/// extension), but Polka can't show a dialog from the panel, so it refuses them with
/// a message instead and the file keeps its name.
enum FileRenaming {
    enum Problem: Equatable {
        /// ":" is how macOS writes "/" inside a name, and "/" separates folders.
        case separator
        /// A name starting with a dot hides the file in Finder.
        case hidden
        /// More than a file name can hold (255 bytes in UTF-8).
        case tooLong
        /// The name ends in a different extension, or gains or loses one. Only for
        /// files: a folder's name can end in anything.
        case extensionChanged(from: String)
    }

    /// The longest name a file can have on a Mac's disks, in bytes of UTF-8.
    static let maxNameBytes = 255

    /// What was typed, as a name: one line, with no space around it. Line breaks
    /// pasted in become spaces, as for a tile's label.
    static func cleaned(_ typed: String) -> String {
        typed.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Why `name` can't replace `oldName`, or nil if it can. `name` is already cleaned.
    static func problem(with name: String, replacing oldName: String, isFolder: Bool) -> Problem? {
        if name.contains(":") || name.contains("/") { return .separator }
        if name.hasPrefix(".") { return .hidden }
        if name.utf8.count > maxNameBytes { return .tooLong }
        if !isFolder {
            let old = realExtension(of: oldName)
            if old.lowercased() != realExtension(of: name).lowercased() {
                return .extensionChanged(from: old)
            }
        }
        return nil
    }

    /// The extension macOS knows a file type by, or "" if there's none. "Notes v1.2"
    /// ends in ".2", but that's part of the name, not a type, so it has none, and
    /// "Notes v1.3" is still the same kind of file.
    static func realExtension(of name: String) -> String {
        let candidate = (name as NSString).pathExtension
        guard !candidate.isEmpty,
              let type = UTType(filenameExtension: candidate),
              !type.isDynamic else { return "" }
        return candidate
    }

    /// What the panel says when a name is refused. `oldName` keeps its name.
    static func message(for problem: Problem, oldName: String) -> String {
        switch problem {
        case .separator:
            return "A name can't contain “:” or “/”, so \(oldName) keeps its name"
        case .hidden:
            return "A name starting with “.” would hide the file, so \(oldName) keeps its name"
        case .tooLong:
            return "That name is too long for a file, so \(oldName) keeps its name"
        case .extensionChanged(let old) where old.isEmpty:
            return "Polka doesn't give files an extension, so \(oldName) keeps its name. Finder can."
        case .extensionChanged(let old):
            return "Polka doesn't change a file's extension, so the name has to end in “.\(old)”. Finder can change it."
        }
    }
}
