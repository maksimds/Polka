import AppKit

/// Starts the notch panel once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Polka launched")
        let controller = NotchPanelController()
        controller.start()
        notchController = controller
    }
}
