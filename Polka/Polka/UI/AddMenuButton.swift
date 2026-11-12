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
        return menu
    }
}
