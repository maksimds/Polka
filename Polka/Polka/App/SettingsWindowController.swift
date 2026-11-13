import AppKit
import SwiftUI

/// The Settings window, opened from the menu bar menu or the gear in the panel.
///
/// It's a plain AppKit window rather than a SwiftUI `Settings` scene so that Polka
/// controls how it comes forward and goes away.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let loginItem: LoginItem
    private let screenshots: ScreenshotCatcher?
    /// Gives focus back to the app you were in once Settings closes.
    private let focus: FocusReturner
    private var window: NSWindow?
    private var hasBeenPlaced = false
    /// The whole form's height, measured once.
    private var formHeight: CGFloat?
    /// Room kept between the window and the screen's edges when it has to shrink.
    private static let screenMargin: CGFloat = 8

    init(loginItem: LoginItem, screenshots: ScreenshotCatcher?, focus: FocusReturner) {
        self.loginItem = loginItem
        self.screenshots = screenshots
        self.focus = focus
        super.init()
    }

    func show() {
        focus.rememberFrontmostApp()
        let window = self.window ?? makeWindow()
        self.window = window
        let isOpening = !window.isVisible
        if isOpening {
            let area = NotchGeometry.screen(containing: NSEvent.mouseLocation)?.visibleFrame
            fit(window, in: area)
            placeOnPointerScreen(window, area: area)
        }
        loginItem.refresh()
        // The Screenshot toolbar may have picked another save location since.
        screenshots?.refresh()

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // If macOS turns the activation down, the window still comes to the front,
        // and one click on it gives it focus.
        window.orderFrontRegardless()
        if isOpening {
            // AppKit puts the caret in a window's first text field when it opens, and
            // here that's the hex code, which you rarely want to type. SwiftUI may
            // place it a moment later, hence once more on the next pass.
            window.makeFirstResponder(nil)
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }

    // MARK: - NSWindowDelegate

    /// Polka has no other window that can take focus, so when Settings closes macOS
    /// leaves Polka active with nothing to type into. Hand focus back instead.
    func windowWillClose(_ notification: Notification) {
        focus.handBack(after: "Settings")
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: SettingsView(loginItem: loginItem, screenshots: screenshots))
        // Polka sizes the window itself (`fit`), rather than the window taking the
        // form's full height, which can be taller than a small screen.
        content.sizingOptions = []
        let window = SettingsWindow(contentViewController: content)
        window.title = "Polka Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        Log.app.info("Settings window created")
        return window
    }

    /// As tall as the whole form, or as tall as the screen allows, with the form
    /// scrolling. The top edge stays put, so a window reopened where you left it
    /// doesn't jump.
    private func fit(_ window: NSWindow, in area: NSRect?) {
        let frame = window.frame
        let titleBar = frame.height - window.contentRect(forFrameRect: frame).height
        var height = measuredFormHeight()
        if let area {
            height = min(height, area.height - titleBar - Self.screenMargin * 2)
        }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: height)).size
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: false)
    }

    /// The form's full height, from a copy that doesn't scroll and so takes all the
    /// room it needs.
    private func measuredFormHeight() -> CGFloat {
        if let formHeight { return formHeight }
        let copy = NSHostingView(rootView: SettingsView(loginItem: loginItem, screenshots: screenshots)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true))
        let height = copy.fittingSize.height
        formHeight = height
        return height
    }

    /// Opens on the screen the pointer is on, a little above the middle like
    /// `NSWindow.center()`, and never past the menu bar or the screen's bottom.
    /// Reopened on the same screen, it stays where you left it.
    private func placeOnPointerScreen(_ window: NSWindow, area: NSRect?) {
        let frame = window.frame
        guard let area else {
            if !hasBeenPlaced { window.center() }
            hasBeenPlaced = true
            return
        }
        if hasBeenPlaced, area.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            // Back where you left it, though it may have grown since.
            if frame.minY < area.minY {
                window.setFrameOrigin(CGPoint(x: frame.minX, y: area.minY + Self.screenMargin))
            }
            return
        }
        hasBeenPlaced = true
        let lifted = area.midY - frame.height / 2 + area.height / 10
        let y = max(min(lifted, area.maxY - Self.screenMargin - frame.height), area.minY + Self.screenMargin)
        window.setFrameOrigin(CGPoint(x: area.midX - frame.width / 2, y: y))
    }
}

/// Polka's menu bar has no File menu, so no Close item, and the window handles
/// Cmd-W itself.
private final class SettingsWindow: NSWindow {
    /// A click anywhere but the field being typed in ends the typing and applies it, as
    /// in Finder. On its own, AppKit keeps the field going when you click a control
    /// that doesn't take typing, such as a swatch, or the window's background.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let field = (firstResponder as? NSTextView)?.delegate as? NSView,
           !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
