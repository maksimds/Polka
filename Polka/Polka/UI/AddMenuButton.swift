import AppKit
import SwiftUI

/// The + in the panel's header, left of the sort button. It opens an "Add New" menu
/// for adding a link or files without dragging them in, or what's on the clipboard.
struct AddMenuButton: View {
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    /// The shelf is open, so hover counts.
    let isActive: Bool
    let onAddLink: @MainActor () -> Void
    let onAddFiles: @MainActor () -> Void
    /// What "Paste" would add, read as the menu opens. Nil greys the item out.
    let pasteable: @MainActor () -> Pasteable?
    let onPaste: @MainActor (Pasteable) -> Void

    var body: some View {
        // The + turns into an × while its menu is open.
        HeaderMenuButton(label: "Add New", isActive: isActive, makeMenu: makeMenu) { isOpen, isGlowing in
            GlassHeaderGlyph(height: height, isGlowing: isGlowing) {
                PlusCrossGlyph(isCross: isOpen)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Add New"))
        menu.addItem(NSMenuItem(title: "Link", action: onAddLink))
        menu.addItem(NSMenuItem(title: "File", action: onAddFiles))
        menu.addItem(.separator())
        menu.addItem(.paste(pasteable(), action: onPaste))
        return menu
    }
}

extension NSMenuItem {
    /// "Paste", as the + menu and the shelf's free space menu show it: named after
    /// what's on the clipboard ("Paste 3 Files", "Paste Image"), so you know what
    /// you'll get, and greyed out when there's nothing Polka can keep. The ⌘V says
    /// the same works with the pointer over the shelf (`ShelfShortcuts`); pressed
    /// while the menu is open, it chooses this item. Its menu needs
    /// `autoenablesItems` off, or AppKit decides whether it can be chosen.
    @MainActor
    static func paste(_ contents: Pasteable?, action: @escaping @MainActor (Pasteable) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: contents?.menuTitle ?? "Paste") {
            if let contents { action(contents) }
        }
        item.keyEquivalent = "v"
        item.keyEquivalentModifierMask = .command
        item.isEnabled = contents != nil
        return item
    }
}
