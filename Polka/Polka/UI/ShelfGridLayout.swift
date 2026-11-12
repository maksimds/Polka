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

    /// The spot under a point in the panel. A point outside the visible part counts
    /// as the nearest point inside it, so the pointer on the header or beside the
    /// grid picks one of the tiles you can see.
    func slot(at point: CGPoint) -> Int {
        let inside = CGPoint(x: min(max(point.x, viewport.minX), viewport.maxX - 1),
                             y: min(max(point.y, viewport.minY), viewport.maxY - 1))
        return layout.slot(at: CGPoint(x: inside.x - content.minX, y: inside.y - content.minY))
    }

    /// Where the picture of the tile in spot `index` is, in the panel.
    func pictureFrame(ofSlot index: Int) -> CGRect {
        let slot = layout.frame(ofSlot: index)
        return pictureInSlot.offsetBy(dx: content.minX + slot.minX, dy: content.minY + slot.minY)
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
