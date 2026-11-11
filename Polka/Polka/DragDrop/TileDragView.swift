import AppKit
import SwiftUI

/// A transparent AppKit layer over a shelf tile that starts drags out of the panel.
///
/// This is AppKit for the same reason drops are: SwiftUI's drag support expects a
/// window that can become key, and the notch panel never does. Because this layer
/// sits on top of the tile and receives the presses on its picture and name, it also
/// reports clicks (for selecting) and double-clicks (for opening), reports hover with
/// a tracking area marked `.activeAlways` so it works while another app is
/// frontmost, and shows the tile's right-click menu.
final class TileDragView: NSView {
    /// One entry in the tile's right-click menu.
    struct MenuEntry {
        let title: String
        var isChecked = false
        var isEnabled = true
        /// Puts a divider above this entry, to start a new group.
        var startsGroup = false
        let action: @MainActor () -> Void
    }

    weak var source: ShelfDragSource?
    var onHoverChanged: ((Bool) -> Void)?
    /// A press that ended without becoming a drag.
    var onClick: ((SelectionClick) -> Void)?
    /// The second click of a double-click. The first one has already selected the tile.
    var onDoubleClick: (() -> Void)?
    /// Asked when a drag begins: this tile's item, or the whole selection.
    var itemsToDrag: (() -> [ShelfItem])?
    /// Off for items whose file is missing, so there is nothing broken to drag.
    var isDragEnabled = true
    /// Empty means no menu.
    var menuEntries: [MenuEntry] = []
    /// Where a press counts, measured from the top left as SwiftUI does: the picture
    /// and the text under it, like an icon on the desktop. Presses on the blank rest
    /// of the tile fall through to the grid, where they clear the selection or start
    /// a selection rectangle. Nil means the whole tile.
    var pressArea: CGRect?
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

    /// AppKit asks this to find which view gets a press, a right-click or a scroll.
    /// Returning nil passes it to whatever is behind. Hover isn't affected: the
    /// tracking area still covers the whole tile, so its buttons show anywhere on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pressArea, let superview else { return super.hitTest(point) }
        // `point` is in the superview's coordinates, and AppKit measures from the bottom.
        let local = convert(point, from: superview)
        let fromTop = CGPoint(x: local.x, y: bounds.height - local.y)
        // A little slack, so the edge of a picture or name isn't fiddly to hit.
        guard pressArea.insetBy(dx: -4, dy: -4).contains(fromTop) else { return nil }
        return super.hitTest(point)
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
        // Still set means the pointer never moved far enough to drag. macOS counts the
        // clicks itself, using the double-click speed set in System Settings.
        if pressPoint != nil {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                onClick?(pressClick)
            }
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
            if entry.startsGroup, index > 0 {
                menu.addItem(.separator())
            }
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
    let pressArea: CGRect?
    let onHoverChanged: (Bool) -> Void
    let onClick: (SelectionClick) -> Void
    let onDoubleClick: () -> Void
    let itemsToDrag: () -> [ShelfItem]

    func makeNSView(context: Context) -> TileDragView {
        TileDragView()
    }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.source = source
        view.isDragEnabled = isDragEnabled
        view.menuEntries = menuEntries
        view.pressArea = pressArea
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.itemsToDrag = itemsToDrag
    }
}
