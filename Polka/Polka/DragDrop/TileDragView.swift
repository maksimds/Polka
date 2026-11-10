import AppKit
import SwiftUI

/// A transparent AppKit layer over a shelf tile that starts drags out of the panel.
///
/// This is AppKit for the same reason drops are: SwiftUI's drag support expects a
/// window that can become key, and the notch panel never does. Because this layer
/// sits on top of the tile and receives every press, it also reports clicks (for
/// selecting), reports hover with a tracking area marked `.activeAlways` so it
/// works while another app is frontmost, and shows the tile's right-click menu.
final class TileDragView: NSView {
    /// One entry in the tile's right-click menu.
    struct MenuEntry {
        let title: String
        var isChecked = false
        var isEnabled = true
        let action: @MainActor () -> Void
    }

    weak var source: ShelfDragSource?
    var onHoverChanged: ((Bool) -> Void)?
    /// A press that ended without becoming a drag.
    var onClick: ((SelectionClick) -> Void)?
    /// Asked when a drag begins: this tile's item, or the whole selection.
    var itemsToDrag: (() -> [ShelfItem])?
    /// Off for items whose file is missing, so there is nothing broken to drag.
    var isDragEnabled = true
    /// Empty means no menu.
    var menuEntries: [MenuEntry] = []
    /// The entries of the menu that is open, so a choice runs the action it showed.
    private var shownEntries: [MenuEntry] = []

    /// Where the press started. Nil once a drag has begun or the press has ended.
    private var pressPoint: NSPoint?
    /// The keys held when the press started, which decide what a click selects.
    private var pressClick = SelectionClick.only

    /// How far the pointer has to move before a press counts as a drag.
    private let dragThreshold: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addHoverTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addHoverTracking()
    }

    private func addHoverTracking() {
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    /// Accepts the press even though the panel's window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        pressClick = SelectionClick(event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragEnabled, let pressPoint, let source, let itemsToDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= dragThreshold else { return }

        self.pressPoint = nil
        // Hover events pause during a drag, so clear it now rather than leave it stuck on.
        onHoverChanged?(false)
        source.startDrag(of: itemsToDrag(), at: point, from: self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        // Still set means the pointer never moved far enough to drag.
        if pressPoint != nil {
            onClick?(pressClick)
        }
        pressPoint = nil
    }

    // MARK: - Right-click menu

    /// AppKit asks for this on a right-click and shows the menu itself. A menu
    /// doesn't need the panel to become key, so focus stays with the app in front.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuEntries.isEmpty else { return nil }
        shownEntries = menuEntries
        let menu = NSMenu()
        // Each entry says for itself whether it can be chosen.
        menu.autoenablesItems = false
        for (index, entry) in shownEntries.enumerated() {
            let menuItem = NSMenuItem(title: entry.title, action: #selector(menuEntryChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.state = entry.isChecked ? .on : .off
            menuItem.isEnabled = entry.isEnabled
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func menuEntryChosen(_ sender: NSMenuItem) {
        guard shownEntries.indices.contains(sender.tag) else { return }
        shownEntries[sender.tag].action()
    }
}

extension SelectionClick {
    /// Command wins over Shift, as in Finder.
    init(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            self = .toggle
        } else if flags.contains(.shift) {
            self = .range
        } else {
            self = .only
        }
    }
}

/// Puts a `TileDragView` into the SwiftUI tile.
struct ShelfItemDragHandle: NSViewRepresentable {
    let source: ShelfDragSource
    let isDragEnabled: Bool
    let menuEntries: [TileDragView.MenuEntry]
    let onHoverChanged: (Bool) -> Void
    let onClick: (SelectionClick) -> Void
    let itemsToDrag: () -> [ShelfItem]

    func makeNSView(context: Context) -> TileDragView {
        TileDragView()
    }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.source = source
        view.isDragEnabled = isDragEnabled
        view.menuEntries = menuEntries
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        view.itemsToDrag = itemsToDrag
    }
}
