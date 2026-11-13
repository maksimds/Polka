import Foundation
import Testing
@testable import Polka

/// The header's "Sort By" menu: each order, the shelf keeping itself sorted, tiles
/// that can't be moved by hand while it is, and the choice being remembered.
@MainActor
struct ShelfSortTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// An item as the store would have made it, without needing a real file on disk.
    private func item(_ title: String, _ kind: ShelfItem.Kind = .file, addedMinutesIn minutes: Double = 0) -> ShelfItem {
        let source: ShelfItem.Source = kind == .link
            ? .link(URL(string: "https://example.com/\(title)")!)
            : .file(path: "/tmp/\(title)", bookmark: nil)
        return ShelfItem(id: UUID(), kind: kind, title: title, source: source, storageMode: .reference,
                         createdAt: start.addingTimeInterval(minutes * 60), expiresAt: nil, sortOrder: 0)
    }

    private func titles(_ items: [ShelfItem]) -> [String] {
        items.map(\.title)
    }

    private func files(_ names: String...) -> [ShelfItem.Draft] {
        names.map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    // MARK: - The orders

    @Test func noneLeavesTheOrderAlone() {
        let items = [item("b"), item("a"), item("c")]
        #expect(titles(ShelfSort.none.arranged(items)) == ["b", "a", "c"])
    }

    @Test func nameIgnoresCaseAndReadsNumbersAsNumbers() {
        let items = [item("file10.txt"), item("Banana"), item("file2.txt"), item("apple")]
        #expect(titles(ShelfSort.name.arranged(items)) == ["apple", "Banana", "file2.txt", "file10.txt"])
    }

    @Test func kindPutsFoldersThenFilesThenLinksEachFromAToZ() {
        let items = [item("GitHub", .link), item("notes.txt"), item("Projects", .folder),
                     item("Apple", .link), item("Archive", .folder), item("a.pdf")]
        #expect(titles(ShelfSort.kind.arranged(items))
                == ["Archive", "Projects", "a.pdf", "notes.txt", "Apple", "GitHub"])
    }

    @Test func fileTypePutsFoldersThenEachExtensionThenOtherThenLinks() {
        let items = [item("site", .link), item("b.pdf"), item("Makefile"), item("main.py"),
                     item("Docs", .folder), item("a.PDF"), item("letter.docx")]
        #expect(titles(ShelfSort.fileType.arranged(items))
                == ["Docs", "letter.docx", "a.PDF", "b.pdf", "main.py", "Makefile", "site"])
    }

    @Test func kindAndFileTypeShowTitledGroupsAndTheOthersDont() {
        let items = [item("Docs", .folder), item("a.pdf"), item("b.pdf"), item("c.py"), item("site", .link)]

        #expect(ShelfSort.kind.groups(of: ShelfSort.kind.arranged(items))
                == [ShelfGroup(title: "Folders", count: 1), ShelfGroup(title: "Files", count: 3),
                    ShelfGroup(title: "Links", count: 1)])
        #expect(ShelfSort.fileType.groups(of: ShelfSort.fileType.arranged(items))
                == [ShelfGroup(title: "Folders", count: 1), ShelfGroup(title: "PDF", count: 2),
                    ShelfGroup(title: "PY", count: 1), ShelfGroup(title: "Links", count: 1)])
        for sort in [ShelfSort.none, .name, .dateAdded] {
            #expect(!sort.showsGroups)
            #expect(sort.groups(of: items).isEmpty)
        }
    }

    @Test func dateAddedPutsTheNewestFirst() {
        let items = [item("old", addedMinutesIn: 0), item("newest", addedMinutesIn: 10), item("middle", addedMinutesIn: 5)]
        #expect(titles(ShelfSort.dateAdded.arranged(items)) == ["newest", "middle", "old"])
    }

    /// Items from one drop share a date, and two files can share a name.
    @Test func tiesKeepTheOrderTheyCameIn() {
        let sameDrop = [item("x"), item("y"), item("z")]
        #expect(titles(ShelfSort.dateAdded.arranged(sameDrop)) == ["x", "y", "z"])

        let twins = [item("same"), item("same")]
        #expect(ShelfSort.name.arranged(twins).map(\.id) == twins.map(\.id))
    }

    // MARK: - The store keeps itself sorted

    @Test func choosingASortSortsTheShelfAndSavesTheOrder() {
        let persistence = InMemoryShelfPersistence()
        let store = ShelfStore(persistence: persistence)
        store.add(files("b", "c", "a"))

        store.setSort(.name)

        #expect(titles(store.items) == ["a", "b", "c"])
        #expect(store.items.map(\.sortOrder) == [0, 1, 2])
        #expect(titles(ShelfStore(persistence: persistence).items) == ["a", "b", "c"])
    }

    @Test func aNewItemLandsInItsSortedSpot() {
        let store = ShelfStore(sort: .name)
        store.add(files("a", "c"))

        let result = store.add(files("b"))

        #expect(titles(store.items) == ["a", "b", "c"])
        // The result reports where it really went, not the front.
        #expect(result.added.map(\.title) == ["b"])
        #expect(result.added.map(\.sortOrder) == [1])
    }

    @Test func aRenamedItemMovesToItsNewSpot() throws {
        let store = ShelfStore(sort: .name)
        store.add([ShelfItem.Draft(linkURL: try #require(URL(string: "https://zeta.example"))),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/m.txt"))])
        let link = try #require(store.items.first { $0.kind == .link })
        #expect(titles(store.items).first == "m.txt")

        // The site's own name arrives after the link was added.
        store.applyLinkPreview(id: link.id, siteName: "Alpha", iconFileName: nil)

        #expect(store.items.first?.id == link.id)
    }

    @Test func tilesCantBeMovedByHandWhileSorted() {
        let store = ShelfStore(sort: .name)
        store.add(files("a", "b", "c"))

        store.move([store.items[0].id], to: 2)

        #expect(titles(store.items) == ["a", "b", "c"])
    }

    /// As in Finder: back on None, the tiles stay where the sort put them, and the
    /// shelf works by hand again from there.
    @Test func backOnNoneTheSortedOrderStaysAndNewItemsArriveFirstAgain() {
        let store = ShelfStore()
        store.add(files("b", "c", "a"))
        store.setSort(.name)

        store.setSort(.none)
        #expect(titles(store.items) == ["a", "b", "c"])

        store.add(files("z"))
        #expect(titles(store.items) == ["z", "a", "b", "c"])

        store.move([store.items[0].id], to: 3)
        #expect(titles(store.items) == ["a", "b", "c", "z"])
    }

    @Test func aShelfSavedInAnotherOrderIsSortedWhenLoaded() {
        let persistence = InMemoryShelfPersistence()
        let unsorted = ShelfStore(persistence: persistence)
        unsorted.add(files("b", "c", "a"))

        let sorted = ShelfStore(persistence: persistence, sort: .name)

        #expect(titles(sorted.items) == ["a", "b", "c"])
        #expect(sorted.items.map(\.sortOrder) == [0, 1, 2])
    }

    // MARK: - The grid with groups

    private let layout = ShelfGridLayout(width: 488)

    @Test func withoutGroupsTilesGoWhereTheyAlwaysHave() {
        let placement = layout.placement(tileCount: 7, groups: [])

        #expect(placement.headers.isEmpty)
        #expect(placement.tiles == (0..<7).map(layout.frame(ofSlot:)))
        #expect(placement.rows.map(\.start) == [.tile(0), .tile(5)])
        #expect(placement.height == layout.frame(ofSlot: 5).maxY)
    }

    @Test func eachGroupStartsANewRowUnderItsTitle() {
        // Two folders, then six files, which take two rows.
        let placement = layout.placement(tileCount: 8, groups: [ShelfGroup(title: "Folders", count: 2),
                                                               ShelfGroup(title: "Files", count: 6)])
        let rowHeight = ShelfGridLayout.rowHeight
        let firstTiles = ShelfGridLayout.headerHeight + ShelfGridLayout.headerSpacing
        let secondTitle = firstTiles + rowHeight + ShelfGridLayout.groupSpacing
        let secondTiles = secondTitle + ShelfGridLayout.headerHeight + ShelfGridLayout.headerSpacing

        #expect(placement.headers.map(\.minY) == [0, secondTitle])
        #expect(placement.tiles.map(\.minY) == [firstTiles, firstTiles]
                + Array(repeating: secondTiles, count: 5) + [secondTiles + rowHeight + ShelfGridLayout.spacing])
        // The third tile, the first file, starts its own row in the first column.
        #expect(placement.tiles[2].minX == 0)
        #expect(placement.rows.map(\.start) == [.header(0), .tile(0), .header(1), .tile(2), .tile(7)])
        #expect(placement.height == placement.tiles[7].maxY)
    }

    /// Like the header strip: the line runs from the first picture's left edge to the last one's right edge.
    @Test func aTitleLinesUpWithThePictures() {
        let title = layout.placement(tileCount: 1, groups: [ShelfGroup(title: "Files", count: 1)]).headers[0]
        let inset = (layout.columnWidth - ShelfItemTile.imageSide) / 2

        #expect(abs(title.minX - inset) < 0.001)
        #expect(abs(title.maxX - (layout.width - inset)) < 0.001)
    }

    @Test func groupsThatDontAddUpGiveAPlainGrid() {
        #expect(layout.placement(tileCount: 3, groups: [ShelfGroup(title: "Folders", count: 1),
                                                             ShelfGroup(title: "Files", count: 1)]).headers.isEmpty)
    }

    // MARK: - The panel

    /// A shelf of b, c and a, laid out in one row of the panel, where tiles make room at once.
    private func makeModel(saveSort: @escaping (ShelfSort) -> Void = { _ in }) -> (NotchViewModel, ShelfStore) {
        let store = ShelfStore()
        store.add(files("b", "c", "a"))
        let model = NotchViewModel(store: store, saveSort: saveSort, moveSettleDelay: .zero)
        let row = CGRect(x: 16, y: 40, width: 488, height: ShelfGridLayout.rowHeight)
        model.gridGeometry.viewport = row
        model.gridGeometry.content = row
        model.state = .expanded
        return (model, store)
    }

    private func point(onSlot index: Int, of model: NotchViewModel) -> CGPoint {
        let frame = model.gridGeometry.pictureFrame(ofSlot: index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test func choosingFromTheMenuSortsAndRemembersTheChoice() {
        var saved: [ShelfSort] = []
        let (model, store) = makeModel { saved.append($0) }

        model.chooseSort(.name)

        #expect(store.sort == .name)
        #expect(titles(store.items) == ["a", "b", "c"])
        #expect(saved == [.name])
    }

    @Test func onASortedShelfTheOtherTilesDontMakeRoom() {
        let (model, store) = makeModel()
        model.chooseSort(.name)
        model.beginTileMove(model.dragContents(from: store.items[0].id))

        model.tileMoved(to: point(onSlot: 2, of: model))

        #expect(model.tileMove?.target == nil)
        #expect(titles(model.displayedItems) == ["a", "b", "c"])
    }

    /// Like an icon dropped in a sorted Finder window: it glides back to its own spot.
    @Test func onASortedShelfADroppedTileGoesBackToItsSpot() throws {
        let (model, store) = makeModel()
        model.chooseSort(.name)
        let moved = store.items[0].id
        model.beginTileMove(model.dragContents(from: moved))

        let drop = try #require(model.tileDrop(at: point(onSlot: 2, of: model)))
        #expect(drop.target == nil)
        #expect(drop.landingFrames == [model.gridGeometry.pictureFrame(ofSlot: 0)])

        model.finishTileMove(at: drop.target, gliding: true)

        #expect(titles(store.items) == ["a", "b", "c"])
        #expect(model.hiddenItemIDs == [moved])
    }

    /// Under a group's title, the spot a picture glides back to is below the title.
    @Test func inAGroupedOrderADroppedTileGoesBackBelowItsTitle() throws {
        let (model, store) = makeModel()
        model.chooseSort(.kind)
        let moved = store.items[0].id
        model.beginTileMove(model.dragContents(from: moved))

        let drop = try #require(model.tileDrop(at: point(onSlot: 2, of: model)))

        let placement = model.gridGeometry.layout.placement(tileCount: 3, groups: [ShelfGroup(title: "Files", count: 3)])
        #expect(drop.landingFrames == [model.gridGeometry.pictureFrame(ofTile: 0, in: placement)])
        #expect(drop.landingFrames.first?.minY
                == model.gridGeometry.pictureFrame(ofSlot: 0).minY
                + ShelfGridLayout.headerHeight + ShelfGridLayout.headerSpacing)
    }

    @Test func aDropRemembersTheNewItemToShowUntilThePanelCloses() throws {
        let (model, store) = makeModel()
        model.chooseSort(.name)

        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/ab"))])

        let added = try #require(store.items.first { $0.title == "ab" })
        #expect(store.items.firstIndex { $0.id == added.id } == 1)
        #expect(model.itemToReveal == added.id)

        model.state = .collapsed
        #expect(model.itemToReveal == nil)
    }

    // MARK: - The saved choice

    @Test func theChoiceIsKeptAndAnUnknownOneMeansNone() throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShelfSettings(defaults: defaults)

        #expect(settings.shelfSort == .none)
        settings.shelfSort = .dateAdded
        #expect(settings.shelfSort == .dateAdded)

        defaults.set("size", forKey: ShelfSettings.shelfSortKey)
        #expect(settings.shelfSort == .none)
    }
}
