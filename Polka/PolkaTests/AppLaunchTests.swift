import AppKit
import Testing
@testable import Polka

@MainActor
struct AppLaunchTests {
    /// The unit tests run inside the app, which must not bring up the panel or its
    /// global mouse monitors while they do.
    @Test func unitTestsDoNotStartTheNotchPanel() {
        #expect(!NSApp.windows.contains { $0 is NotchPanel })
    }

    /// Polka has a Dock icon, so it runs as a regular app rather than a menu bar agent.
    @Test func polkaHasADockIcon() {
        #expect(NSApp.activationPolicy() == .regular)
    }

    /// Polka's menu bar shows while it's the active app, and its Polka menu offers
    /// Settings… with the usual Cmd-comma.
    @Test func thePolkaMenuOffersSettings() {
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let settings = appMenu?.items.first { $0.title == "Settings…" }
        #expect(settings?.keyEquivalent == ",")
        #expect(settings?.keyEquivalentModifierMask == .command)
    }
}
