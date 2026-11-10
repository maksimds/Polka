import AppKit
import SwiftUI

/// The Settings window, opened from the menu bar menu or the gear in the panel.
///
/// It's a plain AppKit window rather than a SwiftUI `Settings` scene so that Polka
/// controls how it comes forward and goes away. Polka has no Dock icon and is almost
/// never the active app, and a window from an inactive app opens behind the app
/// you're in, where it can't take keystrokes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let loginItem: LoginItem
    private var window: NSWindow?
    /// The app you were in before Settings took focus, so it can get focus back.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var hasBeenPlaced = false

    init(loginItem: LoginItem) {
        self.loginItem = loginItem
        super.init()

        // Keeps track of the last other app you used, in case you switch to another
        // one and back while Settings is open.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    func show() {
        remember(NSWorkspace.shared.frontmostApplication)
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            placeOnPointerScreen(window)
        }
        loginItem.refresh()

        // Making Polka the active app is what lets the window take keyboard focus.
        // You asked for a window, so focus moving to it is expected here. The notch
        // panel never does this.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // If macOS turns the activation down, the window still comes to the front,
        // and one click on it gives it focus.
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    /// Polka has no other window that can take focus, so when Settings closes macOS
    /// leaves Polka active with nothing to type into. Hand focus back instead.
    func windowWillClose(_ notification: Notification) {
        // Closed while you were already in another app: leave focus where it is.
        guard NSApp.isActive, let app = previousApp, !app.isTerminated else { return }
        // Polka is active, so it can pass activation on to another app.
        let activated = app.activate(from: .current, options: [])
        Log.app.debug("""
            Settings closed, focus back to \(app.localizedName ?? "?", privacy: .public): \(activated)
            """)
    }

    // MARK: - Private

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = app
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: SettingsView(loginItem: loginItem))
        // Created with its content's size, and kept at it.
        let window = SettingsWindow(contentViewController: content)
        window.title = "Polka Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        Log.app.info("Settings window created")
        return window
    }

    /// Opens on the screen the pointer is on, a little above the middle like
    /// `NSWindow.center()`. Reopened on the same screen, it stays where you left it.
    private func placeOnPointerScreen(_ window: NSWindow) {
        let frame = window.frame
        guard let area = NotchGeometry.screen(containing: NSEvent.mouseLocation)?.visibleFrame else {
            if !hasBeenPlaced { window.center() }
            hasBeenPlaced = true
            return
        }
        if hasBeenPlaced, area.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
        hasBeenPlaced = true
        window.setFrameOrigin(CGPoint(x: area.midX - frame.width / 2,
                                      y: area.midY - frame.height / 2 + area.height / 10))
    }
}

/// An agent app's menu bar never shows and may not have a Close item, so the window
/// handles Cmd-W itself.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
