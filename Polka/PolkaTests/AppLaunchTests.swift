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
}
