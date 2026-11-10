import CoreGraphics
import Foundation
import Testing
@testable import Polka

/// The hover delay and hover area settings, and the areas they make.
struct HoverTuningTests {
    private let notch = CGRect(x: 663, y: 950, width: 185, height: 32)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - Areas

    @Test func mediumIsTheAreaPolkaHadBefore() {
        let area = NotchGeometry.hoverRect(around: notch, area: .medium)

        #expect(area == CGRect(x: notch.minX - 12, y: notch.minY - 4,
                               width: notch.width + 24, height: notch.height + 8))
    }

    @Test func eachSizeHoldsTheOneBelowIt() {
        let small = NotchGeometry.hoverRect(around: notch, area: .small)
        let medium = NotchGeometry.hoverRect(around: notch, area: .medium)
        let large = NotchGeometry.hoverRect(around: notch, area: .large)

        #expect(medium.contains(small))
        #expect(large.contains(medium))
        #expect(large.width > medium.width && large.height > medium.height)
    }

    @Test func everySizeReachesTheTopEdgeOfTheScreen() {
        let topOfScreen = CGPoint(x: notch.midX, y: notch.maxY)

        for area in HoverArea.allCases {
            #expect(NotchGeometry.hoverRect(around: notch, area: area).contains(topOfScreen))
        }
    }

    @Test func smallIsJustTheNotch() {
        let small = NotchGeometry.hoverRect(around: notch, area: .small)

        #expect(!small.contains(CGPoint(x: notch.minX - 1, y: notch.midY)))
        #expect(!small.contains(CGPoint(x: notch.midX, y: notch.minY - 1)))
        #expect(small.contains(CGPoint(x: notch.minX, y: notch.minY)))
    }

    // MARK: - Settings

    @Test func theDefaultsAre250MillisecondsAndSmall() throws {
        try withDefaults { defaults in
            let settings = ShelfSettings(defaults: defaults)
            #expect(settings.hoverDelay == 250)
            #expect(settings.hoverArea == .small)
        }
    }

    @Test func zeroIsAValidDelayAndOutOfRangeValuesAreClamped() throws {
        try withDefaults { defaults in
            let settings = ShelfSettings(defaults: defaults)

            settings.hoverDelay = 0
            #expect(settings.hoverDelay == 0)

            defaults.set(5000, forKey: ShelfSettings.hoverDelayKey)
            #expect(settings.hoverDelay == ShelfSettings.hoverDelayRange.upperBound)

            defaults.set(-20, forKey: ShelfSettings.hoverDelayKey)
            #expect(settings.hoverDelay == 0)
        }
    }

    @Test func theAreaIsSavedAndAnUnknownValueFallsBackToTheDefault() throws {
        try withDefaults { defaults in
            let settings = ShelfSettings(defaults: defaults)

            settings.hoverArea = .large
            #expect(settings.hoverArea == .large)
            #expect(defaults.string(forKey: ShelfSettings.hoverAreaKey) == "large")

            defaults.set("enormous", forKey: ShelfSettings.hoverAreaKey)
            #expect(settings.hoverArea == .small)
        }
    }
}
