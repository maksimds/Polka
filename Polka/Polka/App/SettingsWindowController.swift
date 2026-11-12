import AppKit
import SwiftUI

/// The Settings window, opened from the menu bar menu or the gear in the panel.
///
/// It's a plain AppKit window rather than a SwiftUI `Settings` scene so that Polka
/// controls how it comes forward and goes away. Polka is almost never the active app
/// (its panel never takes focus), and a window from an inactive app opens behind the
/// app you're in, where it can't take keystrokes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let loginItem: LoginItem
    /// Gives focus back to the app you were in once Settings closes.
    private let focus: FocusReturner
    private var window: NSWindow?
    private var hasBeenPlaced = false

    init(loginItem: LoginItem, focus: FocusReturner) {
        self.loginItem = loginItem
        self.focus = focus
        super.init()
    }

    func show() {
        focus.rememberFrontmostApp()
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
        focus.handBack(after: "Settings")
    }

    // MARK: - Private

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

/// Polka's menu bar has no File menu, so no Close item, and the window handles
/// Cmd-W itself.
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
