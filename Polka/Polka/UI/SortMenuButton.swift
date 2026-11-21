import AppKit
import SwiftUI

/// The sort button in the panel's header, left of the gear: a symbol that opens a
/// "Sort By" menu with a checkmark on the current choice, like Finder's.
struct SortMenuButton: View {
    let sort: ShelfSort
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    /// The shelf is open, so hover counts.
    let isActive: Bool
    let onChoose: @MainActor (ShelfSort) -> Void

    /// #2881DB, the color of the symbol's glass while a sort is on. Fixed, not the
    /// system accent.
    static let activeColor = Color(.sRGB, red: 0x28 / 255, green: 0x81 / 255, blue: 0xDB / 255)

    /// Each press parts the arrows once.
    @State private var presses = 0

    var body: some View {
        HeaderMenuButton(label: "Sort By",
                         isActive: isActive,
                         makeMenu: makeMenu,
                         onPress: { presses += 1 }) { _, isGlowing in
            // Blue glass while the shelf is sorted, so a sorted shelf can be told apart
            // from one arranged by hand.
            SortArrowsSymbol(presses: presses,
                             tint: sort == .none ? nil : Self.activeColor,
                             height: height,
                             isGlowing: isGlowing)
        }
        .animation(.easeOut(duration: 0.15), value: sort)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Sort By"))
        for choice in ShelfSort.allCases {
            let item = NSMenuItem(title: choice.title) { onChoose(choice) }
            item.state = choice == sort ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
