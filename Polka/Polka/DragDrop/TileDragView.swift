import AppKit
import SwiftUI

/// A transparent AppKit layer over a shelf tile that starts its drags, out of the
/// panel or to another place on the shelf.
///
/// This is AppKit for the same reason drops are: SwiftUI's drag support expects a
/// window that can become key, and the notch panel never does. Because this layer
/// sits on top of the tile and receives the presses on its picture and name, it also
/// reports clicks (for selecting) and double-clicks (for opening), reports hover with
/// a tracking area marked `.activeAlways` so it works while another app is
/// frontmost, and shows the tile's right-click menu. Presses and hover both count
/// only on the tile's `shape`, what's drawn of it.
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
    var dragContents: (() -> ShelfDragContents)?
    /// Empty means no menu.
    var menuEntries: [MenuEntry] = []
    /// What counts as the tile, for presses and hover, measured from the top left as
    /// SwiftUI does: the visible part of the picture, the name and the line under it,
    /// as drawn, like an icon on the desktop. Presses on the blank rest of the column
    /// fall through to the grid, where they clear the selection or start a selection
    /// rectangle, and the pointer there doesn't hover the tile. Empty means the whole
    /// tile, until SwiftUI has measured it.
    var shape: [CGRect] = []
    /// Where the remove button is, from the top left. While it shows, the pointer on
    /// it still hovers the tile, so it can be reached where it hangs past the picture.
    var removeButtonArea: CGRect?
    /// Whether the tile shows itself hovered, as SwiftUI last said. SwiftUI clears it
    /// on its own when the panel closes, so it's kept in step from there.
    var isHoverShown = false
    /// The entries of the menu that is open, so a choice runs the action it showed.
    private var shownEntries: [MenuEntry] = []

    /// Where the press started. Nil once a drag has begun or the press has ended.
    private var pressPoint: NSPoint?
    /// The keys held when the press started, which decide what a click selects.
    private var pressClick = SelectionClick.only

    /// How far the pointer has to move before a press counts as a drag.
    private let dragThreshold: CGFloat = 4

    /// True while the grid this tile is in scrolls, from the swipe until it comes to
    /// rest, momentum included.
    private var isScrolling = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addHoverTracking()
        observeScrolling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addHoverTracking()
        observeScrolling()
    }

    /// The area covers the whole column, which is a rectangle, and also reports moves
    /// inside it, so each move can be checked against the tile's shape.
    private func addHoverTracking() {
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false)
    }

    /// While the grid scrolls, tiles slide under a pointer that isn't moving. That
    /// isn't hovering, so they don't light up as they pass, as in Finder.
    private func updateHover(at pointInWindow: NSPoint) {
        guard !isScrolling else { return }
        setHover(isOnTile(pointInWindow, countingRemoveButton: true))
    }

    /// Tells SwiftUI only when it changes, not on every move.
    private func setHover(_ hovering: Bool) {
        guard hovering != isHoverShown else { return }
        isHoverShown = hovering
        onHoverChanged?(hovering)
    }

    /// True when a point in the window is on the tile's shape, or on its remove
    /// button while that shows, and in the part of the grid that's on screen.
    private func isOnTile(_ pointInWindow: NSPoint, countingRemoveButton: Bool) -> Bool {
        let local = convert(pointInWindow, from: nil)
        // Inside SwiftUI's scroll view, a tile's `visibleRect` isn't trimmed to the
        // tile. It's the whole visible grid, for every tile, so `bounds` is checked too.
        guard bounds.contains(local), visibleRect.contains(local) else { return false }
        return isOnShape(fromTop(local), countingRemoveButton: countingRemoveButton)
    }

    private func isOnShape(_ point: CGPoint, countingRemoveButton: Bool) -> Bool {
        if shape.isEmpty { return true }
        if shape.contains(where: { $0.contains(point) }) { return true }
        return countingRemoveButton && isHoverShown && removeButtonArea?.contains(point) == true
    }

    /// AppKit measures from the bottom; the shape is measured from the top, as SwiftUI does.
    private func fromTop(_ local: NSPoint) -> CGPoint {
        CGPoint(x: local.x, y: bounds.height - local.y)
    }

    // MARK: - Scrolling

    /// A trackpad scroll is a "live scroll": the scroll view says when it starts and
    /// when it has come to rest. (A mouse wheel's clicks aren't, so tiles still light
    /// up under one.) Selector-based observers go away with the view on their own.
    private func observeScrolling() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveScrollStarted(_:)),
                           name: NSScrollView.willStartLiveScrollNotification, object: nil)
        center.addObserver(self, selector: #selector(liveScrollEnded(_:)),
                           name: NSScrollView.didEndLiveScrollNotification, object: nil)
    }

    @objc private func liveScrollStarted(_ notification: Notification) {
        // Every scroll view in Polka posts these, Settings' form too. Only the grid's count.
        guard let scrollView = notification.object as? NSScrollView, isDescendant(of: scrollView) else { return }
        isScrolling = true
    }

    /// Any scroll ending clears it, since only one can run at a time, so a tile can't
    /// be left thinking the grid still scrolls.
    @objc private func liveScrollEnded(_ notification: Notification) {
        guard isScrolling else { return }
        isScrolling = false
        // A tile that came to rest under the pointer had its arrival ignored, and
        // AppKit won't report it again, so check for it now.
        if let window {
            updateHover(at: window.mouseLocationOutsideOfEventStream)
        }
    }

    /// AppKit asks this to find which view gets a press, a right-click or a scroll.
    /// Returning nil passes it to whatever is behind. Only the tile's shape takes
    /// presses; the remove button is SwiftUI's, on top, and takes its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        // `point` is in the superview's coordinates.
        guard isOnShape(fromTop(convert(point, from: superview)), countingRemoveButton: false) else { return nil }
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
        guard let pressPoint, let source, let dragContents else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= dragThreshold else { return }

        self.pressPoint = nil
        // Hover events pause during a drag, so clear it now rather than leave it stuck on.
        setHover(false)
        source.startDrag(of: dragContents(), at: point, from: self, event: event)
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
    let menuEntries: [TileDragView.MenuEntry]
    /// See `TileDragView.shape`.
    let shape: [CGRect]
    let removeButtonArea: CGRect?
    let isHovering: Bool
    let onHoverChanged: (Bool) -> Void
    let onClick: (SelectionClick) -> Void
    let onDoubleClick: () -> Void
    let dragContents: () -> ShelfDragContents

    func makeNSView(context: Context) -> TileDragView {
        TileDragView()
    }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.source = source
        view.menuEntries = menuEntries
        view.shape = shape
        view.removeButtonArea = removeButtonArea
        view.isHoverShown = isHovering
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.dragContents = dragContents
    }
}
