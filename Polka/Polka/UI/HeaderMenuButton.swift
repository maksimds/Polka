import AppKit
import SwiftUI

/// A symbol in the panel's header that opens a menu, like the sort and + buttons.
///
/// The menu is AppKit's, opened by an AppKit layer over the symbol, rather than a
/// SwiftUI `Menu`, so Polka decides where it goes: right under the symbol, with its
/// right edge lined up with the symbol's. That keeps it over the panel. Opened to
/// the right, it would hang past the panel's edge, and the panel collapses once the
/// pointer has been out there. Menus don't need their window to be key, so this
/// works in the never-key panel, like the tiles' right-click menu.
struct HeaderMenuButton: View {
    let systemName: String
    /// Colors the glass symbol instead of white.
    var tint: Color?
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    /// What VoiceOver calls the button.
    let label: String
    /// Built each time the menu opens, so it always shows the current state.
    let makeMenu: @MainActor () -> NSMenu

    /// Like the gear: the frame is just the symbol, and the area you can click
    /// reaches this much further around it.
    static let clickMargin = Glass.headerClickMargin

    var body: some View {
        GlassHeaderSymbol(systemName: systemName, tint: tint, height: height)
            .accessibilityHidden(true)
            .overlay {
                HeaderMenuArea(label: label, makeMenu: makeMenu)
                    .padding(-Self.clickMargin)
            }
    }
}

private struct HeaderMenuArea: NSViewRepresentable {
    let label: String
    let makeMenu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> HeaderMenuView {
        HeaderMenuView()
    }

    func updateNSView(_ view: HeaderMenuView, context: Context) {
        view.label = label
        view.makeMenu = makeMenu
    }
}

/// Takes the press on a header symbol and shows its menu.
final class HeaderMenuView: NSView {
    var label = ""
    var makeMenu: (@MainActor () -> NSMenu)?

    /// Measured from the top, so placing the menu below reads top to bottom.
    override var isFlipped: Bool { true }

    /// The panel is never the key window, so without this the first click would
    /// only be taken as bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Opens on the press, as menu buttons do. AppKit then follows the pointer
    /// itself, so pressing, sliding to a choice and letting go works too.
    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    private func showMenu() {
        guard let menu = makeMenu?() else { return }
        // The symbol is the click area minus its margin. The menu's top left goes
        // where its right edge lines up with the symbol's, just under the header.
        let margin = HeaderMenuButton.clickMargin
        let location = NSPoint(x: bounds.maxX - margin - menu.size.width,
                               y: bounds.maxY - margin + 4)
        // Returns once the menu has closed, after any choice has run.
        menu.popUp(positioning: nil, at: location, in: self)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .menuButton
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }
}

extension NSMenuItem {
    /// A menu item that runs `action` when chosen.
    @MainActor
    convenience init(title: String, action: @escaping @MainActor () -> Void) {
        let target = MenuItemAction(action)
        self.init(title: title, action: #selector(MenuItemAction.run), keyEquivalent: "")
        self.target = target
        // An item only holds its target weakly; this keeps it alive as long as the item.
        representedObject = target
    }
}

@MainActor
private final class MenuItemAction: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
