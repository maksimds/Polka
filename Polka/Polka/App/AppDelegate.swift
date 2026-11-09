import AppKit

/// Starts the notch panel once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; the panel and its mouse monitors stay off for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Log.app.info("Polka launched")
        let controller = NotchPanelController(store: ShelfStore())
        controller.start()
        notchController = controller
    }
}
