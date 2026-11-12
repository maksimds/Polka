import Foundation
import SwiftUI
import Testing
@testable import Polka

/// Moving tiles around the shelf: the new order, the spot under the pointer, and the
/// preview while a drag runs.
@MainActor
struct TileMoveTests {
    private struct Tile: Identifiable, Equatable {
        let id: String
    }

    private let tiles = ["a", "b", "c", "d", "e"].map(Tile.init)

    private func ids(_ tiles: [Tile]) -> String {
        tiles.map(\.id).joined()
    }

    // MARK: - The new order

    @Test func aTileMovedForwardLandsInThatSpot() {
        #expect(ids(tiles.moving(["a"], to: 2)) == "bcade")
    }

    @Test func aTileMovedBackPushesTheOthersAlong() {
        #expect(ids(tiles.moving(["d"], to: 0)) == "dabce")
    }

    @Test func severalTilesLandSideBySideInTheirOldOrder() {
        #expect(ids(tiles.moving(["d", "b"], to: 0)) == "bdace")
        #expect(ids(tiles.moving(["a", "e"], to: 1)) == "baecd")
    }

    @Test func aSpotPastEitherEndIsTheEnd() {
        #expect(ids(tiles.moving(["a"], to: 99)) == "bcdea")
        #expect(ids(tiles.moving(["e"], to: -3)) == "eabcd")
    }

    @Test func tilesThatAreNotThereChangeNothing() {
        #expect(ids(tiles.moving(["x"], to: 0)) == "abcde")
    }

