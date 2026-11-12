import AppKit
import SwiftUI

/// The + in the panel's header, left of the sort button. It opens an "Add New" menu
/// for adding a link or files without dragging them in.
struct AddMenuButton: View {
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    let onAddLink: @MainActor () -> Void
    let onAddFiles: @MainActor () -> Void

    var body: some View {
        HeaderMenuButton(systemName: "plus",
                         color: .white.opacity(0.55),
                         height: height,
                         label: "Add New",
                         makeMenu: makeMenu)
    }

    /// Each choice ends in "…" because it asks for more before anything is added.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Add New"))
        menu.addItem(NSMenuItem(title: "Link…", action: onAddLink))
        menu.addItem(NSMenuItem(title: "File…", action: onAddFiles))
        return menu
    }
}
