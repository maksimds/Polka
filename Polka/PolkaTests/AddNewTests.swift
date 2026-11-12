import Foundation
import Testing
@testable import Polka

/// Typing a link into the shelf's link field.
struct LinkInputTests {
    private func parsed(_ text: String) -> String? {
        LinkInput.url(from: text)?.absoluteString
    }

    @Test func aFullAddressIsKeptAsTyped() {
        #expect(parsed("https://github.com/apple/swift") == "https://github.com/apple/swift")
        #expect(parsed("http://example.com/a?b=1#c") == "http://example.com/a?b=1#c")
    }

    @Test func anAddressWithoutASchemeGetsHTTPS() {
        #expect(parsed("example.com") == "https://example.com/")
        #expect(parsed("www.apple.com/mac") == "https://www.apple.com/mac")
        #expect(parsed("localhost:3000") == "https://localhost:3000/")
        #expect(parsed("example.com:8080/path") == "https://example.com:8080/path")
    }

    /// Written the way a browser writes it, so it matches the same page dragged in.
    @Test func theSchemeAndHostAreLowercasedAndAnEmptyPathBecomesASlash() {
        #expect(parsed("HTTPS://Example.COM") == "https://example.com/")
        #expect(parsed("Example.com/Path") == "https://example.com/Path")
    }

    @Test func spaceAroundTheAddressIsIgnored() {
        #expect(parsed("  example.com\n") == "https://example.com/")
    }

    @Test func textThatIsNotAWebAddressIsTurnedDown() {
        #expect(parsed("") == nil)
        #expect(parsed("   ") == nil)
        #expect(parsed("hello") == nil)
        #expect(parsed("two words.com") == nil)
        #expect(parsed("example.") == nil)
        #expect(parsed(".com") == nil)
        #expect(parsed("https://") == nil)
    }

    @Test func onlyWebSchemesAreAccepted() {
        #expect(parsed("mailto:someone@example.com") == nil)
        #expect(parsed("ftp://example.com") == nil)
        #expect(parsed("file:///Users") == nil)
        #expect(parsed("javascript:alert(1)") == nil)
    }

    /// Typed with its scheme, a host needs no dot, like a machine on a home network.
    @Test func aHostWithoutADotIsFineWithAScheme() {
        #expect(parsed("http://router") == "http://router/")
    }
}

/// The header's "Add New" menu: the link field and the Open dialog.
@MainActor
struct AddNewTests {
    private func makeModel() -> (model: NotchViewModel, store: ShelfStore) {
        let store = ShelfStore()
        let model = NotchViewModel(store: store)
        model.state = .expanded
        return (model, store)
    }

    @Test func choosingLinkTurnsTheShelfIntoTheField() {
        let (model, _) = makeModel()

        model.beginAddingLink()

        #expect(model.state == .addingLink)
        #expect(model.currentSize == model.linkEntrySize)
        #expect(model.linkEntrySize.width == model.expandedSize.width)
        #expect(model.linkEntrySize.height < model.expandedSize.height)
    }

    @Test func theFieldOnlyOpensFromTheShelf() {
        let (model, _) = makeModel()
        model.state = .collapsed

        model.beginAddingLink()

        #expect(model.state == .collapsed)
    }

    @Test func theFieldStartsWithNothingSelected() {
        let (model, store) = makeModel()
        store.add([ShelfItem.Draft(linkURL: URL(string: "https://example.com/a")!)])
        model.click(store.items[0].id, .only)

        model.beginAddingLink()

        #expect(model.selection.isEmpty)
    }

    @Test func addingALinkStoresItLikeADroppedOneAndShowsTheShelfAtIt() {
        let (model, store) = makeModel()
        model.beginAddingLink()

        let problem = model.addLink(from: "github.com/apple/swift")

        #expect(problem == nil)
        #expect(store.items.map(\.title) == ["Github/apple/swift"])
        #expect(store.items.first?.source == .link(URL(string: "https://github.com/apple/swift")!))
        #expect(model.state == .expanded)
        #expect(model.itemToReveal == store.items.first?.id)
    }

    @Test func textThatIsNotALinkKeepsTheFieldOpen() {
        let (model, store) = makeModel()
        model.beginAddingLink()

        let problem = model.addLink(from: "not a link")

        #expect(problem == "That doesn't look like a web address")
        #expect(store.items.isEmpty)
        #expect(model.state == .addingLink)
    }

    @Test func aLinkAlreadyOnTheShelfKeepsTheFieldOpen() {
        let (model, store) = makeModel()
        model.handleDrop([.link(URL(string: "https://example.com/")!)])
        model.beginAddingLink()

        let problem = model.addLink(from: "example.com")

        #expect(problem == "That link is already on the shelf")
        #expect(store.items.count == 1)
        #expect(model.state == .addingLink)
        // Said in the field, not in the shelf's message.
        #expect(model.notice == nil)
    }

    @Test func cancellingGoesBackToTheShelfAddingNothing() {
        let (model, store) = makeModel()
        model.beginAddingLink()

        model.cancelAddingLink()

        #expect(model.state == .expanded)
        #expect(store.items.isEmpty)
    }

    @Test func chosenFilesAreStoredAndRevealedNextTime() {
        let (model, store) = makeModel()
        model.state = .collapsed

        model.addFiles([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")])

        #expect(store.items.map(\.title) == ["a.txt", "b.txt"])
        #expect(model.itemToReveal == store.items.first?.id)
        // The panel stays as it was; the next hover opens it.
        #expect(model.state == .collapsed)
    }

    @Test func chosenFilesAlreadyOnTheShelfGetTheUsualMessage() {
        let (model, store) = makeModel()
        model.addFiles([URL(fileURLWithPath: "/tmp/a.txt")])

        model.addFiles([URL(fileURLWithPath: "/tmp/a.txt")])

        #expect(store.items.count == 1)
        #expect(model.notice == "a.txt is already on the shelf")
    }
}