    @Test func theStoreSavesTheNewOrder() {
        let persistence = InMemoryShelfPersistence()
        let store = ShelfStore(persistence: persistence)
        store.add(["a", "b", "c"].map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) })

        store.move([store.items[0].id], to: 2)

        #expect(store.items.map(\.title) == ["b", "c", "a"])
        #expect(store.items.map(\.sortOrder) == [0, 1, 2])
        #expect(ShelfStore(persistence: persistence).items.map(\.title) == ["b", "c", "a"])
    }

    // MARK: - The spot under the pointer

    /// Column widths are fractions of a point, so allow for rounding.
    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < 0.001 }
    }

    /// The panel's grid: 488 pt wide, so each column is 91.2 pt with 8 pt between.
    private let layout = ShelfGridLayout(width: 488)

    @Test func spotsFillEachRowLeftToRight() {
        #expect(layout.slot(at: CGPoint(x: 45, y: 50)) == 0)
        #expect(layout.slot(at: CGPoint(x: 3 * 99.2 + 10, y: 50)) == 3)
        #expect(layout.slot(at: CGPoint(x: 10, y: 108 + 5)) == 5)
        #expect(isClose(layout.frame(ofSlot: 7), CGRect(x: 2 * 99.2, y: 108, width: 91.2, height: 100)))
    }

    @Test func aGapBelongsToTheNearerSpot() {
        #expect(layout.slot(at: CGPoint(x: 91.2 + 3, y: 50)) == 0)
        #expect(layout.slot(at: CGPoint(x: 91.2 + 5, y: 50)) == 1)
    }

    @Test func pastTheSidesCountsAsTheNearestColumn() {
        #expect(layout.slot(at: CGPoint(x: -20, y: 50)) == 0)
        #expect(layout.slot(at: CGPoint(x: 600, y: 50)) == 4)
        #expect(layout.slot(at: CGPoint(x: 45, y: -30)) == 0)
    }

    /// The grid as it sits in the panel: two rows visible, `rows` rows in all, scrolled
    /// down by `scrolledRows`.
    private func geometry(rows: Int, scrolledRows: Int = 0) -> ShelfGridGeometry {
        let geometry = ShelfGridGeometry()
        geometry.viewport = CGRect(x: 16, y: 40, width: 488, height: 216)
        geometry.content = CGRect(x: 16, y: 40 - CGFloat(scrolledRows) * 108,
                                  width: 488, height: CGFloat(rows) * 108 - 8)
        geometry.pictureInSlot = CGRect(x: 19.6, y: 6, width: 52, height: 52)
        return geometry
    }

    @Test func thePointerOnTheHeaderPicksTheTopRowYouCanSee() {
        let header = CGPoint(x: 16 + 2 * 99.2 + 40, y: 20)

        #expect(geometry(rows: 4).slot(at: header) == 2)
        #expect(geometry(rows: 4, scrolledRows: 1).slot(at: header) == 7)
    }

    @Test func aDroppedPictureLandsOnItsSpotsPicture() {
        let frame = geometry(rows: 2).pictureFrame(ofSlot: 6)

        #expect(isClose(frame, CGRect(x: 16 + 99.2 + 19.6, y: 40 + 108 + 6, width: 52, height: 52)))
    }

    @Test func holdingNearAnEdgeScrollsOnlyIfThereIsMoreThatWay() {
        let top = CGPoint(x: 100, y: 45)
        let middle = CGPoint(x: 100, y: 140)
        let bottom = CGPoint(x: 100, y: 250)

        let atTop = geometry(rows: 4)
        #expect(atTop.scrollEdge(at: top) == nil)
        #expect(atTop.scrollEdge(at: middle) == nil)
        #expect(atTop.scrollEdge(at: bottom) == .bottom)

        let atBottom = geometry(rows: 4, scrolledRows: 2)
        #expect(atBottom.scrollEdge(at: top) == .top)
        #expect(atBottom.scrollEdge(at: bottom) == nil)

        #expect(geometry(rows: 2).scrollEdge(at: bottom) == nil)
    }

    // MARK: - While dragging

    /// A shelf of a, b, c, d and e, laid out in the panel, where tiles make room at once.
    private func makeModel(settleDelay: Duration = .zero) -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        store.add(["a", "b", "c", "d", "e"].map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) })
        let model = NotchViewModel(store: store, moveSettleDelay: settleDelay)
        let laidOut = geometry(rows: 1)
        model.gridGeometry.viewport = laidOut.viewport
        model.gridGeometry.content = laidOut.content
        model.gridGeometry.pictureInSlot = laidOut.pictureInSlot
        model.state = .expanded
        return (model, store)
    }

    /// The middle of spot `index`'s picture, in the panel.
    private func point(onSlot index: Int, of model: NotchViewModel) -> CGPoint {
        let frame = model.gridGeometry.pictureFrame(ofSlot: index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func titles(_ items: [ShelfItem]) -> String {
        items.map(\.title).joined()
    }

    @Test func aDraggedTileLeavesAGapWhereItWas() {
        let (model, store) = makeModel()

        model.beginTileMove(model.dragContents(from: store.items[0].id))

        #expect(model.hiddenItemIDs == [store.items[0].id])
        #expect(titles(model.displayedItems) == "abcde")
    }

    @Test func theOtherTilesMakeRoomWithoutSavingAnything() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        model.tileMoved(to: point(onSlot: 3, of: model))

        #expect(titles(model.displayedItems) == "bcdae")
        #expect(titles(store.items) == "abcde")
    }

    @Test func tilesWaitForThePointerToRestBeforeMakingRoom() {
        let (model, store) = makeModel(settleDelay: .seconds(10))
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        model.tileMoved(to: point(onSlot: 3, of: model))

        #expect(titles(model.displayedItems) == "abcde")
    }

    @Test func leavingThePanelPutsTheTilesBack() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))
        model.tileMoved(to: point(onSlot: 3, of: model))

        model.tileMoveLeft()

        #expect(titles(model.displayedItems) == "abcde")
        #expect(model.hiddenItemIDs == [store.items[0].id])
    }

    @Test func aDropSavesTheNewOrderAndTheTileLandsInItsSpot() throws {
        let (model, store) = makeModel()
        let moved = store.items[0].id
        model.beginTileMove(model.dragContents(from: moved))
        model.tileMoved(to: point(onSlot: 3, of: model))

        let drop = try #require(model.tileDrop(at: point(onSlot: 3, of: model)))
        #expect(drop.target == 3)
        #expect(drop.landingFrames == [model.gridGeometry.pictureFrame(ofSlot: 3)])

        model.finishTileMove(at: drop.target, gliding: true)

        #expect(titles(store.items) == "bcdae")
        #expect(model.tileMove == nil)
        // Still hidden while its picture glides into place.
        #expect(model.hiddenItemIDs == [moved])
    }

    @Test func withoutGlidingTheTileShowsRightAway() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        model.finishTileMove(at: 3, gliding: false)

        #expect(model.hiddenItemIDs.isEmpty)
    }

    /// A quick drop, before the tiles have made room, still goes where the pointer is.
    @Test func aDropGoesUnderThePointerEvenBeforeTheTilesMadeRoom() throws {
        let (model, store) = makeModel(settleDelay: .seconds(10))
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        let drop = try #require(model.tileDrop(at: point(onSlot: 2, of: model)))

        #expect(drop.target == 2)
    }

    @Test func aDragThatEndsElsewhereChangesNothing() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))
        model.tileMoved(to: point(onSlot: 3, of: model))

        model.endTileMove()

        #expect(titles(store.items) == "abcde")
        #expect(titles(model.displayedItems) == "abcde")
        #expect(model.hiddenItemIDs.isEmpty)
    }

    @Test func aSelectionMovesTogetherAndEachPictureFindsItsOwnSpot() throws {
        let (model, store) = makeModel()
        let ids = store.items.map(\.id)
        model.click(ids[0], .only)
        model.click(ids[2], .toggle)
        model.beginTileMove(model.dragContents(from: ids[2]))

        model.tileMoved(to: point(onSlot: 2, of: model))
        #expect(titles(model.displayedItems) == "bdace")

        // The drag holds c first, so c's picture goes first: c lands in spot 3, a in 2.
        let drop = try #require(model.tileDrop(at: point(onSlot: 2, of: model)))
        #expect(drop.landingFrames == [model.gridGeometry.pictureFrame(ofSlot: 3),
                                       model.gridGeometry.pictureFrame(ofSlot: 2)])
    }

    @Test func pastTheLastTileIsTheEnd() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        // The empty spot after e, in a second row.
        model.tileMoved(to: CGPoint(x: 100, y: 40 + 108 + 50))

        #expect(titles(model.displayedItems) == "bcdea")
    }

    @Test func aDragOutShrinksThePanelAndPutsTheTilesBack() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: store.items[0].id))
        model.tileMoved(to: point(onSlot: 3, of: model))

        model.dragOutMoved(isInsidePanel: false)

        #expect(model.state == .draggingOut)
        #expect(model.tileMove?.target == nil)
    }

    @Test func aMissingFileKeepsThePanelOpenWhenItLeaves() {
        let (model, store) = makeModel()
        let item = store.items[0]
        model.beginTileMove(ShelfDragContents(items: [item], staysOnShelf: true))

        model.dragOutMoved(isInsidePanel: false)

        #expect(model.state == .expanded)
    }

    @Test func holdingATileNearTheBottomScrollsUntilTheDragEnds() {
        let (model, store) = makeModel()
        model.gridGeometry.content.size.height = 4 * 108 - 8
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        model.tileMoved(to: CGPoint(x: 100, y: 250))
        #expect(model.scrollEdge == .bottom)

        model.endTileMove()
        #expect(model.scrollEdge == nil)
    }
}
