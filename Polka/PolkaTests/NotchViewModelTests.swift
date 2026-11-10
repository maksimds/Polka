import Foundation
import Testing
@testable import Polka

@MainActor
struct NotchViewModelTests {
    private func makeModel() -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        return (NotchViewModel(store: store), store)
    }

    private func file(_ name: String) -> DroppedItem {
        .file(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func link(_ string: String) -> DroppedItem {
        .link(URL(string: string)!)
    }

    @Test func aDropStoresItemsAndExpandsThePanel() {
        let (model, store) = makeModel()
        model.state = .dropReady

        model.handleDrop([file("a.txt"), link("https://example.com/a")])

        #expect(store.items.map(\.title) == ["a.txt", "example.com/a"])
        #expect(store.items.map(\.kind) == [.file, .link])
        #expect(model.state == .expanded)
        #expect(model.notice == nil)
    }

    @Test func droppingTheSameFileAgainShowsANoticeAndAddsNothing() {
        let (model, store) = makeModel()
        model.handleDrop([file("report.pdf")])

        model.handleDrop([file("report.pdf")])

        #expect(store.items.count == 1)
        #expect(model.notice == "report.pdf is already on the shelf")
        #expect(model.state == .expanded)
    }

    @Test func droppingTheSameLinkAgainShowsANotice() {
        let (model, store) = makeModel()
        model.handleDrop([link("https://example.com/a")])

        model.handleDrop([link("https://example.com/a")])

        #expect(store.items.count == 1)
        #expect(model.notice == "example.com/a is already on the shelf")
    }

    @Test func severalDuplicatesAreCountedAndNewFilesStillGetAdded() {
        let (model, store) = makeModel()
        model.handleDrop([file("a.txt"), file("b.txt")])

        model.handleDrop([file("a.txt"), file("b.txt"), file("c.txt")])

        #expect(store.items.map(\.title) == ["c.txt", "a.txt", "b.txt"])
        #expect(model.notice == "2 items are already on the shelf")
    }

    @Test func theNoticeStaysThroughLaterDropsUntilItIsClosed() {
        let (model, _) = makeModel()
        model.handleDrop([file("a.txt")])
        model.handleDrop([file("a.txt")])

        model.handleDrop([file("new.txt")])
        #expect(model.notice == "a.txt is already on the shelf")

        model.dismissNotice()
        #expect(model.notice == nil)
    }

    // MARK: - Dragging out

    @Test func thePanelStaysOpenWhileTheDragIsInsideIt() {
        let (model, _) = makeModel()
        model.state = .expanded

        model.dragOutMoved(isInsidePanel: true)

        #expect(model.state == .expanded)
        #expect(model.currentSize == model.expandedSize)
    }

    @Test func leavingThePanelMidDragShrinksItToTheNotch() {
        let (model, _) = makeModel()
        model.state = .expanded

        model.dragOutMoved(isInsidePanel: false)

        #expect(model.state == .draggingOut)
        #expect(model.currentSize == model.notchSize)
    }

    @Test func comingBackMidDragDoesNotReopenThePanel() {
        let (model, _) = makeModel()
        model.state = .expanded
        model.dragOutMoved(isInsidePanel: false)

        model.dragOutMoved(isInsidePanel: true)

        #expect(model.state == .draggingOut)
    }

    @Test func aDragThatEndsAwayCollapsesThePanel() {
        let (model, _) = makeModel()
        model.state = .expanded
        model.dragOutMoved(isInsidePanel: false)

        model.dragOutEnded()

        #expect(model.state == .collapsed)
    }

    @Test func aDragThatNeverLeftKeepsThePanelOpen() {
        let (model, _) = makeModel()
        model.state = .expanded
        model.dragOutMoved(isInsidePanel: true)

        model.dragOutEnded()

        #expect(model.state == .expanded)
    }

    @Test func aMessageIsStillThereAfterADragOut() {
        let (model, _) = makeModel()
        model.handleDrop([file("a.txt")])
        model.handleDrop([file("a.txt")])

        model.dragOutMoved(isInsidePanel: false)
        model.dragOutEnded()

        #expect(model.state == .collapsed)
        #expect(model.notice == "a.txt is already on the shelf")
    }

    // MARK: - Notices

    @Test func aNewDuplicateReplacesTheOldNotice() {
        let (model, _) = makeModel()
        model.handleDrop([file("a.txt"), file("b.txt")])
        model.handleDrop([file("a.txt")])

        model.handleDrop([file("b.txt")])

        #expect(model.notice == "b.txt is already on the shelf")
    }
}
