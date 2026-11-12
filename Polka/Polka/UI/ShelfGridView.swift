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

/// Right-click > Rename: the tile's name turns into a field, and the edit ends by
/// keeping what's typed or, with Esc, the old name.
struct ShelfRenameActions {
    let begin: @MainActor (ShelfItem.ID) -> Void
    let finish: @MainActor (ShelfItem.ID, String) -> Void
    let cancel: @MainActor (ShelfItem.ID) -> Void
}

/// The shelf's items as a scrolling grid, in the shelf's order. New items arrive at
/// the top left. While tiles are being moved, `items` is the order they'd have if
/// dropped now, so the others slide aside to make room. Sorted by Kind or File Type,
/// the tiles show in `groups`, each starting a new row under its title.
struct ShelfGridView: View {
    let items: [ShelfItem]
    /// The titled groups `items` fall into, in order. Empty for a plain grid.
    let groups: [ShelfGroup]
    /// False while the panel is closed or a drag out is running; the grid stays built.
    let isActive: Bool
    let missingItemIDs: Set<ShelfItem.ID>
    let copyingItemIDs: Set<ShelfItem.ID>
    let selection: Set<ShelfItem.ID>
    /// Tiles shown as empty gaps: being moved, or just dropped and still landing.
    let hiddenItemIDs: Set<ShelfItem.ID>
    /// True while tiles are being moved around the shelf.
    let isMovingTiles: Bool
    /// The edge to scroll toward, a row at a time, while a tile is held near it.
    let scrollEdge: VerticalEdge?
    /// A just-dropped item to bring into view on opening, instead of the first items.
    let revealItemID: ShelfItem.ID?
    /// Where the grid is, kept up to date here for finding the spot under the pointer.
    let geometry: ShelfGridGeometry
    let images: ShelfItemImages
    let dragSource: ShelfDragSource
    let onClick: @MainActor (ShelfItem.ID, SelectionClick) -> Void
    let onClearSelection: @MainActor () -> Void
    let dragContents: @MainActor (ShelfItem.ID) -> ShelfDragContents
    let onDelete: @MainActor (ShelfItem.ID) -> Void
    let onRemoveFromMenu: @MainActor (ShelfItem.ID) -> Void
    let onToggleTemporary: @MainActor (ShelfItem.ID) -> Void
    let onToggleKeepCopy: (@MainActor (ShelfItem.ID) -> Void)?
    let commands: ShelfItemCommands
    /// The tile whose name is being edited, if any.
    let renamingItemID: ShelfItem.ID?
    let rename: ShelfRenameActions
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

    /// Five equal columns, matching `ShelfGridLayout`. The grid itself is laid out by
    /// `ShelfGridArrangement`; the panel's header uses these to line its name and
    /// buttons up with the tiles.
    static let columns = Array(repeating: GridItem(.flexible(), spacing: ShelfGridLayout.spacing),
                               count: ShelfGridLayout.columnCount)

    /// The grid's visible area, the same while it scrolls. Tiles report where they are
    /// in it, and the selection rectangle is drawn in it.
    static let viewportSpace = "ShelfGridViewport"

    /// Room above the first row. A tall picture's remove badge rises a little above
    /// its tile, and with nothing above the first row (no group title), the scroll
    /// view's top edge cut it off. Two rows still fit without scrolling.
    static let topInset: CGFloat = 6

    /// The grid's content, room above the first row included, for scrolling to the top.
    private static let topID = "ShelfGridTop"

