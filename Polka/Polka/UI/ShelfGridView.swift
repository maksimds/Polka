import SwiftUI

/// What a tile can ask the app to do with its item. Each one collapses the panel
/// first, so the panel controller provides them.
struct ShelfItemCommands {
    /// Double-click: the file in its default app, or the link in the browser.
    let open: @MainActor (ShelfItem.ID) -> Void
    /// Right-click > Quick Look.
    let quickLook: @MainActor (ShelfItem.ID) -> Void
    /// Right-click > Get Info.
    let showInfo: @MainActor (ShelfItem.ID) -> Void
}

/// The shelf's items as a scrolling grid, newest first.
struct ShelfGridView: View {
    let items: [ShelfItem]
    /// False while the panel is closed or a drag out is running; the grid stays built.
    let isActive: Bool
    let missingItemIDs: Set<ShelfItem.ID>
    let copyingItemIDs: Set<ShelfItem.ID>
    let selection: Set<ShelfItem.ID>
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onClick: @MainActor (ShelfItem.ID, SelectionClick) -> Void
    let onClearSelection: @MainActor () -> Void
    let itemsToDrag: @MainActor (ShelfItem.ID) -> [ShelfItem]
    let onDelete: @MainActor (ShelfItem.ID) -> Void
    let onRemoveFromMenu: @MainActor (ShelfItem.ID) -> Void
    let onToggleTemporary: @MainActor (ShelfItem.ID) -> Void
    let onToggleKeepCopy: (@MainActor (ShelfItem.ID) -> Void)?
    let commands: ShelfItemCommands
    /// A selection rectangle starts, with the keys held: Shift adds, Command flips.
    let onMarqueeBegan: @MainActor (SelectionClick) -> Void
    /// The rectangle moved; these are the tiles it touches now.
    let onMarqueeChanged: @MainActor (Set<ShelfItem.ID>) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each tile's picture and text are in the visible area.
    @State private var pressAreas = PressAreas()
    /// The selection rectangle while you drag one. SwiftUI clears it when the drag ends.
    @GestureState private var marquee: CGRect?
    /// Where the current rectangle started, to tell a new rectangle from one that moved.
    @State private var marqueeStart: CGPoint?

    /// Five equal columns. Shared with the panel's header, which lines its name and
    /// gear up with the tiles.
    static let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    /// The grid's visible area, the same while it scrolls. Tiles report where they are
    /// in it, and the selection rectangle is drawn in it.
    static let viewportSpace = "ShelfGridViewport"

    /// A tile grows in when added and shrinks away when removed, while the others
    /// slide into place. Reduce Motion gets a fade.
    private var tileTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
    }

    private var reflowAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 8) {
                        ForEach(items) { item in
                            ShelfItemTile(item: item,
                                          isAvailable: !missingItemIDs.contains(item.id),
                                          isCopying: copyingItemIDs.contains(item.id),
                                          isSelected: selection.contains(item.id),
                                          isActive: isActive,
                                          images: images,
                                          dragSource: dragSource,
                                          onClick: { onClick(item.id, $0) },
                                          itemsToDrag: { itemsToDrag(item.id) },
                                          onDelete: { onDelete(item.id) },
                                          onRemoveFromMenu: { onRemoveFromMenu(item.id) },
                                          selectionCount: selection.count,
                                          onToggleTemporary: { onToggleTemporary(item.id) },
                                          onToggleKeepCopy: onToggleKeepCopy.map { toggle in { toggle(item.id) } },
                                          onOpen: { commands.open(item.id) },
                                          onQuickLook: { commands.quickLook(item.id) },
                                          onShowInfo: { commands.showInfo(item.id) },
                                          onPressAreaMoved: { pressAreas.frames[item.id] = $0 })
                                .transition(tileTransition)
                        }
                    }
                    .animation(reflowAnimation, value: items.map(\.id))
                    // At least as tall as the visible area, so a click or drag anywhere
                    // around the tiles reaches the gestures below. Presses on a tile's
                    // picture or name never get here: its AppKit layer takes them first.
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClearSelection)
                    .simultaneousGesture(marqueeGesture(within: CGRect(origin: .zero, size: proxy.size)))
                }
                .coordinateSpace(.named(Self.viewportSpace))
                .overlay(alignment: .topLeading) {
                    marqueeRectangle
                }
                // The grid isn't rebuilt each time anymore, so bring the newest items back
                // into view on opening, while the shelf is still fading in.
                .onChange(of: isActive) { _, active in
                    if active, let newest = items.first {
                        scroller.scrollTo(newest.id, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Selection rectangle

    /// Press on free space and drag, as on the desktop: every tile whose picture or
    /// name the rectangle touches is selected, live. It stays inside the visible area.
    private func marqueeGesture(within visibleArea: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.viewportSpace))
            .updating($marquee) { drag, rectangle, _ in
                rectangle = Self.rectangle(from: drag.startLocation, to: drag.location, within: visibleArea)
            }
            .onChanged { drag in
                if marqueeStart != drag.startLocation {
                    marqueeStart = drag.startLocation
                    // The keys held as the rectangle starts, as with a click.
                    onMarqueeBegan(SelectionClick(NSEvent.modifierFlags))
                }
                let rectangle = Self.rectangle(from: drag.startLocation, to: drag.location, within: visibleArea)
                let touched = items.map(\.id).filter { id in
                    pressAreas.frames[id]?.intersects(rectangle) == true
                }
                onMarqueeChanged(Set(touched))
            }
    }

    /// The rectangle between two points, kept inside the visible area and never
    /// thinner than a point, so a straight line still touches what it crosses.
    private static func rectangle(from start: CGPoint, to end: CGPoint, within area: CGRect) -> CGRect {
        let rectangle = CGRect(x: min(start.x, end.x),
                               y: min(start.y, end.y),
                               width: max(abs(end.x - start.x), 1),
                               height: max(abs(end.y - start.y), 1))
        return rectangle.intersection(area)
    }

    /// Finder's look on a dark background: a faint light fill with a brighter edge.
    @ViewBuilder
    private var marqueeRectangle: some View {
        if let marquee, !marquee.isNull {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Where each tile's picture and text are in the grid's visible area.
///
/// A class rather than SwiftUI state on purpose: the frames change on every scroll,
/// and nothing is drawn from them, so changing them shouldn't redraw the grid.
private final class PressAreas {
    var frames: [ShelfItem.ID: CGRect] = [:]
}
