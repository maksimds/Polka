import AppKit

/// Builds the shelf and the helpers around it, then starts the notch panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?
    private var expirySweeper: ExpirySweeper?
    private var copyKeeper: CopyKeeper?
    private var linkPreviewFetcher: LinkPreviewFetcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; the panel and its mouse monitors stay off for them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        Log.app.info("Polka launched")
        let locations = makeLocations()
        let store = makeStore(locations: locations)
        store.refreshReferences()

        // Before the sweeper, so a copy whose item expires while Polka was closed is
        // deleted right away.
        if let locations {
            let keeper = CopyKeeper(store: store, copies: ShelfCopies(folder: locations.copiesFolder))
            keeper.start()
            copyKeeper = keeper
        }

        let sweeper = ExpirySweeper(store: store)
        sweeper.start()
        expirySweeper = sweeper

        if let locations {
            let fetcher = LinkPreviewFetcher(store: store, previewsFolder: locations.previewsFolder)
            fetcher.start()
            linkPreviewFetcher = fetcher
        }

        let images = ShelfItemImages(previewsFolder: locations?.previewsFolder)
        let controller = NotchPanelController(store: store, images: images, copies: copyKeeper)
        controller.start()
        notchController = controller
    }

    /// Polka's Application Support folder. Without it Polka still runs, but the shelf
    /// only lasts until it quits, links get no saved previews, and nothing can be
    /// kept as a copy.
    private func makeLocations() -> ShelfLocations? {
        do {
            let locations = try ShelfLocations.standard()
            Log.storage.info("Shelf file: \(locations.shelfFile.path, privacy: .public)")
            return locations
        } catch {
            Log.storage.error("""
                No Application Support folder, so the shelf won't be saved: \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    private func makeStore(locations: ShelfLocations?) -> ShelfStore {
        guard let locations else { return ShelfStore() }
        return ShelfStore(persistence: JSONFileShelfPersistence(fileURL: locations.shelfFile))
    }
}
