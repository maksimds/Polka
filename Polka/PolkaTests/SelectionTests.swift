import Foundation
import Testing
@testable import Polka

/// Multi-select (FR-10): which tiles a click selects, and what a drag carries.
@MainActor
struct SelectionTests {
    /// A model whose shelf holds a, b, c, d and e, in that order.
    private func makeModel() -> (model: NotchViewModel, store: ShelfStore, ids: [ShelfItem.ID]) {
        let store = ShelfStore()
        store.add(["a", "b", "c", "d", "e"].map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) })
        return (NotchViewModel(store: store), store, store.items.map(\.id))
    }

    @Test func aPlainClickSelectsOnlyThatItem() {
        let (model, _, ids) = makeModel()

        model.click(ids[0], .only)
        model.click(ids[2], .only)

        #expect(model.selection == [ids[2]])
    }

    @Test func commandClickAddsAndRemoves() {
        let (model, _, ids) = makeModel()

        model.click(ids[0], .only)
        model.click(ids[3], .toggle)
        #expect(model.selection == [ids[0], ids[3]])

        model.click(ids[0], .toggle)
        #expect(model.selection == [ids[3]])
    }

    @Test func shiftClickSelectsEverythingInBetween() {
        let (model, _, ids) = makeModel()

        model.click(ids[3], .only)
        model.click(ids[1], .range)
        #expect(model.selection == Set(ids[1...3]))

        // The range is measured from the last plain click, not the last Shift-click.
        model.click(ids[4], .range)
        #expect(model.selection == Set(ids[3...4]))
    }

    @Test func shiftClickWithNothingClickedYetActsLikeAPlainClick() {
        let (model, _, ids) = makeModel()

        model.click(ids[2], .range)

        #expect(model.selection == [ids[2]])
    }

    @Test func draggingASelectedItemCarriesTheWholeSelectionStartingWithIt() {
        let (model, _, ids) = makeModel()
        model.click(ids[0], .only)
        model.click(ids[2], .toggle)
        model.click(ids[4], .toggle)

        let dragged = model.itemsToDrag(from: ids[2])

        #expect(dragged.map(\.id) == [ids[2], ids[0], ids[4]])
        #expect(model.selection == [ids[0], ids[2], ids[4]])
    }

    @Test func draggingAnItemThatIsNotSelectedSelectsItAlone() {
        let (model, _, ids) = makeModel()
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)

        let dragged = model.itemsToDrag(from: ids[3])

        #expect(dragged.map(\.id) == [ids[3]])
        #expect(model.selection == [ids[3]])
    }

    @Test func missingFilesStayBehindWhenTheSelectionIsDragged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let present = folder.appendingPathComponent("present.txt")
        try Data("x".utf8).write(to: present)
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: present),
                   ShelfItem.Draft(fileURL: folder.appendingPathComponent("gone.txt"))])
        store.refreshReferences()
        let model = NotchViewModel(store: store)
        let ids = store.items.map(\.id)
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)

        let dragged = model.itemsToDrag(from: ids[0])

        #expect(dragged.map(\.title) == ["present.txt"])
    }

    @Test func closingThePanelClearsTheSelection() {
        let (model, _, ids) = makeModel()
        model.state = .expanded
        model.click(ids[0], .only)

        model.state = .collapsed
        #expect(model.selection.isEmpty)

        // And a Shift-click afterwards has no old anchor to measure from.
        model.state = .expanded
        model.click(ids[4], .range)
        #expect(model.selection == [ids[4]])
    }

    @Test func aDragOutKeepsTheSelectionWhileThePanelShrinks() {
        let (model, _, ids) = makeModel()
        model.state = .expanded
        model.click(ids[0], .only)

        model.dragOutMoved(isInsidePanel: false)

        #expect(model.state == .draggingOut)
        #expect(model.selection == [ids[0]])
    }

    // MARK: - Remove from the menu

    @Test func removingAnUnselectedTileRemovesOnlyThatOne() {
        let (model, store, ids) = makeModel()
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)

        model.remove(from: ids[3])

        #expect(store.items.map(\.id) == [ids[0], ids[1], ids[2], ids[4]])
        #expect(model.selection == [ids[0], ids[1]])
    }

    @Test func removingASelectedTileRemovesTheWholeSelection() {
        let (model, store, ids) = makeModel()
        model.click(ids[0], .only)
        model.click(ids[2], .toggle)

        model.remove(from: ids[2])

        #expect(store.items.map(\.id) == [ids[1], ids[3], ids[4]])
        #expect(model.selection.isEmpty)
    }

    // MARK: - Selection rectangle

    @Test func aRectangleReplacesTheSelectionAndFollowsWhatItTouches() {
        let (model, _, ids) = makeModel()
        model.click(ids[0], .only)

        model.beginMarquee(.only)
        model.updateMarquee(touching: [ids[2], ids[3]])
        #expect(model.selection == [ids[2], ids[3]])

        // Pulled back off a tile, the tile goes dark again.
        model.updateMarquee(touching: [ids[2]])
        #expect(model.selection == [ids[2]])
    }

    @Test func shiftAddsTheRectangleToTheSelection() {
        let (model, _, ids) = makeModel()
        model.click(ids[0], .only)

        model.beginMarquee(.range)
        model.updateMarquee(touching: [ids[0], ids[3]])

        #expect(model.selection == [ids[0], ids[3]])
    }

    @Test func commandFlipsEachTileTheRectangleTouches() {
        let (model, _, ids) = makeModel()
        model.click(ids[0], .only)
        model.click(ids[1], .toggle)

        model.beginMarquee(.toggle)
        model.updateMarquee(touching: [ids[1], ids[2]])

        #expect(model.selection == [ids[0], ids[2]])
    }
}
