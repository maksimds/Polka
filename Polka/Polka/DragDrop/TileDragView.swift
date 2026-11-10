import AppKit
import SwiftUI

/// A transparent AppKit layer over a shelf tile that starts drags out of the panel.
///
/// This is AppKit for the same reason drops are: SwiftUI's drag support expects a
/// window that can become key, and the notch panel never does. It also reports
/// hover, using a tracking area marked `.activeAlways` so it works while another
/// app is frontmost, and shows the tile's right-click menu, because this layer sits
/// on top of the tile and is what receives the click.
final class TileDragView: NSView {
    /// One entry in the tile's right-click menu.
    struct MenuEntry {
        let title: String
        var isChecked = false
        var isEnabled = true
        let action: @MainActor () -> Void
    }

    var item: ShelfItem?
    var image: NSImage?
    weak var source: ShelfDragSource?
    var onHoverChanged: ((Bool) -> Void)?
    /// Off for items whose file is missing, so there is nothing broken to drag.
    var isDragEnabled = true
    /// Empty means no menu.
    var menuEntries: [MenuEntry] = []
    /// The entries of the menu that is open, so a choice runs the action it showed.
    private var shownEntries: [MenuEntry] = []

    /// Where the press started. Nil once a drag has begun or the press has ended.
    private var pressPoint: NSPoint?

    /// How far the pointer has to move before a press counts as a drag.
    private let dragThreshold: CGFloat = 4
    private let previewSide: CGFloat = 52

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
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragEnabled, let pressPoint, let item, let image, let source else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= dragThreshold else { return }

        self.pressPoint = nil
        // Hover events pause during a drag, so clear it now rather than leave it stuck on.
        onHoverChanged?(false)
        let frame = NSRect(x: point.x - previewSide / 2,
                           y: point.y - previewSide / 2,
                           width: previewSide,
                           height: previewSide)
        source.startDrag(of: item, image: image, imageFrame: frame, from: self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
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

/// Puts a `TileDragView` into the SwiftUI tile.
struct ShelfItemDragHandle: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage
    let source: ShelfDragSource
    let isDragEnabled: Bool
    let menuEntries: [TileDragView.MenuEntry]
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TileDragView {
        TileDragView()
    }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.item = item
        view.image = image
        view.source = source
        view.isDragEnabled = isDragEnabled
        view.menuEntries = menuEntries
        view.onHoverChanged = onHoverChanged
    }
}
