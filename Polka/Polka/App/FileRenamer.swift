import Foundation

/// Renames an item's file or folder on disk, for "Rename File" and "Rename Folder".
///
/// The real file is renamed, the one opening the tile opens: a kept copy's original
/// while it can be found, otherwise the item's own file. A kept copy's copy gets the
/// new name too, so a drag out drops it under the name you gave. A file with no
/// original (a promised file, a pasted picture, a screenshot) only has its copy in
/// Polka's folder, and that's what is renamed.
///
/// The work happens off the main thread: in Desktop, Documents or Downloads, macOS
/// may first ask for access, and the rename waits for that answer.
enum FileRenamer {
    /// What to rename, worked out from the item on the main actor.
    struct Plan: Sendable, Equatable {
        /// The file whose name changes, and whose name the rules compare against.
        let file: URL
        /// True when `file` is a kept copy's original, not the item's own file.
        let isOriginal: Bool
        /// The item's copy in Polka's folder, renamed along with its original. Nil for
        /// a reference, or a copy whose original is gone (then `file` is the copy).
        let copy: URL?
        let isFolder: Bool

        /// Nil for links and text, which have no file.
        init?(item: ShelfItem, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
            guard case .file(let path, _) = item.source else { return nil }
            isFolder = item.kind == .folder
            let own = URL(fileURLWithPath: path)
            if let original = item.original, fileExists(original.path) {
                file = URL(fileURLWithPath: original.path)
                isOriginal = true
                copy = own
            } else {
                file = own
                isOriginal = false
                copy = nil
            }
        }
    }

    enum Outcome: Equatable {
        /// Nothing typed, or the same name.
        case unchanged
        /// Where the item's own file is now (nil if it didn't move), and a kept copy's
        /// original (nil unless it was the one renamed).
        case renamed(name: String, path: String?, originalPath: String?)
        /// The file keeps its name; the panel shows this.
        case refused(String)
    }

    /// Renames the plan's file to `typed`, cleaned. Never replaces another file: a
    /// name that's taken is refused, even if another file takes it at the last moment.
    static func rename(_ plan: Plan, to typed: String) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            perform(plan, to: typed)
        }.value
    }

    /// The rename itself, which waits on the disk. Not on the main thread.
    static func perform(_ plan: Plan, to typed: String) -> Outcome {
        let name = FileRenaming.cleaned(typed)
        let oldName = plan.file.lastPathComponent
        // Empty brings the name back, as in Finder.
        guard !name.isEmpty, name != oldName else { return .unchanged }
        if let problem = FileRenaming.problem(with: name, replacing: oldName, isFolder: plan.isFolder) {
            return .refused(FileRenaming.message(for: problem, oldName: oldName))
        }

        let destination = plan.file.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try move(plan.file, to: destination)
        } catch {
            Log.app.error("Couldn't rename a file: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            return .refused(message(for: error, oldName: oldName, newName: name))
        }

        guard plan.isOriginal else {
            return .renamed(name: name, path: destination.path, originalPath: nil)
        }
        // The copy sits alone in its own folder, so its new name is free. If it can't be
        // renamed anyway, it keeps the old name, which only shows when dragged out.
        var copyPath: String?
        if let copy = plan.copy {
            let copyDestination = copy.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try move(copy, to: copyDestination)
                copyPath = copyDestination.path
            } catch {
                Log.app.error("Couldn't rename a kept copy: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            }
        }
        return .renamed(name: name, path: copyPath, originalPath: destination.path)
    }

    /// Renames through a file coordinator, so an app that has the file open (TextEdit,
    /// Preview, an iCloud download) hears that it moved and follows it. The rename is
    /// exclusive (`RENAME_EXCL`): it fails rather than replace a file already at
    /// `destination`, and still allows a change of case alone ("report" to "Report"),
    /// which the disk sees as the same file.
    private static func move(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 {
                coordinator.item(at: from, didMoveTo: to)
            } else {
                moveError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if let error = coordinationError ?? moveError {
            throw error
        }
    }

    private static func message(for error: Error, oldName: String, newName: String) -> String {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EEXIST, .ENOTEMPTY:
                return "The name \(newName) is already taken, so \(oldName) keeps its name"
            case .EACCES, .EPERM, .EROFS:
                return "Polka isn't allowed to rename \(oldName)"
            case .ENAMETOOLONG:
                return "That name is too long for a file, so \(oldName) keeps its name"
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError].contains(nsError.code) {
            return "Polka isn't allowed to rename \(oldName)"
        }
        return "Couldn't rename \(oldName)"
    }
}
