import AppKit
import Foundation
import Testing
@testable import Polka

/// Shelf folders (FR-26): folders made on the shelf to sort tiles into. They live only
/// in shelf.json, and the tiles in them keep pointing at their own files.
@MainActor
struct ShelfFolderTests {
    private func files(_ names: String...) -> [ShelfItem.Draft] {
        names.map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) }
    }

    private func titles(_ items: [ShelfItem]) -> String {
        items.map(\.title).joined(separator: " ")
    }

    private func id(_ title: String, in store: ShelfStore) -> ShelfItem.ID {
        store.items.first { $0.title == title }!.id
    }

    /// A folder named `name`, holding nothing yet.
    private func folder(_ name: String, in store: ShelfStore) -> ShelfItem.ID {
        let folder = store.createFolder()
        store.rename(id: folder.id, to: name)
        return folder.id
    }

    // MARK: - Making and naming

    @Test func aNewFolderArrivesAtTheFrontAfterThePinnedTiles() {
        let store = ShelfStore()
        store.add(files("a", "b"))
        store.pin(id: id("b", in: store))

        let folder = store.createFolder()

        #expect(folder.kind == .shelfFolder)
        #expect(folder.source == .shelfFolder)
        #expect(folder.folderID == nil)
        #expect(!folder.isTemporary)
        #expect(titles(store.items) == "b Untitled Folder a")
    }

    @Test func newFoldersAreNumberedWhileTheNameIsTakenAsInFinder() {
        #expect(ShelfStore.freeFolderName(among: []) == "Untitled Folder")
        #expect(ShelfStore.freeFolderName(among: ["untitled folder"]) == "Untitled Folder 2")
        #expect(ShelfStore.freeFolderName(among: ["Untitled Folder", "Untitled Folder 2"]) == "Untitled Folder 3")

        let store = ShelfStore()
        store.createFolder()
        store.createFolder()
        #expect(Set(store.items.map(\.title)) == ["Untitled Folder", "Untitled Folder 2"])
    }

    @Test func aFolderIsRenamedByItsNameAndAnEmptyNameChangesNothing() {
        let store = ShelfStore()
        let id = store.createFolder().id

        store.rename(id: id, to: "  Work\nStuff ")
        #expect(store.folder(id)?.title == "Work Stuff")
        #expect(store.folder(id)?.customName == nil)

        store.rename(id: id, to: "   ")
        #expect(store.folder(id)?.displayName == "Work Stuff")
    }

    @Test func aFolderNeverExpires() {
        let store = ShelfStore()
        let id = store.createFolder().id

        store.makeTemporary(id: id, lifetime: 60)

        #expect(store.folder(id)?.isTemporary == false)
    }

    // MARK: - Moving in and out

    @Test func tilesMovedIntoAFolderLeaveTheShelfAndArriveAtTheFolderFront() {
        let store = ShelfStore()
        store.add(files("a", "b", "c"))
        let work = folder("Work", in: store)
        store.add(files("x"), in: work)

        let moved = store.move([id("a", in: store), id("c", in: store)], toFolder: work)

        #expect(moved.count == 2)
        #expect(titles(store.items(in: nil)) == "Work b")
        #expect(titles(store.items(in: work)) == "a c x")
        #expect(store.folderItemCounts[work] == 3)
    }

    @Test func tilesMovedOutGoBackToTheShelfFront() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a", "b"), in: work)
        store.add(files("z"))

        store.move([id("a", in: store)], toFolder: nil)

        #expect(titles(store.items(in: nil)) == "a z Work")
        #expect(titles(store.items(in: work)) == "b")
    }

    @Test func aFolderNeverGoesIntoAFolder() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        let home = folder("Home", in: store)

        #expect(store.move([home, work], toFolder: work).isEmpty)
        #expect(store.items.allSatisfy { $0.folderID == nil })
    }

    @Test func movingToAFolderThatIsGoneChangesNothing() {
        let store = ShelfStore()
        store.add(files("a"))
        let before = store.items

        #expect(store.move([id("a", in: store)], toFolder: UUID()).isEmpty)
        #expect(store.items == before)
    }

    @Test func aMovedTileLosesItsPin() {
        let store = ShelfStore()
        store.add(files("a"))
        let work = folder("Work", in: store)
        store.pin(id: id("a", in: store))

        store.move([id("a", in: store)], toFolder: work)

        #expect(store.items.first { $0.title == "a" }?.isPinned == false)
    }

    // MARK: - Adding

    @Test func newItemsCanArriveInAFolder() {
        let store = ShelfStore()
        let work = folder("Work", in: store)

        let result = store.add(files("a", "b"), in: work)

        #expect(result.added.allSatisfy { $0.folderID == work })
        #expect(titles(store.items(in: work)) == "a b")
        #expect(titles(store.items(in: nil)) == "Work")
    }

    @Test func anItemAddedNextToAnotherLandsInItsFolder() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("report.docx", "z"), in: work)

        store.add(files("report.pdf"), after: id("report.docx", in: store))

        #expect(titles(store.items(in: work)) == "report.docx report.pdf z")
    }

    @Test func aFolderThatIsGoneMeansTheShelf() {
        let store = ShelfStore()

        store.add(files("a"), in: UUID())

        #expect(store.items.first?.folderID == nil)
    }

    @Test func duplicatesAreCaughtAcrossFolders() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a"), in: work)

        let result = store.add(files("a"))

        #expect(result.added.isEmpty)
        #expect(result.duplicates.count == 1)
    }

    @Test func twoFoldersCanShareANameWithoutBeingDuplicates() {
        let store = ShelfStore()
        _ = folder("Work", in: store)
        _ = folder("Work", in: store)

        #expect(store.items.filter(\.isShelfFolder).count == 2)
    }

    // MARK: - Removing

    @Test func removingAFolderPutsItsTilesBackWhereItWas() {
        let store = ShelfStore()
        store.add(files("c"))
        let work = folder("Work", in: store)
        store.add(files("a", "b"), in: work)
        store.add(files("z"))
        store.pin(id: id("a", in: store))
        #expect(titles(store.items(in: nil)) == "z Work c")

        store.remove(ids: [work])

        #expect(store.folder(work) == nil)
        #expect(titles(store.items) == "z a b c")
        #expect(store.items.allSatisfy { $0.folderID == nil && !$0.isPinned })
    }

    @Test func removingAFolderWithSomeOfItsTilesKeepsTheRest() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a", "b"), in: work)

        store.remove(ids: [work, id("a", in: store)])

        #expect(titles(store.items) == "b")
    }

    @Test func expiredTilesInAFolderLeaveAndTheFolderStays() {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = ShelfStore(now: { now })
        let work = folder("Work", in: store)
        store.add(files("a"), in: work)
        store.makeTemporary(id: id("a", in: store), lifetime: 60)

        now += 61
        store.removeExpired()

        #expect(titles(store.items) == "Work")
    }

    // MARK: - Order, sort and pins in each place

    @Test func tilesMovedByHandOnlyReorderTheirOwnPlace() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a", "b", "c"), in: work)
        store.add(files("x", "y"))
        #expect(titles(store.items(in: nil)) == "x y Work")

        store.move([id("c", in: store)], to: 0, in: work)
        store.move([id("x", in: store)], to: 2, in: nil)

        #expect(titles(store.items(in: work)) == "c a b")
        #expect(titles(store.items(in: nil)) == "y Work x")
        #expect(store.items.map(\.sortOrder) == Array(0..<store.items.count))
    }

    @Test func theShelfsSortLeavesFoldersAsTheyAre() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("b", "c", "a"), in: work)
        store.add(files("z", "m"))

        store.setSort(.name)

        #expect(titles(store.items(in: nil)) == "m Work z")
        #expect(titles(store.items(in: work)) == "b c a")
        #expect(store.sort(in: work) == ShelfSort.none)
    }

    @Test func aFoldersSortLeavesTheShelfAndOtherFoldersAsTheyAre() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        let home = folder("Home", in: store)
        store.add(files("b", "c", "a"), in: work)
        store.add(files("y", "x"), in: home)
        store.add(files("z", "m"))
        let shelfBefore = titles(store.items(in: nil))

        store.setSort(.name, in: work)

        #expect(titles(store.items(in: work)) == "a b c")
        #expect(titles(store.items(in: home)) == "y x")
        #expect(titles(store.items(in: nil)) == shelfBefore)
        #expect(store.sort == ShelfSort.none)
        #expect(store.sort(in: work) == .name)
    }

    @Test func aSortedFolderKeepsNewTilesInOrderAndRefusesHandMoves() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("b", "d"), in: work)
        store.setSort(.name, in: work)

        store.add(files("c", "a"), in: work)
        store.move([id("a", in: store)], to: 3, in: work)

        #expect(titles(store.items(in: work)) == "a b c d")
    }

    @Test func aFolderBackOnNoneKeepsItsLastSortedOrder() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("b", "a"), in: work)
        store.setSort(.name, in: work)

        store.setSort(.none, in: work)
        store.move([id("a", in: store)], to: 1, in: work)

        #expect(store.folder(work)?.sortBy == nil)
        #expect(titles(store.items(in: work)) == "b a")
    }

    @Test func pinsStayFirstInEachPlaceWhateverItsSort() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("c", "b", "a"), in: work)
        store.add(files("z", "y"))
        store.setSort(.name, in: work)
        store.pin(id: id("c", in: store))
        store.pin(id: id("z", in: store))

        #expect(titles(store.items(in: work)) == "c a b")
        #expect(titles(store.items(in: nil)) == "z y Work")
        store.unpin(id: id("c", in: store))
        #expect(titles(store.items(in: work)) == "a b c")
    }

    @Test func aFoldersSortIsSavedWithIt() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-folder-sort-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))
        let work = folder("Work", in: store)
        store.add(files("b", "a"), in: work)
        store.setSort(.name, in: work)

        let reloaded = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))

        #expect(reloaded.sort(in: work) == .name)
        #expect(reloaded.sort == ShelfSort.none)
        #expect(titles(reloaded.items(in: work)) == "a b")
    }

    @Test func choosingASortInAnOpenFolderOnlySortsItAndIsNotSavedAsTheShelfs() {
        let store = ShelfStore()
        var saved: [ShelfSort] = []
        let model = NotchViewModel(store: store, saveSort: { saved.append($0) })
        model.state = .expanded
        let work = folder("Work", in: store)
        store.add(files("b", "a"), in: work)
        store.add(files("z", "m"))
        model.openFolder(work)

        model.chooseSort(.name)

        #expect(model.shownSort == .name)
        #expect(saved.isEmpty)
        #expect(store.sort == ShelfSort.none)
        model.closeFolder()
        #expect(model.shownSort == ShelfSort.none)
    }

    @Test func kindPutsShelfFoldersWithTheFolders() {
        let store = ShelfStore(sort: .kind)
        store.add([ShelfItem.Draft(text: "note")])
        _ = folder("Work", in: store)

        #expect(ShelfSort.kind.groups(of: store.items).first?.title == "Folders")
        #expect(store.items.first?.isShelfFolder == true)
    }

    @Test func eachPlacePinsFiveOfItsOwn() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a", "b", "c", "d", "e", "f"))
        store.add(files("1", "2", "3", "4", "5", "6"), in: work)

        for title in ["a", "b", "c", "d", "e", "1", "2", "3", "4", "5"] {
            #expect(store.pin(id: id(title, in: store)), "\(title)")
        }
        #expect(!store.pin(id: id("6", in: store)))
        #expect(store.pinnedCount(in: work) == 5)
        #expect(store.pinnedCount(in: nil) == 5)
        #expect(titles(store.items(in: work).prefix(5).map { $0 }) == "1 2 3 4 5")
    }

    @Test func aPinnedTileInAFolderComesFirstThereAndAnUnpinnedOneFirstAfterThePins() {
        let store = ShelfStore()
        let work = folder("Work", in: store)
        store.add(files("a", "b", "c"), in: work)
        store.add(files("x"))
        store.pin(id: id("x", in: store))

        store.pin(id: id("c", in: store))
        #expect(titles(store.items(in: work)) == "c a b")
        store.pin(id: id("b", in: store))
        #expect(titles(store.items(in: work)) == "c b a")
        store.unpin(id: id("c", in: store))
        #expect(titles(store.items(in: work)) == "b c a")
    }

    // MARK: - Saving

    @Test func foldersAndTheirTilesSurviveAJSONRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-folders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))
        let work = folder("Work", in: store)
        store.add(files("a"), in: work)
        store.add([ShelfItem.Draft(text: "note")])

        let reloaded = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))

        #expect(!reloaded.loadFailed)
        #expect(reloaded.items == store.items)
        #expect(reloaded.folder(work)?.title == "Work")
        #expect(titles(reloaded.items(in: work)) == "a")
    }

    @Test func aShelfSavedBeforeFoldersStillLoads() throws {
        let json = """
        {"version":1,"items":[{"id":"6A1C2F3E-0000-4000-8000-000000000001","kind":"text",
        "title":"note","source":{"text":{"_0":"note"}},"storageMode":"reference",
        "createdAt":0,"sortOrder":0}]}
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(json.utf8).write(to: file)

        let store = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: file))

        #expect(!store.loadFailed)
        #expect(store.items.first?.folderID == nil)
        #expect(store.items.first?.title == "note")
    }

    @Test func aTileWhoseFolderIsGoneLoadsOnTheShelf() throws {
        let persistence = InMemoryShelfPersistence()
        var orphan = ShelfStore().add([ShelfItem.Draft(text: "note")]).added[0]
        orphan.folderID = UUID()
        persistence.save([orphan])

        let store = ShelfStore(persistence: persistence)

        #expect(store.items.first?.folderID == nil)
    }

    // MARK: - The panel

    private func openModel() -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        let model = NotchViewModel(store: store, moveSettleDelay: .zero)
        model.state = .expanded
        return (model, store)
    }

    @Test func openingAFolderShowsItsTilesAndClosingItSelectsTheFolder() {
        let (model, store) = openModel()
        store.add(files("a"))
        let work = folder("Work", in: store)
        store.add(files("x", "y"), in: work)
        model.click(id("a", in: store), .only)

        model.openFolder(work)

        #expect(model.shownFolder?.title == "Work")
        #expect(titles(model.shownItems) == "x y")
        #expect(titles(model.displayedItems) == "x y")
        #expect(model.selection.isEmpty)

        model.closeFolder()

        #expect(model.shownFolder == nil)
        #expect(titles(model.shownItems) == "Work a")
        #expect(model.selection == [work])
    }

    @Test func onlyAShelfFolderOpens() {
        let (model, store) = openModel()
        store.add(files("a"))

        model.openFolder(id("a", in: store))

        #expect(model.shownFolder == nil)
    }

    @Test func closingThePanelGoesBackToTheShelf() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.openFolder(work)

        model.state = .collapsed

        #expect(model.shownFolder == nil)
    }

    @Test func whatIsAddedWhileAFolderIsOpenGoesIntoIt() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.openFolder(work)

        model.paste(.text("a note"))
        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/dropped"))])
        model.beginAddingLink()
        #expect(model.addLink(from: "example.com") == nil)

        #expect(store.items(in: work).count == 3)
        #expect(titles(store.items(in: nil)) == "Work")
    }

    @Test func filesChosenForAFolderOpenItNextTime() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.openFolder(work)
        model.state = .collapsed

        model.addFiles([URL(fileURLWithPath: "/tmp/chosen")], in: work)

        #expect(store.items(in: work).map(\.title) == ["chosen"])
        #expect(model.shownFolder?.id == work)
        #expect(model.itemToReveal == id("chosen", in: store))
    }

    @Test func aDuplicateSaysWhichFolderItIsIn() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        store.add(files("report.pdf"), in: work)

        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/report.pdf"))])

        #expect(model.notice == "report.pdf is already in Work")
    }

    @Test func aNewFolderOpensItsNameForTyping() {
        let (model, store) = openModel()

        model.createFolder()

        let folder = try? #require(store.items.first)
        #expect(folder?.isShelfFolder == true)
        #expect(model.renamingItemID == folder?.id)
        #expect(model.selection == Set([folder?.id].compactMap { $0 }))
    }

    @Test func noFolderIsMadeInsideAFolder() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.openFolder(work)

        #expect(!model.canCreateFolder)
        model.createFolder()

        #expect(store.items.filter(\.isShelfFolder).count == 1)
    }

    @Test func moveToListsTheShelfAndTheOtherFoldersAToZ() {
        let (model, store) = openModel()
        store.add(files("a"))
        let work = folder("Work", in: store)
        let home = folder("Home", in: store)
        store.add(files("x"), in: work)

        #expect(model.moveDestinations(for: id("a", in: store)).map(\.title) == ["Home", "Work"])
        #expect(model.moveDestinations(for: id("x", in: store)).map(\.title) == ["Shelf", "Home"])
        #expect(model.moveDestinations(for: home).isEmpty)
    }

    @Test func moveToMovesTheSelectionLeavingFoldersBehindAndPulsesTheFolder() {
        let (model, store) = openModel()
        store.add(files("a", "b"))
        let work = folder("Work", in: store)
        let home = folder("Home", in: store)
        model.click(id("a", in: store), .only)
        model.click(id("b", in: store), .toggle)
        model.click(home, .toggle)
        #expect(model.movableSelectionCount == 2)

        model.move(from: id("a", in: store), toFolder: work)

        #expect(titles(store.items(in: work)) == "a b")
        #expect(store.folder(home)?.folderID == nil)
        #expect(model.selection == [home])
        #expect(model.copyPulses[work] == 1)
    }

    @Test func aFolderOnlyMovesAroundTheShelfAndStaysBehindWhenOthersGo() {
        let (model, store) = openModel()
        store.add(files("a"))
        let work = folder("Work", in: store)

        let alone = model.dragContents(from: work)
        #expect(alone.staysOnShelf)
        #expect(alone.items.map(\.id) == [work])

        model.click(id("a", in: store), .toggle)
        let together = model.dragContents(from: id("a", in: store))
        #expect(!together.staysOnShelf)
        #expect(together.items.map(\.title) == ["a"])
    }

    @Test func aFolderIsNeverCopiedSharedOrOpenedAsAFile() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.click(work, .only)

        #expect(!model.copySelection(to: NSPasteboard(name: NSPasteboard.Name("polka-tests-\(UUID())"))))
        #expect(model.itemsToShare(from: work).isEmpty)
        #expect(model.urlToOpen(work) == nil)
        #expect(model.itemsToSend(from: work).isEmpty)
    }

    @Test func tilesMovedByHandInsideAFolderStayInIt() {
        let (model, store) = openModel()
        store.add(files("z"))
        let work = folder("Work", in: store)
        store.add(files("a", "b", "c"), in: work)
        model.openFolder(work)

        model.beginTileMove(model.dragContents(from: id("c", in: store)))
        model.finishTileMove(at: 0, gliding: false)

        #expect(titles(store.items(in: work)) == "c a b")
        #expect(titles(store.items(in: nil)) == "Work z")
    }

    @Test func removingAFolderFromThePanelPutsItsTilesOnTheShelf() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        store.add(files("a"), in: work)

        model.remove([work])

        #expect(titles(store.items) == "a")
    }

    @Test func aFolderNeverTurnsTemporaryFromTheMenu() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)

        model.toggleTemporary(work)

        #expect(store.folder(work)?.isTemporary == false)
    }

    @Test func theTypeLineCountsWhatAFolderHolds() {
        #expect(ShelfItemTile.folderLine(count: 0) == "Empty")
        #expect(ShelfItemTile.folderLine(count: 1) == "1 Item")
        #expect(ShelfItemTile.folderLine(count: 12) == "12 Items")
    }

    // MARK: - Dragging into and out of folders

    /// The panel open on a shelf laid out like the real one, where tiles make room at once.
    private func laidOutModel() -> (model: NotchViewModel, store: ShelfStore) {
        let (model, store) = openModel()
        model.gridGeometry.viewport = CGRect(x: 16, y: 40, width: 488, height: 216)
        model.gridGeometry.content = CGRect(x: 16, y: 40, width: 488, height: 208)
        model.gridGeometry.pictureInSlot = CGRect(x: 19.6, y: 6, width: 52, height: 52)
        return (model, store)
    }

    /// The middle of the picture of the tile shown at `index`.
    private func pointOnTile(_ index: Int, of model: NotchViewModel) -> CGPoint {
        let placement = model.gridGeometry.layout.placement(tileCount: model.displayedItems.count,
                                                            groups: model.displayedGroups)
        let frame = model.gridGeometry.pictureFrame(ofTile: index, in: placement)!
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test func tilesDroppedOnAFolderGoInsideAndThePicturesGlideIntoIt() throws {
        let (model, store) = laidOutModel()
        store.add(files("a", "b"))
        let work = folder("Work", in: store)
        #expect(titles(model.displayedItems) == "Work a b")
        model.click(id("a", in: store), .only)
        model.click(id("b", in: store), .toggle)
        model.beginTileMove(model.dragContents(from: id("b", in: store)))
        let onFolder = pointOnTile(0, of: model)

        model.tileMoved(to: onFolder)
        #expect(model.tileMoveInto == .folder(work))
        let drop = try #require(model.tileDrop(at: onFolder))
        model.finishTileMove(drop, gliding: true)

        #expect(drop.into == .folder(work))
        #expect(drop.landingFrames.count == 2)
        #expect(drop.landingFrames.allSatisfy { $0.contains(onFolder) })
        #expect(titles(store.items(in: work)) == "a b")
        #expect(titles(store.items(in: nil)) == "Work")
        #expect(model.copyPulses[work] == 1)
        #expect(model.tileMoveInto == nil)
        #expect(model.selection.isEmpty)
    }

    @Test func overAFolderTheOtherTilesStopMakingRoom() {
        let (model, store) = laidOutModel()
        store.add(files("a", "b", "c"))
        _ = folder("Work", in: store)
        model.beginTileMove(model.dragContents(from: id("c", in: store)))

        model.tileMoved(to: pointOnTile(1, of: model))
        #expect(titles(model.displayedItems) == "Work c a b")
        model.tileMoved(to: pointOnTile(0, of: model))

        #expect(titles(model.displayedItems) == "Work c a b")
    }

    @Test func aSortedShelfStillTakesTilesIntoAFolder() throws {
        let (model, store) = laidOutModel()
        store.add(files("b", "a"))
        let work = folder("Work", in: store)
        model.chooseSort(.name)
        #expect(titles(model.displayedItems) == "a b Work")
        model.beginTileMove(model.dragContents(from: id("a", in: store)))
        let onFolder = pointOnTile(2, of: model)

        model.tileMoved(to: onFolder)
        let drop = try #require(model.tileDrop(at: onFolder))
        model.finishTileMove(drop, gliding: false)

        #expect(titles(store.items(in: work)) == "a")
    }

    @Test func aFolderDraggedOntoAFolderStaysPut() throws {
        let (model, store) = laidOutModel()
        let work = folder("Work", in: store)
        let home = folder("Home", in: store)
        #expect(titles(model.displayedItems) == "Home Work")
        model.beginTileMove(model.dragContents(from: home))

        model.tileMoved(to: pointOnTile(1, of: model))

        #expect(model.tileMoveInto == nil)
        let drop = try #require(model.tileDrop(at: pointOnTile(1, of: model)))
        #expect(drop.into == nil)
        #expect(store.items(in: work).isEmpty)
    }

    @Test func tilesDroppedOnPolkaGoBackOntoTheShelf() throws {
        let (model, store) = laidOutModel()
        let work = folder("Work", in: store)
        store.add(files("a", "b"), in: work)
        model.openFolder(work)
        model.gridGeometry.backTitleArea = CGRect(x: 16, y: 8, width: 44, height: 20)
        model.beginTileMove(model.dragContents(from: id("b", in: store)))
        let onPolka = CGPoint(x: 30, y: 18)

        model.tileMoved(to: onPolka)
        #expect(model.tileMoveInto == .shelf)
        let drop = try #require(model.tileDrop(at: onPolka))
        model.finishTileMove(drop, gliding: false)

        #expect(titles(store.items(in: work)) == "a")
        #expect(titles(store.items(in: nil)) == "b Work")
    }

    @Test func polkaTakesNothingOnTheShelfItself() {
        let (model, store) = laidOutModel()
        store.add(files("a"))
        model.gridGeometry.backTitleArea = CGRect(x: 16, y: 8, width: 44, height: 20)
        model.beginTileMove(model.dragContents(from: id("a", in: store)))

        model.tileMoved(to: CGPoint(x: 30, y: 18))

        #expect(model.tileMoveInto == nil)
    }

    @Test func leavingThePanelForgetsTheFolderUnderThePointer() {
        let (model, store) = laidOutModel()
        store.add(files("a"))
        _ = folder("Work", in: store)
        model.beginTileMove(model.dragContents(from: id("a", in: store)))
        model.tileMoved(to: pointOnTile(0, of: model))

        model.tileMoveLeft()

        #expect(model.tileMoveInto == nil)
    }

    // MARK: - The drop zone's folders

    @Test func theDropZoneOffersTheShelfsFoldersInItsOrderAndNoneWithoutFolders() {
        let (model, store) = openModel()
        store.add(files("a"))
        #expect(model.dropZoneFolders.isEmpty)

        let work = folder("Work", in: store)
        let home = folder("Home", in: store)
        store.pin(id: work)

        #expect(model.dropZoneFolders.map(\.id) == [work, home])
    }

    @Test func aDragOverAFolderInTheRowLightsItUpAndLeavingClearsIt() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.state = .dropReady
        model.dropZoneGeometry.folderFrames[work] = CGRect(x: 100, y: 200, width: 70, height: 60)

        model.externalDragMoved(to: CGPoint(x: 130, y: 230))
        #expect(model.dropZoneFolderID == work)
        #expect(model.dropZoneFolder(at: CGPoint(x: 130, y: 230)) == work)

        model.externalDragMoved(to: CGPoint(x: 30, y: 230))
        #expect(model.dropZoneFolderID == nil)

        model.externalDragMoved(to: CGPoint(x: 130, y: 230))
        model.state = .expanded
        #expect(model.dropZoneFolderID == nil)
        #expect(model.dropZoneFolder(at: CGPoint(x: 130, y: 230)) == nil)
    }

    @Test func aDropOnAFolderInTheRowGoesStraightInAndTheShelfShowsTheFolder() async throws {
        let (model, store) = openModel()
        store.add(files("z"))
        let work = folder("Work", in: store)
        model.state = .dropReady

        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/dropped")), .text("a note")], intoFolder: work)

        #expect(titles(store.items(in: work)) == "dropped a note")
        #expect(titles(store.items(in: nil)) == "Work z")
        #expect(model.state == .expanded)
        #expect(model.shownFolder == nil)
        #expect(model.itemToReveal == work)
        for _ in 0..<50 where model.copyPulses[work] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.copyPulses[work] == 1)
    }

    @Test func aDropOnTheBoxGoesWhereThePanelWasShowing() {
        let (model, store) = openModel()
        let work = folder("Work", in: store)
        model.state = .dropReady

        model.handleDrop([.file(URL(fileURLWithPath: "/tmp/on-the-box"))])

        #expect(store.items(in: work).isEmpty)
        #expect(titles(store.items(in: nil)) == "on-the-box Work")
    }

    @Test func aPromisedFileArrivesInTheFolderItWasDroppedOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copies = ShelfCopies(folder: root.appendingPathComponent("Copies", isDirectory: true))
        let store = ShelfStore()
        let work = folder("Work", in: store)
        let keeper = CopyKeeper(store: store, copies: copies)
        keeper.start()
        let file = try copies.makeFolder().appendingPathComponent("IMG_0001.heic")
        try Data("photo".utf8).write(to: file)

        keeper.promisedFileArrived(at: file, failure: nil, in: work) { _ in }

        #expect(titles(store.items(in: work)) == "IMG_0001.heic")
    }

    @Test func theDropGoesToTheFolderTheDragWasOverEvenIfTheDropZoneClosedFirst() async throws {
        let view = DropTargetView(frame: NSRect(x: 0, y: 0, width: 600, height: 310))
        let folderID = UUID()
        // Open while the drag moves; closed by the time the drop arrives, as when Polka
        // sees the button go up before the app the drag came from hands the drop over.
        var isDropZoneOpen = true
        var reported: ShelfItem.ID?
        view.dropFolder = { _ in isDropZoneOpen ? folderID : nil }
        view.onDrop = { _, folder in reported = folder }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        let drag = FakeDrag(pasteboard: pasteboard, source: nil)

        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        isDropZoneOpen = false
        #expect(view.performDragOperation(drag))
        try await Task.sleep(for: .milliseconds(50))

        #expect(reported == folderID)
    }

    @Test func aDragThatLeftTheFolderDropsOnTheShelf() async throws {
        let view = DropTargetView(frame: NSRect(x: 0, y: 0, width: 600, height: 310))
        var overFolder = true
        var reported: ShelfItem.ID? = UUID()
        view.dropFolder = { _ in overFolder ? UUID() : nil }
        view.onDrop = { _, folder in reported = folder }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        let drag = FakeDrag(pasteboard: pasteboard, source: nil)

        _ = view.draggingEntered(drag)
        overFolder = false
        _ = view.draggingUpdated(drag)
        #expect(view.performDragOperation(drag))
        try await Task.sleep(for: .milliseconds(50))

        #expect(reported == nil)
    }

    // MARK: - The picture

    @Test func theFolderPictureIsLightGreyAndShapedLikeFindersFolder() throws {
        let icon = NSWorkspace.shared.icon(for: .folder)
        let picture = try #require(ShelfFolderPicture.make(from: icon, pixels: 64))
        let original = try #require(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))

        // The same shape as Finder's folder.
        let bounds = ShelfItemImages.visibleBounds(of: picture)
        let finders = ShelfItemImages.visibleBounds(of: original)
        #expect(abs(bounds.minY - finders.minY) < 0.05)
        #expect(abs(bounds.width - finders.width) < 0.05)

        // Light grey in the middle of the front: no color, and bright.
        let middle = try #require(pixel(of: picture, x: 32, y: 40))
        #expect(abs(middle.red - middle.blue) < 0.02)
        #expect(middle.red > 0.75)
        // Not the dark icon of a dark drawing either, so the shelf never puts it on a page.
        #expect(!ShelfItemImages.needsLightBackground(picture))
    }

    /// The color at a pixel, counted from the top left, without its opacity.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (red: Double, green: Double, blue: Double)? {
        let side = image.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let index = (y * side + x) * 4
        let alpha = Double(pixels[index + 3])
        guard alpha > 0 else { return nil }
        return (Double(pixels[index]) / alpha, Double(pixels[index + 1]) / alpha, Double(pixels[index + 2]) / alpha)
    }
}
