import AppKit
import SwiftUI

/// The + in the panel's header, left of the sort button. It opens an "Add New" menu
/// for adding a link or files without dragging them in, or what's on the clipboard.
struct AddMenuButton: View {
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    let onAddLink: @MainActor () -> Void
    let onAddFiles: @MainActor () -> Void
    /// What "Paste" would add, read as the menu opens. Nil greys the item out.
    let pasteable: @MainActor () -> Pasteable?
    let onPaste: @MainActor (Pasteable) -> Void

    var body: some View {
        HeaderMenuButton(systemName: "plus",
                         height: height,
                         label: "Add New",
                         makeMenu: makeMenu)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Add New"))
        menu.addItem(NSMenuItem(title: "Link", action: onAddLink))
        menu.addItem(NSMenuItem(title: "File", action: onAddFiles))
        menu.addItem(.separator())
        // Named after what's on the clipboard ("Paste 3 Files", "Paste Image"), so you
        // know what you'll get. The ⌘V says the same works with the pointer over the
        // shelf (`PasteShortcut`); pressed while this menu is open, it chooses this item.
        let contents = pasteable()
        let pasteItem = NSMenuItem(title: contents?.menuTitle ?? "Paste") { [onPaste] in
            if let contents { onPaste(contents) }
        }
        pasteItem.keyEquivalent = "v"
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.isEnabled = contents != nil
        menu.addItem(pasteItem)
        return menu
    }
}
