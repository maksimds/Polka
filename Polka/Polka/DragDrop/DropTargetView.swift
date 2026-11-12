import AppKit

/// Where a drop of the shelf's own tiles puts them.
struct TileDrop: Equatable {
    /// The spot the first of them lands in, counted among the tiles that stay.
    let target: Int
    /// Where each dragged picture ends up, in the drag's order, in SwiftUI's
    /// coordinates (from the panel's top left). Empty if they can't all be placed,
    /// in which case the pictures don't glide.
    let landingFrames: [CGRect]
}

/// AppKit drop destination that wraps the SwiftUI content.
///
/// SwiftUI's `.onDrop` tries to make its window key when a drag enters, and the
/// notch panel refuses key status (so it never steals focus). An AppKit
/// `NSDraggingDestination` does not need key status, so drops work reliably here.
///
/// Two kinds of drag arrive here. Files and links from other apps are stored. A
/// drag of the shelf's own tiles moves them to a new place on the shelf; AppKit only
/// sets `draggingSource` for drags that started inside Polka, which is how the two
/// are told apart.
///
/// The callbacks run one run-loop tick after AppKit's drag callback returns.
/// AppKit is still mid-drag during its callback, and changing state then makes the
/// window redraw too early, which logs "Reentrant message: kDragIPCCompleted".
final class DropTargetView: NSView {
    var onTargetChanged: (@MainActor (Bool) -> Void)?
    var onDrop: (@MainActor ([DroppedItem]) -> Void)?
    /// The one exception to waiting a tick: an app's file promise has to be asked for
    /// during the drop itself, while the drag is still going. Whatever it calls must
    /// only start receiving, and leave state changes until the files arrive.
    var onPromisesDropped: (@MainActor ([NSFilePromiseReceiver]) -> Void)?

    /// A tile being moved is over the panel, at this point in SwiftUI's coordinates.
    /// Also called while the pointer holds still, since AppKit keeps asking.
    var onTileMoved: (@MainActor (CGPoint) -> Void)?
    /// A tile being moved has left the panel.
    var onTileExited: (@MainActor () -> Void)?
    /// Asked during the drop itself, so it must only work things out and change
    /// nothing: where tiles dropped at this point would go.
    var tileDrop: (@MainActor (CGPoint) -> TileDrop?)?
    /// Tiles were dropped. True when their pictures are gliding into place.
    var onTileDropped: (@MainActor (TileDrop, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.draggedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.draggedTypes)
    }

    /// AppKit only reports drags carrying one of these. Tiles carry files and links,
    /// except a missing file, which carries Polka's own type.
    private static let draggedTypes = DropReceiver.acceptedPasteboardTypes + [ShelfDragSource.shelfOnlyType]

    /// Hosts a child view (the SwiftUI content) that fills this view.
    func embed(_ child: NSView) {
        child.frame = bounds
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.isTileDrag(sender) {
            return tileMoved(sender)
        }
        let canAccept = isAcceptable(sender)
        Log.drop.debug("Drag entered panel, acceptable: \(canAccept)")
        reportTargetChanged(canAccept)
        return canAccept ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.isTileDrag(sender) {
            return tileMoved(sender)
        }
        return isAcceptable(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, Self.isTileDrag(sender) {
            DispatchQueue.main.async { [weak self] in self?.onTileExited?() }
            return
        }
        Log.drop.debug("Drag exited panel")
        reportTargetChanged(false)
    }

    /// For tiles, this is where AppKit is told whether to glide their pictures into
    /// their new places. With Reduce Motion they just disappear and the tiles fade in.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.isTileDrag(sender) {
            sender.animatesToDestination = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.isTileDrag(sender) {
            return performTileDrop(sender)
        }
        // The pasteboard is only readable during this call, so read it now.
        let items = DropReceiver.items(from: sender.draggingPasteboard)
        let accepted = !items.isEmpty
        Log.drop.debug("Drop performed, accepted: \(accepted)")
        guard accepted else { return false }

        let promises = items.compactMap(\.promise)
        if !promises.isEmpty {
            onPromisesDropped?(promises)
        }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(items) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        reportTargetChanged(false)
    }

    // MARK: - Moving tiles

    static func isTileDrag(_ drag: NSDraggingInfo) -> Bool {
        drag.draggingSource is ShelfDragSource
    }

    /// A move if the keys held allow it. Holding Option or Command narrows what the
    /// drag offers, and the tile still moves then.
    private func tileMoved(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = swiftUIPoint(sender.draggingLocation)
        DispatchQueue.main.async { [weak self] in self?.onTileMoved?(point) }
        let offered = sender.draggingSourceOperationMask
        return [NSDragOperation.move, .generic, .copy].first { offered.contains($0) } ?? []
    }

    /// Works out where the tiles go, then points each dragged picture at its new
    /// spot so AppKit glides it there. The tiles themselves move a tick later.
    private func performTileDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = tileDrop?(swiftUIPoint(sender.draggingLocation)) else { return false }
        let gliding = sender.animatesToDestination && !drop.landingFrames.isEmpty
        if gliding {
            let frames = drop.landingFrames.map(appKitRect)
            // Every item can be read as an NSPasteboardItem, so this visits them all,
            // in the order the drag was started with.
            sender.enumerateDraggingItems(options: [],
                                          for: self,
                                          classes: [NSPasteboardItem.self],
                                          searchOptions: [:]) { item, index, _ in
                guard frames.indices.contains(index) else { return }
                item.draggingFrame = frames[index]
            }
        }
        Log.drop.debug("Tiles dropped at spot \(drop.target), gliding: \(gliding)")
        DispatchQueue.main.async { [weak self] in self?.onTileDropped?(drop, gliding) }
        return true
    }

    /// AppKit measures from the bottom left of the window, and SwiftUI from the top
    /// left of the content, which fills this view.
    private func swiftUIPoint(_ windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func appKitRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Drops from other apps

    /// Drags from inside Polka are tiles, handled above, and never stored again.
    private func isAcceptable(_ drag: NSDraggingInfo) -> Bool {
        drag.draggingSource == nil && DropReceiver.canAccept(drag.draggingPasteboard)
    }

    private func reportTargetChanged(_ targeted: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onTargetChanged?(targeted) }
    }
}
