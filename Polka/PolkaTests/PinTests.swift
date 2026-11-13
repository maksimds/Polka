import Foundation
import Testing
@testable import Polka

/// "Pin" (FR-21): pinned items have the first row to themselves in every order, at
/// most five of them, and tiles moved by hand stay in their part of the shelf.
@MainActor
struct PinTests {
    private func files(_ names: String...) -> [ShelfItem.Draft] {
        names.map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    private func titles(_ items: [ShelfItem]) -> String {
        items.map(\.title).joined()
    }

    private func id(_ title: String, in store: ShelfStore) -> ShelfItem.ID {
        store.items.first { $0.title == title }!.id
    }

    // MARK: - The store

    @Test func unsortedAPinGoesToTheEndOfThePinnedRowAndAnUnpinFirstAfterIt() {
        let store = ShelfStore()
        store.add(files("a", "b", "c", "d"))

        store.pin(id: id("c", in: store))
        #expect(titles(store.items) == "cabd")
        store.pin(id: id("d", in: store))
        #expect(titles(store.items) == "cdab")
        store.unpin(id: id("c", in: store))
        #expect(titles(store.items) == "dcab")
        #expect(store.items.map(\.isPinned) == [true, false, false, false])
        #expect(store.items.map(\.sortOrder) == [0, 1, 2, 3])
    }

    @Test func pinnedItemsComeFirstInEveryOrderAndAreSortedAmongThemselves() {
        let store = ShelfStore()
        store.add(files("d", "b", "c", "a"))
        store.pin(id: id("c", in: store))
        store.pin(id: id("a", in: store))

        for sort in ShelfSort.allCases where sort != .none {
            store.setSort(sort)
            let pinnedFirst = store.items.prefix(2).allSatisfy { $0.isPinned }
            #expect(pinnedFirst, "\(sort)")
        }
        store.setSort(.name)
        #expect(titles(store.items) == "acbd")
    }

    @Test func aSixthPinIsRefusedAndChangesNothing() {
        let store = ShelfStore()
        store.add(files("a", "b", "c", "d", "e", "f"))
        for title in ["a", "b", "c", "d", "e"] {
            #expect(store.pin(id: id(title, in: store)))
        }
        let before = store.items

        #expect(!store.pin(id: id("f", in: store)))
        #expect(store.items == before)
        #expect(store.pinnedCount == ShelfStore.maxPinned)
    }

    @Test func newItemsArriveRightAfterThePinnedOnes() {
        let store = ShelfStore()
        store.add(files("a", "b"))
        store.pin(id: id("b", in: store))

        store.add(files("x"))

        #expect(titles(store.items) == "bxa")
    }

    @Test func pinsAreSavedAndLoadedAgain() {
        let persistence = InMemoryShelfPersistence()
        let store = ShelfStore(persistence: persistence)
        store.add(files("a", "b"))
        store.pin(id: id("b", in: store))

        let loaded = ShelfStore(persistence: persistence)

        #expect(titles(loaded.items) == "ba")
        #expect(loaded.items.map(\.isPinned) == [true, false])
    }

    @Test func aShelfSavedBeforePinningLoadsUnpinned() throws {
        let json = """
            {"id":"\(UUID().uuidString)","kind":"file","title":"a","source":{"file":{"path":"/tmp/a"}},
             "storageMode":"reference","createdAt":0,"sortOrder":0}
            """
        let item = try JSONDecoder().decode(ShelfItem.self, from: Data(json.utf8))

        #expect(!item.isPinned)
    }

    @Test func thePanelSaysWhyASixthPinDidNothing() {
        let store = ShelfStore()
        store.add(files("a", "b", "c", "d", "e", "f"))
        let model = NotchViewModel(store: store)
        for title in ["a", "b", "c", "d", "e"] {
            model.togglePinned(id("\(title)", in: store))
        }
        #expect(model.notice == nil)

        model.togglePinned(id("f", in: store))

        #expect(model.notice == "You can pin up to 5 items. Unpin one to pin this.")
        #expect(!store.items.first { $0.title == "f" }!.isPinned)
    }

    // MARK: - Groups and the grid

    @Test func thePinnedTilesAreAGroupOfTheirOwnWithNoTitle() {
        let store = ShelfStore()
        store.add(files("a", "b", "c"))
        #expect(store.sort.groups(of: store.items).isEmpty)

        store.pin(id: id("b", in: store))
        #expect(store.sort.groups(of: store.items)
                == [ShelfGroup(title: nil, count: 1), ShelfGroup(title: nil, count: 2)])

        store.setSort(.kind)
        #expect(store.sort.groups(of: store.items)
                == [ShelfGroup(title: nil, count: 1), ShelfGroup(title: "Files", count: 2)])
    }

    private let layout = ShelfGridLayout(width: 488)

    /// Two pinned tiles, then three others.
    private var pinnedAndRest: ShelfGridLayout.Placement {
        layout.placement(tileCount: 5, groups: [ShelfGroup(title: nil, count: 2), ShelfGroup(title: nil, count: 3)])
    }

    @Test func thePinnedRowIsARowOfItsOwnWithNoTitle() {
        let placement = pinnedAndRest
        let secondRow = ShelfGridLayout.rowHeight + ShelfGridLayout.groupSpacing

        #expect(placement.headers.isEmpty)
        #expect(placement.tiles.map(\.minY) == [0, 0, secondRow, secondRow, secondRow])
        #expect(placement.tiles[2].minX == 0)
        #expect(placement.rows.map(\.start) == [.tile(0), .tile(2)])
        #expect(placement.rows.map(\.group) == [0, 1])
    }

    @Test func theSpotUnderThePointerKnowsItsGroup() {
        let placement = pinnedAndRest
        let secondRow = ShelfGridLayout.rowHeight + ShelfGridLayout.groupSpacing

        // The pinned row's empty fourth spot.
        #expect(layout.spot(at: CGPoint(x: 3 * 99.2 + 10, y: 50), in: placement)
                == ShelfGridLayout.Spot(group: 0, index: 3))
        // The second spot of the next row, which holds the fourth tile.
        #expect(layout.spot(at: CGPoint(x: 99.2 + 10, y: secondRow + 50), in: placement)
                == ShelfGridLayout.Spot(group: 1, index: 3))
        // Below the grid counts for rows past the last.
        #expect(layout.spot(at: CGPoint(x: 10, y: secondRow + 108 + 50), in: placement)
                == ShelfGridLayout.Spot(group: 1, index: 7))
    }

    @Test func onAPlainGridTheSpotIsTheSlot() {
        let placement = layout.placement(tileCount: 12, groups: [])
        for point in [CGPoint(x: 45, y: 50), CGPoint(x: 3 * 99.2 + 10, y: 50), CGPoint(x: 10, y: 113),
                      CGPoint(x: 600, y: 230), CGPoint(x: 45, y: -30), CGPoint(x: 45, y: 500)] {
            #expect(layout.spot(at: point, in: placement).index == layout.slot(at: point))
        }
    }

    // MARK: - Moving tiles by hand

    /// a and b pinned, then c, d and e, laid out in the panel, where tiles make room at once.
    private func makeModel() -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        store.add(files("a", "b", "c", "d", "e"))
        store.pin(id: id("a", in: store))
        store.pin(id: id("b", in: store))
        let model = NotchViewModel(store: store, moveSettleDelay: .zero)
        let grid = CGRect(x: 16, y: 40, width: 488, height: 2 * ShelfGridLayout.rowHeight + ShelfGridLayout.groupSpacing)
        model.gridGeometry.viewport = grid
        model.gridGeometry.content = grid
        model.gridGeometry.pictureInSlot = CGRect(x: 19.6, y: 6, width: 52, height: 52)
        model.state = .expanded
        return (model, store)
    }

    /// The middle of the picture in grid spot `column` of the pinned row (`row` 0) or
    /// the row after it (1).
    private func point(row: Int, column: Int, of model: NotchViewModel) -> CGPoint {
        let placement = model.gridGeometry.layout.placement(tileCount: 2 + 5,
                                                            groups: [ShelfGroup(title: nil, count: 2),
                                                                     ShelfGroup(title: nil, count: 5)])
        let frame = model.gridGeometry.pictureFrame(ofTile: row == 0 ? column : 2 + column, in: placement)!
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test func aPinnedTileMovesOnlyAmongThePinned() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: id("b", in: store)))

        model.tileMoved(to: point(row: 0, column: 0, of: model))
        #expect(titles(model.displayedItems) == "bacde")

        // Over the other tiles, it waits at the end of the pinned row.
        model.tileMoved(to: point(row: 1, column: 1, of: model))
        #expect(titles(model.displayedItems) == "abcde")
    }

    @Test func anOtherTileHeldOverThePinnedRowGoesFirstAfterIt() {
        let (model, store) = makeModel()
        model.beginTileMove(model.dragContents(from: id("e", in: store)))

        model.tileMoved(to: point(row: 0, column: 1, of: model))
        #expect(titles(model.displayedItems) == "abecd")

        model.tileMoved(to: point(row: 1, column: 1, of: model))
        #expect(titles(model.displayedItems) == "abced")
    }

    @Test func aDroppedTileLandsBelowThePinnedRow() throws {
        let (model, store) = makeModel()
        let moved = id("e", in: store)
        model.beginTileMove(model.dragContents(from: moved))

        let drop = try #require(model.tileDrop(at: point(row: 1, column: 0, of: model)))
        #expect(drop.target == 2)
        #expect(drop.landingFrames.first?.minY
                == 40 + ShelfGridLayout.rowHeight + ShelfGridLayout.groupSpacing + 6)

        model.finishTileMove(at: drop.target, gliding: false)
        #expect(titles(store.items) == "abecd")
        #expect(!store.items[2].isPinned)
    }

    /// Pinned and unpinned tiles can't land side by side in either part of the shelf,
    /// so the others don't make room and the pictures glide back.
    @Test func aSelectionOfPinnedAndOtherTilesGoesBackWhereItWas() throws {
        let (model, store) = makeModel()
        model.click(id("a", in: store), .only)
        model.click(id("c", in: store), .toggle)
        model.beginTileMove(model.dragContents(from: id("a", in: store)))

        model.tileMoved(to: point(row: 1, column: 2, of: model))
        #expect(model.tileMove?.target == nil)

        let drop = try #require(model.tileDrop(at: point(row: 1, column: 2, of: model)))
        #expect(drop.target == nil)
        model.finishTileMove(at: drop.target, gliding: false)
        #expect(titles(store.items) == "abcde")
    }
}
