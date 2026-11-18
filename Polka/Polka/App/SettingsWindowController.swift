import AppKit
import SwiftUI

/// The Settings window, opened from the menu bar menu or the gear in the panel.
///
/// It's a plain AppKit window rather than a SwiftUI `Settings` scene so that Polka
/// controls how it comes forward and goes away. Its tabs are the toolbar buttons
/// macOS apps use for settings (`NSTabViewController` in toolbar style), each holding
/// a SwiftUI form, and the window takes each tab's height.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case general
        case nearby

        var title: String {
            switch self {
            case .general: return "General"
            case .nearby: return "Nearby Sharing"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .nearby: return "person.2.wave.2"
            }
        }
    }

    private let loginItem: LoginItem
    private let screenshots: ScreenshotCatcher?
    /// Looks for Macs nearby only while the Nearby Sharing tab shows, for its list.
    private let nearby: NearbyService
    private var isBrowsing = false
    /// Gives focus back to the app you were in once Settings closes.
    private let focus: FocusReturner
    private(set) var window: NSWindow?
    private var tabs: SettingsTabController?
    /// The room the window last opened in, for refitting it when the tab changes.
    private var area: NSRect?
    private var hasBeenPlaced = false
    /// Each tab's whole form height, measured once.
    private var formHeights: [Tab: CGFloat] = [:]
    /// Room kept between the window and the screen's edges when it has to shrink.
    private static let screenMargin: CGFloat = 8
    /// Runs once the window has closed. The shelf stays open while Settings is, and
    /// this lets it go.
    var onClose: (@MainActor () -> Void)?

    init(loginItem: LoginItem, screenshots: ScreenshotCatcher?, nearby: NearbyService, focus: FocusReturner) {
        self.loginItem = loginItem
        self.screenshots = screenshots
        self.nearby = nearby
        self.focus = focus
        super.init()
    }

    /// Opens on `screen` (the pointer's if nil), below `top` if given: the bottom of the
    /// open shelf, which floats above normal windows and would cover Settings' top.
    ///
    /// From a full-screen app, macOS takes you to the desktop to show it, since a
    /// full-screen Space only holds that app's windows. The window's Space behavior is
    /// left as macOS sets it for that; joining the active Space would keep it there.
    func show(on screen: NSScreen? = nil, below top: CGFloat? = nil) {
        focus.rememberFrontmostApp()
        let window = self.window ?? makeWindow()
        self.window = window
        let isOpening = !window.isVisible
        if isOpening {
            let screen = screen ?? NotchGeometry.screen(containing: NSEvent.mouseLocation)
            area = screen.map { Self.area(on: $0, below: top) }
            fit(window, animate: false)
            place(window, area: area)
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
            clearCaret(in: window)
        }
        updateBrowsing()
    }

    /// The tab showing, or the one the window opens on.
    var selectedTab: Tab {
        tabs.flatMap { Tab(rawValue: $0.selectedTabViewItemIndex) } ?? .general
    }

    func select(_ tab: Tab) {
        _ = window ?? makeWindow()
        tabs?.selectedTabViewItemIndex = tab.rawValue
    }

    // MARK: - NSWindowDelegate

    /// Polka has no other window that can take focus, so when Settings closes macOS
    /// leaves Polka active with nothing to type into. Hand focus back instead.
    func windowWillClose(_ notification: Notification) {
        focus.handBack(after: "Settings")
        updateBrowsing(isClosing: true)
        // A tick later, once the window is off screen.
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    /// The screen's room for windows, with its top lowered to `top` if that's lower.
    static func area(on screen: NSScreen, below top: CGFloat?) -> NSRect {
        var area = screen.visibleFrame
        if let top, top < area.maxY, top > area.minY {
            area.size.height = top - area.minY
        }
        return area
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        // Polka sizes the window itself (`fit`), keeping its top edge where it is.
        tabs.transitionOptions = []
        for tab in Tab.allCases {
            let content = NSHostingController(rootView: form(for: tab))
            // The window doesn't take the form's full height on its own, which can be
            // taller than a small screen.
            content.sizingOptions = []
            // The window's title follows the tab, as in other Mac apps' settings.
            content.title = tab.title
            let item = NSTabViewItem(viewController: content)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.onSelect = { [weak self] in self?.tabChanged() }
        self.tabs = tabs
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        // Icons over their names, centered, like System Settings' old panes and Safari's.
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        Log.app.info("Settings window created")
        return window
    }

    @ViewBuilder
    private func form(for tab: Tab) -> some View {
        switch tab {
        case .general: SettingsView(loginItem: loginItem, screenshots: screenshots)
        case .nearby: NearbySettingsView(nearby: nearby)
        }
    }

    private func tabChanged() {
        guard let window, window.isVisible else { return }
        fit(window, animate: true)
        clearCaret(in: window)
        updateBrowsing()
    }

    /// Browsing keeps the Wi-Fi radio hopping to the peer-to-peer channel, so only
    /// while the Nearby Sharing tab is on screen.
    private func updateBrowsing(isClosing: Bool = false) {
        let wanted = !isClosing && window?.isVisible == true && selectedTab == .nearby
        guard wanted != isBrowsing else { return }
        isBrowsing = wanted
        if wanted { nearby.beginBrowsing() } else { nearby.endBrowsing() }
    }

    /// AppKit puts the caret in a form's first text field when it shows, and here
    /// that's the hex code or the name, which you rarely want to type. SwiftUI may
    /// place it a moment later, hence once more on the next pass.
    private func clearCaret(in window: NSWindow) {
        window.makeFirstResponder(nil)
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    /// As tall as the tab's whole form, or as tall as the screen allows, with the form
    /// scrolling. The top edge stays put, so a window reopened where you left it
    /// doesn't jump, and switching tabs grows or shrinks it downward.
    private func fit(_ window: NSWindow, animate: Bool) {
        let frame = window.frame
        // The title bar and the tabs' toolbar.
        let chrome = frame.height - window.contentRect(forFrameRect: frame).height
        var height = measuredFormHeight(for: selectedTab)
        if let area {
            height = min(height, area.height - chrome - Self.screenMargin * 2)
        }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: height)).size
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                        display: true, animate: animate)
    }

    /// A tab's full form height, from a copy that doesn't scroll and so takes all the
    /// room it needs.
    func measuredFormHeight(for tab: Tab) -> CGFloat {
        if let height = formHeights[tab] { return height }
        let copy = NSHostingView(rootView: form(for: tab)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true))
        let height = copy.fittingSize.height
        formHeights[tab] = height
        return height
    }

    /// A little above the middle of the area like `NSWindow.center()`, and never past
    /// its top (the menu bar or the shelf) or the screen's bottom. Reopened on the
    /// same screen, it stays where you left it, moved down if the shelf would cover it.
    private func place(_ window: NSWindow, area: NSRect?) {
        let frame = window.frame
        guard let area else {
            if !hasBeenPlaced { window.center() }
            hasBeenPlaced = true
            return
        }
        if hasBeenPlaced, area.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            // Back where you left it, though it may have grown since, or been left
            // where the shelf now is.
            if frame.maxY > area.maxY - Self.screenMargin {
                window.setFrameOrigin(CGPoint(x: frame.minX, y: area.maxY - Self.screenMargin - frame.height))
            } else if frame.minY < area.minY {
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

/// Says when another tab is picked, so the window can take its height.
private final class SettingsTabController: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
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
