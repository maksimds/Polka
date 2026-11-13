import SwiftUI

/// The grid's fixed measurements: five equal columns, rows as tall as a tile, and
/// 8 pt between them.
///
/// Moving a tile works out the spot under the pointer from these numbers rather
/// than from where the tiles are drawn. The tiles slide while you drag, and
/// measuring targets that are moving would make them jump back and forth.
struct ShelfGridLayout: Equatable {
    static let columnCount = 5
    static let spacing: CGFloat = 8
    static let rowHeight = ShelfItemTile.height

    /// The grid's width. The columns share what's left after the gaps.
    var width: CGFloat

    var columnWidth: CGFloat {
        max((width - Self.spacing * CGFloat(Self.columnCount - 1)) / CGFloat(Self.columnCount), 0)
    }

    /// From the top of one row to the top of the next.
    var rowPitch: CGFloat {
        Self.rowHeight + Self.spacing
    }

    private var columnPitch: CGFloat {
        columnWidth + Self.spacing
    }

    /// Spot `index`, from the grid's top left. Spots fill each row left to right.
    func frame(ofSlot index: Int) -> CGRect {
        let row = index / Self.columnCount
        let column = index % Self.columnCount
        return CGRect(x: CGFloat(column) * columnPitch,
                      y: CGFloat(row) * rowPitch,
                      width: columnWidth,
                      height: Self.rowHeight)
    }

    /// The spot under `point`, from the grid's top left. Each gap is split between
    /// the spots on either side of it. A point past the left or right edge counts
    /// for the nearest column, and one above the grid for the first row.
    func slot(at point: CGPoint) -> Int {
        guard columnPitch > 0 else { return 0 }
        let column = Int(((point.x + Self.spacing / 2) / columnPitch).rounded(.down))
        let row = Int(((point.y + Self.spacing / 2) / rowPitch).rounded(.down))
        return max(row, 0) * Self.columnCount + min(max(column, 0), Self.columnCount - 1)
    }

    // MARK: - Groups

    /// A group's title row, in the orders that group tiles (Kind, File Type).
    static let headerHeight: CGFloat = 20
    /// From a title to its group's first row. Small, since a tile already has room
    /// above its picture.
    static let headerSpacing: CGFloat = 2
    /// From a group's last row to the next group's title, or to its first row if it
    /// has no title, as after the pinned row.
    static let groupSpacing: CGFloat = 10

    /// What a row of the grid starts with: a group's title, or a tile (by index).
    enum RowStart: Equatable {
        case header(Int)
        case tile(Int)
    }

    struct Row: Equatable {
        let start: RowStart
        let minY: CGFloat
        /// The group the row belongs to. Zero on a plain grid.
        var group = 0
    }

    /// Where everything goes, from the grid's top left.
    struct Placement: Equatable {
        var headers: [CGRect] = []
        var tiles: [CGRect] = []
        /// Every row from the top, for scrolling one to the top of the visible area.
        var rows: [Row] = []
        var height: CGFloat = 0
    }

    /// From a column's edge to its tiles' pictures. A group's title starts where the
    /// first column's pictures start, and its line ends where the last column's
    /// pictures end, like the panel's header strip and the link field.
    var pictureInset: CGFloat {
        max((columnWidth - ShelfItemTile.imageSide) / 2, 0)
    }

