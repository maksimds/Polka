import AppKit
import Testing
@testable import Polka

/// Settings opens below the open shelf, which floats above normal windows and would
/// otherwise cover its top.
@MainActor
struct SettingsPlacementTests {
    private var screen: NSScreen? { NSScreen.screens.first }

    @Test func theShelfLowersTheTopOfTheRoomForSettings() throws {
        let screen = try #require(screen)
        let visible = screen.visibleFrame
        let shelfBottom = visible.maxY - 200
        let area = SettingsWindowController.area(on: screen, below: shelfBottom)
        #expect(area.maxY == shelfBottom)
        #expect(area.minY == visible.minY)
        #expect(area.width == visible.width)
    }

    @Test func withoutTheShelfSettingsHasTheWholeScreen() throws {
        let screen = try #require(screen)
        #expect(SettingsWindowController.area(on: screen, below: nil) == screen.visibleFrame)
    }

    @Test func aShelfBottomAboveTheMenuBarChangesNothing() throws {
        // A shelf that ends inside the menu bar's strip leaves the room as it is.
        let screen = try #require(screen)
        let area = SettingsWindowController.area(on: screen, below: screen.frame.maxY)
        #expect(area == screen.visibleFrame)
    }

    @Test func settingsGoesToTheBuiltInScreenWhenThereIsOne() {
        let builtIn = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        #expect(NotchGeometry.settingsScreen() == (builtIn ?? NSScreen.screens.first))
    }
}
