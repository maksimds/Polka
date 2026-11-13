import Foundation
import Testing
@testable import Polka

/// Settings' Transparency: how see-through the open panel is.
struct AppearanceSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func thePanelStartsSolid() throws {
        try withDefaults { defaults in
            #expect(ShelfSettings(defaults: defaults).panelTransparency == 0)
        }
    }

    @Test func aChosenTransparencyIsKept() throws {
        try withDefaults { defaults in
            ShelfSettings(defaults: defaults).panelTransparency = 45
            #expect(ShelfSettings(defaults: defaults).panelTransparency == 45)
        }
    }

    @Test func aValueSetByHandOutsideTheRangeCountsAsTheNearestEnd() throws {
        try withDefaults { defaults in
            defaults.set(250, forKey: ShelfSettings.panelTransparencyKey)
            #expect(ShelfSettings(defaults: defaults).panelTransparency == 100)
            defaults.set(-20, forKey: ShelfSettings.panelTransparencyKey)
            #expect(ShelfSettings(defaults: defaults).panelTransparency == 0)
        }
    }
}
