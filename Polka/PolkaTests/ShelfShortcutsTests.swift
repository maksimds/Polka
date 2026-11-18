import Testing
@testable import Polka

/// When Cmd-V and Cmd-C belong to Polka. While they do, no other app gets them, so it
/// must only be while the pointer is over the open shelf and nothing else on it wants
/// the keys.
struct ShelfShortcutsTests {
    private func wanted(state: NotchState = .expanded,
                        isRenaming: Bool = false,
                        isMenuOpen: Bool = false,
                        isSharing: Bool = false,
                        isPointerOverPanel: Bool = true) -> Bool {
        ShelfShortcuts.isWanted(state: state,
                               isRenaming: isRenaming,
                               isMenuOpen: isMenuOpen,
                               isSharing: isSharing,
                               isPointerOverPanel: isPointerOverPanel)
    }

    @Test func itIsOnWithThePointerOverTheOpenShelf() {
        #expect(wanted())
    }

    @Test func itIsOffWithThePointerAway() {
        // A message keeps the shelf open for a while after the pointer leaves, and
        // Cmd-V must still reach the app you went back to.
        #expect(!wanted(isPointerOverPanel: false))
    }

    @Test func itIsOffUnlessTheShelfIsOpen() {
        // The closed notch doesn't count, nor the drop zone, a drag out, or the link
        // field, which takes Cmd-V into its text.
        for state in [NotchState.collapsed, .dropReady, .draggingOut, .addingLink] {
            #expect(!wanted(state: state), "\(state)")
        }
    }

    @Test func itIsOffWhileANameIsTyped() {
        #expect(!wanted(isRenaming: true))
    }

    @Test func itIsOffWhileAMenuOrShareIsUp() {
        #expect(!wanted(isMenuOpen: true))
        #expect(!wanted(isSharing: true))
    }
}
