import AppKit

/// Gives focus back to the app you were in when a Polka window that took it closes.
///
/// Polka activates itself only for windows you asked for: Settings, Quick Look and
/// the Open dialog, because a window from an inactive app can't take keystrokes.
/// Polka's notch panel never activates it (even the link field takes the keys
/// without that), so when one of those windows closes, macOS would leave Polka
/// active with nothing to type into. Shared by all of them, so it always knows the
/// last other app you used.
@MainActor
final class FocusReturner {
    /// The last other app that was active, kept up to date in case you switch to
    /// another app and back while Polka's window is open.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    /// Call just before Polka activates itself.
    func rememberFrontmostApp() {
        remember(NSWorkspace.shared.frontmostApplication)
    }

    /// Hands focus back, unless you already went to another app yourself.
    /// `window` names the window that closed, for the log.
    func handBack(after window: String) {
        guard NSApp.isActive, let app = previousApp, !app.isTerminated else { return }
        // Polka is active, so it can pass activation on to another app.
        let activated = app.activate(from: .current, options: [])
        Log.app.debug("""
            \(window, privacy: .public) closed, focus back to \(app.localizedName ?? "?", privacy: .private): \
            \(activated)
            """)
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = app
    }
}