    /// Lays out `tileCount` tiles in `groups`, in order: each group starts a new row,
    /// under its title if it has one (`headers` holds only those). Empty, or groups
    /// that don't add up to `tileCount`, means one plain grid, in the same spots as
    /// `frame(ofSlot:)`.
    func placement(tileCount: Int, groups: [ShelfGroup]) -> Placement {
        let grouped = !groups.isEmpty && groups.map(\.count).reduce(0, +) == tileCount
        var placement = Placement()
        var y: CGFloat = 0
        var firstTile = 0
        for (group, info) in (grouped ? groups : [ShelfGroup(title: nil, count: tileCount)]).enumerated() {
            if group > 0 { y += Self.groupSpacing }
            if info.title != nil {
                placement.rows.append(Row(start: .header(group), minY: y, group: group))
                placement.headers.append(CGRect(x: pictureInset, y: y,
                                                width: max(width - 2 * pictureInset, 0),
                                                height: Self.headerHeight))
                y += Self.headerHeight + Self.headerSpacing
            }
            let count = info.count
            let rowCount = (count + Self.columnCount - 1) / Self.columnCount
            for row in 0..<rowCount {
                if row > 0 { y += Self.spacing }
                let rowStart = firstTile + row * Self.columnCount
                placement.rows.append(Row(start: .tile(rowStart), minY: y, group: group))
                for column in 0..<min(Self.columnCount, firstTile + count - rowStart) {
                    placement.tiles.append(CGRect(x: CGFloat(column) * columnPitch, y: y,
                                                  width: columnWidth, height: Self.rowHeight))
                }
                y += Self.rowHeight
            }
            firstTile += count
        }
        placement.height = y
        return placement
    }

    /// A spot in a grid laid out with groups: the group it's in, and the index of the
    /// tile that would be there, counted from the first tile of the whole grid. Past
    /// the end of a group's last row, the index runs on as if the row were full.
    struct Spot: Equatable {
        let group: Int
        let index: Int
    }

    /// The spot under `point`, from the grid's top left, in `placement`. Like
    /// `slot(at:)`, which it matches on a plain grid: the gap between two rows,
    /// a title included, is split between them, a point above the grid counts for
    /// the first row, and one below it for rows past the last.
    func spot(at point: CGPoint, in placement: Placement) -> Spot {
        let rows = placement.rows.compactMap { row -> (start: Int, minY: CGFloat, group: Int)? in
            guard case .tile(let start) = row.start else { return nil }
            return (start, row.minY, row.group)
        }
        guard columnPitch > 0, var row = rows.first else { return Spot(group: 0, index: 0) }
        for next in rows.dropFirst() {
            guard point.y >= (row.minY + Self.rowHeight + next.minY) / 2 else { break }
            row = next
        }
        // Rows that aren't there yet, below the last one.
        let rowsPast = row.start == rows.last?.start
            ? max(Int(((point.y - row.minY + Self.spacing / 2) / rowPitch).rounded(.down)), 0)
            : 0
        let column = Int(((point.x + Self.spacing / 2) / columnPitch).rounded(.down))
        let index = row.start + rowsPast * Self.columnCount + min(max(column, 0), Self.columnCount - 1)
        return Spot(group: row.group, index: index)
    }
}

// MARK: - The grid's layout

/// What one view in the grid is: a group's title or a tile. The layout reads it to
/// know where each view goes.
enum ShelfGridEntry: Hashable {
    case header(String)
    case tile(ShelfItem.ID)
}

struct ShelfGridEntryKey: LayoutValueKey {
    static let defaultValue: ShelfGridEntry? = nil
}

/// Places the shelf's titles and tiles where `ShelfGridLayout.placement` says, so
/// what's drawn always matches the numbers that moving tiles and landing pictures
/// are worked out from. Each view says what it is with `ShelfGridEntryKey`.
///
/// One layout for every order, with and without groups, so a tile stays the same
/// view when the sort changes and slides to its new spot instead of being rebuilt.
/// Unlike `LazyVGrid`, it makes every tile up front; the shelf is built once and
/// stays built anyway.
struct ShelfGridArrangement: Layout {
    let groups: [ShelfGroup]
    let tileIDs: [ShelfItem.ID]