    /// A tile grows in when added and shrinks away when removed, while the others
    /// slide into place. Reduce Motion gets a fade.
    private var tileTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
    }

    /// With Reduce Motion, tiles making room for a moved one jump to their places
    /// instead of sliding there.
    private var reflowAnimation: Animation? {
        if reduceMotion {
            return isMovingTiles ? nil : .easeInOut(duration: 0.2)
        }
        return .snappy(duration: 0.28)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    ShelfGridArrangement(groups: groups, tileIDs: items.map(\.id)) {
                        ForEach(groups, id: \.title) { group in
                            ShelfGroupHeader(title: group.title)
                                .transition(.opacity)
                                .layoutValue(key: ShelfGridEntryKey.self, value: .header(group.title))
                        }
                        ForEach(items) { item in
                            ShelfItemTile(item: item,
                                          isAvailable: !missingItemIDs.contains(item.id),
                                          isCopying: copyingItemIDs.contains(item.id),
                                          isSelected: selection.contains(item.id),
                                          isLifted: hiddenItemIDs.contains(item.id),
                                          isActive: isActive,
                                          images: images,
                                          dragSource: dragSource,
                                          onClick: { onClick(item.id, $0) },
                                          dragContents: { dragContents(item.id) },
                                          onDelete: { onDelete(item.id) },
                                          onRemoveFromMenu: { onRemoveFromMenu(item.id) },
                                          selectionCount: selection.count,
                                          onToggleTemporary: { onToggleTemporary(item.id) },
                                          onToggleKeepCopy: onToggleKeepCopy.map { toggle in { toggle(item.id) } },
                                          onOpen: { commands.open(item.id) },
                                          onQuickLook: { commands.quickLook(item.id) },
                                          onShowInfo: { commands.showInfo(item.id) },
                                          isRenaming: renamingItemID == item.id,
                                          onRename: { rename.begin(item.id) },
                                          onRenameFinished: { rename.finish(item.id, $0) },
                                          onRenameCancelled: { rename.cancel(item.id) },
                                          onPressAreaMoved: { pressAreas.frames[item.id] = $0 },
                                          onPictureInSlotMeasured: { geometry.pictureInSlot = $0 })
                                .transition(tileTransition)
                                .layoutValue(key: ShelfGridEntryKey.self, value: .tile(item.id))
                        }
                    }
                    // The whole grid, rows scrolled out of sight included, before it's
                    // stretched to fill the visible area below.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        geometry.content = frame
                    }
                    .animation(reflowAnimation, value: items.map(\.id))
                    // A change of groups alone, such as Kind to File Type, slides too.
                    .animation(reflowAnimation, value: groups)
                    // Outside the measured grid, so the spot math is unchanged.
                    .padding(.top, Self.topInset)
                    // At least as tall as the visible area, so a click or drag anywhere
                    // around the tiles reaches the gestures below. Presses on a tile's
                    // picture or name never get here: its AppKit layer takes them first.
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClearSelection)
                    .simultaneousGesture(marqueeGesture(within: CGRect(origin: .zero, size: proxy.size)))
                    // To scroll all the way up, room above the first row included.
                    .id(Self.topID)
                }
                .coordinateSpace(.named(Self.viewportSpace))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    geometry.viewport = frame
                }
                .overlay(alignment: .topLeading) {
                    marqueeRectangle
                }
                // Held near an edge, the grid waits a moment, then steps one row at a
                // time until the pointer moves away or there's nothing more to show.
                .task(id: scrollEdge) {
                    guard let edge = scrollEdge else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    while !Task.isCancelled {
                        scrollOneRow(toward: edge, with: scroller)
                        try? await Task.sleep(for: .milliseconds(450))
                    }
                }
                // The grid isn't rebuilt each time anymore, so pick where it shows on
                // opening, while the shelf is still fading in.
                .onChange(of: isActive) { _, active in
                    if active {
                        scrollOnOpening(with: scroller)
                    }
                }
            }
        }
    }

    // MARK: - Scrolling on opening

    /// The top, or, after a drop, as far down as it takes to show the new item. On a
    /// sorted shelf it may have landed below the first rows. A row (or a group's
    /// title) stays lined up with the top, as when scrolling a row at a time.
    private func scrollOnOpening(with scroller: ScrollViewProxy) {
        let placement = geometry.layout.placement(tileCount: items.count, groups: groups.map(\.count))
        guard let firstRow = placement.rows.first else { return }
        var row = firstRow
        if let revealItemID,
           let index = items.firstIndex(where: { $0.id == revealItemID }),
           placement.tiles.indices.contains(index) {
            // The highest row that still keeps the new item in view when it's at the top.
            let lowestTop = placement.tiles[index].maxY - geometry.viewport.height
            row = placement.rows.first { $0.minY >= lowestTop - 0.5 } ?? firstRow
        }
        // The first row goes back to the very top, keeping the room above it.
        if row == firstRow {
            scroller.scrollTo(Self.topID, anchor: .top)
            return
        }
        switch row.start {
        case .header(let group):
            scroller.scrollTo(groups[group].title, anchor: .top)
        case .tile(let index):
            scroller.scrollTo(items[index].id, anchor: .top)
        }
    }

    // MARK: - Scrolling while moving a tile

    /// Brings the next row past `edge` into view, lining a row up with the top.
    private func scrollOneRow(toward edge: VerticalEdge, with scroller: ScrollViewProxy) {
        let pitch = geometry.layout.rowPitch
        guard !items.isEmpty, pitch > 0 else { return }
        let topRow = Int(((geometry.viewport.minY - geometry.content.minY) / pitch).rounded())
        let lastRow = (items.count - 1) / ShelfGridLayout.columnCount
        let row = min(max(edge == .top ? topRow - 1 : topRow + 1, 0), lastRow)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            // The first row goes back to the very top, keeping the room above it.
            if row == 0 {
                scroller.scrollTo(Self.topID, anchor: .top)
            } else {
                scroller.scrollTo(items[row * ShelfGridLayout.columnCount].id, anchor: .top)
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

/// A group's title, such as "Folders" or "PDF", followed by a hairline that runs to
/// the end of the row. Dim white like the panel's header. It takes no presses, so a
/// click there clears the selection and a drag starts a selection rectangle, as on
/// any other free space.
private struct ShelfGroupHeader: View {
    let title: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1 / displayScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where each tile's picture and text are in the grid's visible area.
///
/// A class rather than SwiftUI state on purpose: the frames change on every scroll,
/// and nothing is drawn from them, so changing them shouldn't redraw the grid.
private final class PressAreas {
    var frames: [ShelfItem.ID: CGRect] = [:]
}
