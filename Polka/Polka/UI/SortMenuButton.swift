import AppKit
import SwiftUI

/// The sort button in the panel's header, left of the gear: a symbol that opens a
/// "Sort By" menu with a checkmark on the current choice, like Finder's.
///
/// The menu is AppKit's, opened by an AppKit layer over the symbol, rather than a
/// SwiftUI `Menu`, so Polka decides where it goes: right under the symbol, with its
/// right edge lined up with the symbol's. That keeps it over the panel. Opened to
/// the right, it would hang past the panel's edge, and the panel collapses once the
/// pointer has been out there. Menus don't need their window to be key, so this
/// works in the never-key panel, like the tiles' right-click menu.
struct SortMenuButton: View {
    let sort: ShelfSort
    /// The header's height, so the symbol is centered on it like the gear.
    let height: CGFloat
    let onChoose: @MainActor (ShelfSort) -> Void

    /// Like the gear: the frame is just the symbol, and the area you can click
    /// reaches this much further around it.
    fileprivate static let clickMargin: CGFloat = 8

    /// #2881DB, the symbol's color while a sort is on. Fixed, not the system accent.
    static let activeColor = Color(.sRGB, red: 0x28 / 255, green: 0x81 / 255, blue: 0xDB / 255)

    var body: some View {
        Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: 13, weight: .medium))
            // Blue while the shelf is sorted, so a sorted shelf can be told apart from
            // one arranged by hand.
            .foregroundStyle(sort == .none ? Color.white.opacity(0.55) : Self.activeColor)
            .animation(.easeOut(duration: 0.15), value: sort)
            .frame(height: height)
            .accessibilityHidden(true)
            .overlay {
                SortMenuArea(sort: sort, onChoose: onChoose)
                    .padding(-Self.clickMargin)
            }
    }
}

private struct SortMenuArea: NSViewRepresentable {
    let sort: ShelfSort
    let onChoose: @MainActor (ShelfSort) -> Void

    func makeNSView(context: Context) -> SortMenuView {
        SortMenuView()
    }

    func updateNSView(_ view: SortMenuView, context: Context) {
        view.sort = sort
        view.onChoose = onChoose
    }
}

/// Takes the press on the sort symbol and shows the menu.
final class SortMenuView: NSView {
    var sort: ShelfSort = .none
    var onChoose: (@MainActor (ShelfSort) -> Void)?

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
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Sort By"))
        for choice in ShelfSort.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == sort ? .on : .off
            menu.addItem(item)
        }
        // The symbol is the click area minus its margin. The menu's top left goes
        // where its right edge lines up with the symbol's, just under the header.
        let margin = SortMenuButton.clickMargin
        let location = NSPoint(x: bounds.maxX - margin - menu.size.width,
                               y: bounds.maxY - margin + 4)
        // Returns once the menu has closed, after any choice has run.
        menu.popUp(positioning: nil, at: location, in: self)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = ShelfSort(rawValue: raw) else { return }
        onChoose?(choice)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .menuButton
    }

    override func accessibilityLabel() -> String? {
        "Sort By"
    }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }
}
