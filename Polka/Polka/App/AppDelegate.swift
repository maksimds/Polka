import AppKit
import Quartz

/// Builds the shelf and the helpers around it, then starts the notch panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?
    private var expirySweeper: ExpirySweeper?
    private var copyKeeper: CopyKeeper?
    private var linkPreviewFetcher: LinkPreviewFetcher?
    private var settingsWindow: SettingsWindowController?

    /// One switch shared by the menu bar menu and the Settings window, so they always agree.
    private(set) lazy var loginItem = LoginItem()
    /// Shared by Settings, Quick Look and the Open dialog, the windows that take focus.
    private lazy var focus = FocusReturner()
    private lazy var quickLook = QuickLookController(focus: focus)
    private lazy var fileChooser = FileChooser(focus: focus)

    func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController(loginItem: loginItem, focus: focus)
        settingsWindow = controller
        controller.show()
    }

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
        let controller = NotchPanelController(store: store,
                                              images: images,
                                              copies: copyKeeper,
                                              quickLook: quickLook,
                                              fileChooser: fileChooser,
                                              openSettings: { [weak self] in self?.showSettings() })
        controller.start()
        notchController = controller
    }

    // MARK: - Quick Look control

    // Quick Look asks down the responder chain for an object to supply its files,
    // starting at the key window. Polka's panels never become key, so the question
    // reaches the end of the chain: the app delegate. SwiftUI's own app delegate
    // passes it on to this one, and this one to the Quick Look controller.

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook.isOpen }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.beginControl(panel) }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.endControl(panel) }
    }

    /// Polka's Application Support folder. Without it Polka still runs, but the shelf
    /// only lasts until it quits, links get no saved previews, and nothing can be
    /// kept as a copy.
    private func makeLocations() -> ShelfLocations? {
        do {
            let locations = try ShelfLocations.standard()
            Log.storage.info("Shelf file: \(locations.shelfFile.path, privacy: .private)")
            return locations
        } catch {
            Log.storage.error("""
                No Application Support folder, so the shelf won't be saved: \
                \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)
                """)
            return nil
        }
    }

    private func makeStore(locations: ShelfLocations?) -> ShelfStore {
        let sort = ShelfSettings().shelfSort
        guard let locations else { return ShelfStore(sort: sort) }
        return ShelfStore(persistence: JSONFileShelfPersistence(fileURL: locations.shelfFile), sort: sort)
    }
}
