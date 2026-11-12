import AppKit

/// Hands shelf items to other apps: opens them, and shows Finder's Info window.
@MainActor
enum ItemOpener {
    /// Opens a file in its default app, a folder in Finder, or a link in the default
    /// browser, as a double-click in Finder does. The app that opens it comes to the
    /// front, which is what you asked for, so this doesn't break Polka's rule of
    /// never taking focus: the focus goes to that app, not to Polka.
    ///
    /// Only files and web links. New links can't be anything else, but this also
    /// covers one saved before that rule, or written into shelf.json by hand.
    static func open(_ url: URL) -> Bool {
        guard url.isFileURL || LinkInput.isWebAddress(url) else {
            Log.app.error("Didn't open a link that isn't a web address (\(url.scheme ?? "no scheme", privacy: .public))")
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        if opened {
            Log.app.debug("Opened \(url.absoluteString, privacy: .public)")
        } else {
            Log.app.error("Couldn't open \(url.absoluteString, privacy: .public)")
        }
        return opened
    }

    /// Finder's own Info window for each file, through the "Show Info in Finder"
    /// service that Finder offers every app (right-click > Services). Asking Finder
    /// with AppleScript instead would make macOS ask for permission to control
    /// Finder; a service needs none.
    static func showInfo(for files: [URL]) -> Bool {
        guard !files.isEmpty else { return false }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.maksimds.Polka.ShowInfo"))
        pasteboard.clearContents()
        // The classic list-of-paths type, which is what Finder's service asks for.
        pasteboard.setPropertyList(files.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        guard NSPerformService("Finder/Show Info", pasteboard) else {
            Log.app.error("Finder's Show Info service didn't run")
            return false
        }
        // Polka isn't the active app, so Finder can open the window without coming
        // forward. Ask it to, so the window doesn't end up behind the app you're in.
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        let activated = finder?.activate(options: []) ?? false
        Log.app.debug("Get Info for \(files.count) file(s), Finder brought forward: \(activated)")
        return true
    }
}
