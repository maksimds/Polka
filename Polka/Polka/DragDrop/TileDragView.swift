import AppKit
import SwiftUI

/// A transparent AppKit layer over a shelf tile that starts drags out of the panel.
///
/// This is AppKit for the same reason drops are: SwiftUI's drag support expects a
/// window that can become key, and the notch panel never does. It also reports
/// hover, using a tracking area marked `.activeAlways` so it works while another
/// app is frontmost.
final class TileDragView: NSView {
    var item: ShelfItem?
    var image: NSImage?
    weak var source: ShelfDragSource?
    var onHoverChanged: ((Bool) -> Void)?

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
        guard let pressPoint, let item, let image, let source else { return }
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
}

/// Puts a `TileDragView` into the SwiftUI tile.
struct ShelfItemDragHandle: NSViewRepresentable {
    let item: ShelfItem
    let image: NSImage
    let source: ShelfDragSource
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TileDragView {
        TileDragView()
    }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.item = item
        view.image = image
        view.source = source
        view.onHoverChanged = onHoverChanged
    }
}
