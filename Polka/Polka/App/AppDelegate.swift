import AppKit

/// Starts the notch panel once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; the panel and its mouse monitors stay off for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Log.app.info("Polka launched")
        let controller = NotchPanelController(store: makeStore())
        controller.start()
        notchController = controller
    }

    /// The shelf, saved to a JSON file. If there is nowhere to save it, Polka still
    /// runs, but the shelf only lasts until it quits.
    private func makeStore() -> ShelfStore {
        do {
            let fileURL = try JSONFileShelfPersistence.defaultFileURL()
            Log.storage.info("Shelf file: \(fileURL.path, privacy: .public)")
            return ShelfStore(persistence: JSONFileShelfPersistence(fileURL: fileURL))
        } catch {
            Log.storage.error("""
                No Application Support folder, so the shelf won't be saved: \
                \(error.localizedDescription, privacy: .public)
                """)
            return ShelfStore()
        }
    }
}
