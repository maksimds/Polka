import AppKit
import Testing
@testable import Polka

/// Settings' tabs: General and Nearby Sharing, as toolbar buttons, each giving the
/// window its own height.
@MainActor
struct SettingsTabsTests {
    @Test func eachTabGivesTheWindowItsHeightAndTheTopStaysPut() async throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = try #require(NSScreen.screens.first)
        let controller = SettingsWindowController(loginItem: LoginItem(), screenshots: nil,
                                                  nearby: NearbyService(settings: ShelfSettings(defaults: defaults)),
                                                  focus: FocusReturner())
        controller.show(on: screen, below: nil)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }

        func contentHeight() -> CGFloat { window.contentRect(forFrameRect: window.frame).height }
        let room = screen.visibleFrame.height - (window.frame.height - contentHeight()) - 16

        #expect(controller.selectedTab == .general)
        #expect(window.titleVisibility == .hidden)
        let general = controller.measuredFormHeight(for: .general)
        #expect(abs(contentHeight() - min(general, room)) < 1)
        let top = window.frame.maxY

        controller.select(.nearby)
        // The window grows or shrinks over a quarter of a second.
        try await Task.sleep(for: .milliseconds(600))
        let nearby = controller.measuredFormHeight(for: .nearby)
        #expect(nearby < general)
        #expect(abs(contentHeight() - min(nearby, room)) < 1)
        #expect(abs(window.frame.maxY - top) < 1)

        controller.select(.general)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(contentHeight() - min(general, room)) < 1)
        #expect(abs(window.frame.maxY - top) < 1)
    }
}