    /// Where each view went last time. A view on its way out (a removed tile or a
    /// title that's no longer needed) has no new spot, so it fades out where it was.
    struct Cache {
        var lastFrames: [ShelfGridEntry: CGRect] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    /// Kept as it is when views come and go, which is exactly when the old spots matter.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: placement(width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let placement = placement(width: bounds.width)
        var frames: [ShelfGridEntry: CGRect] = [:]
        // The headers are those of the titled groups, in order.
        for (index, title) in groups.compactMap(\.title).enumerated() where placement.headers.indices.contains(index) {
            frames[.header(title)] = placement.headers[index]
        }
        for (index, id) in tileIDs.enumerated() where placement.tiles.indices.contains(index) {
            frames[.tile(id)] = placement.tiles[index]
        }
        var placed: [ShelfGridEntry: CGRect] = [:]
        for subview in subviews {
            guard let entry = subview[ShelfGridEntryKey.self],
                  let frame = frames[entry] ?? cache.lastFrames[entry] else { continue }
            placed[entry] = frame
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
        cache.lastFrames = placed
    }

    private func placement(width: CGFloat) -> ShelfGridLayout.Placement {
        ShelfGridLayout(width: width).placement(tileCount: tileIDs.count, groups: groups)
    }
}

/// Where the grid is in the panel, kept up to date by the grid as it lays out and
/// scrolls, and read while a tile is being moved. Points are in the panel's SwiftUI
/// coordinates, measured from its top left.
///
/// A class rather than published state, like the tiles' press areas: it changes on
/// every scroll, and nothing is drawn from it.
final class ShelfGridGeometry {
    /// The part of the grid you can see.
    var viewport: CGRect = .zero
    /// The whole grid, scrolled-away rows included. Its top moves up as it scrolls down.
    var content: CGRect = .zero
    /// Where a tile's picture sits within its spot. The same for every tile.
    var pictureInSlot = CGRect(x: 0, y: 0, width: ShelfItemTile.imageSide, height: ShelfItemTile.imageSide)

    /// How close to the top or bottom of the visible part the pointer has to be to
    /// scroll the grid. Above or below it counts too.
    static let scrollBand: CGFloat = 16

    var layout: ShelfGridLayout {
        ShelfGridLayout(width: content.width)
    }

    /// The spot under a point in the panel, in the grid laid out as `placement` says.
    /// A point outside the visible part counts as the nearest point inside it, so the
    /// pointer on the header or beside the grid picks one of the tiles you can see.
    func spot(at point: CGPoint, in placement: ShelfGridLayout.Placement) -> ShelfGridLayout.Spot {
        let inside = CGPoint(x: min(max(point.x, viewport.minX), viewport.maxX - 1),
                             y: min(max(point.y, viewport.minY), viewport.maxY - 1))
        return layout.spot(at: CGPoint(x: inside.x - content.minX, y: inside.y - content.minY), in: placement)
    }

    /// Where the picture of the tile in spot `index` is, in the panel, on a grid
    /// without groups.
    func pictureFrame(ofSlot index: Int) -> CGRect {
        picture(in: layout.frame(ofSlot: index))
    }

    /// Where the picture of tile `index` is, in the panel, laid out as `placement`
    /// says, groups and all. Nil if there's no such tile.
    func pictureFrame(ofTile index: Int, in placement: ShelfGridLayout.Placement) -> CGRect? {
        guard placement.tiles.indices.contains(index) else { return nil }
        return picture(in: placement.tiles[index])
    }

    private func picture(in slot: CGRect) -> CGRect {
        pictureInSlot.offsetBy(dx: content.minX + slot.minX, dy: content.minY + slot.minY)
    }

    /// Which way the grid should scroll with the pointer at `point`: toward the edge
    /// it's held near, if there are rows hidden past that edge. Nil otherwise.
    func scrollEdge(at point: CGPoint) -> VerticalEdge? {
        if point.y < viewport.minY + Self.scrollBand, content.minY < viewport.minY - 0.5 {
            return .top
        }
        if point.y > viewport.maxY - Self.scrollBand, content.maxY > viewport.maxY + 0.5 {
            return .bottom
        }
        return nil
    }
}
