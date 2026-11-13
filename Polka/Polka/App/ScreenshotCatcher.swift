import AppKit
import Combine

/// "Save Screenshots to Polka" in Settings (FR-20). While it's on, macOS saves new
/// screenshots and screen recordings into Polka's own folder instead of the Desktop,
/// and each one goes on the shelf as a temporary item.
///
/// It works through macOS's own setting: the save location that the Screenshot
/// toolbar (Cmd-Shift-5) sets under Options, stored as `location` in
/// `com.apple.screencapture`. Turning it on points that at `inbox` and remembers where
/// it pointed before; turning it off puts that back. Whether it's on is read from
/// macOS's setting each time, so if another location is picked in the toolbar, it
/// shows as off. Polka never watches the Desktop, so macOS never asks for access to it.
///
/// Each file that arrives is moved on into a copy folder of its own, like a promised
/// file, and marked as a screenshot, so it goes to the Trash rather than being deleted
/// when it expires or is removed (see `CopyKeeper`). Files that arrived while Polka
/// wasn't running are picked up when it starts.
@MainActor
final class ScreenshotCatcher: ObservableObject {
    /// macOS's screenshot settings, and the key for where screenshots are saved.
    static let systemDomain = "com.apple.screencapture"
    static let locationKey = "location"
    /// In Polka's own settings: where screenshots were saved before this was turned
    /// on. Empty means macOS's default, the Desktop.
    static let previousLocationKey = "screenshotsPreviousLocation"

    @Published private(set) var isEnabled = false
    /// Where screenshots go without Polka, for Settings: "the Desktop" or a folder's name.
    @Published private(set) var usualLocationName = "the Desktop"

    /// Told about screenshots just put on the shelf.
    var onAdded: (@MainActor (Set<ShelfItem.ID>) -> Void)?

    /// The folder macOS saves into while this is on.
    let inbox: URL
    private let store: ShelfStore
    private let copies: ShelfCopies
    private let system: UserDefaults
    private let defaults: UserDefaults
    private let lifetime: () -> TimeInterval
    /// How long a file has to sit unchanged before it's taken, in case macOS is still
    /// writing it.
    private let settleTime: TimeInterval
    private var watcher: DispatchSourceFileSystemObject?
    private var sweepTask: Task<Void, Never>?

    init(store: ShelfStore,
         copies: ShelfCopies,
         inbox: URL,
         system: UserDefaults,
         defaults: UserDefaults = .standard,
         lifetime: @escaping () -> TimeInterval = { ShelfSettings().temporaryLifetime },
         settleTime: TimeInterval = 0.5) {
        self.store = store
        self.copies = copies
        self.inbox = inbox
        self.system = system
        self.defaults = defaults
        self.lifetime = lifetime
        self.settleTime = settleTime
    }

    func start() {
        refresh()
        // Screenshots taken while Polka wasn't running.
        sweep()
    }

    /// Reads macOS's setting again, since it can be changed in the Screenshot toolbar.
    /// Called when Settings opens.
    func refresh() {
        let location = system.string(forKey: Self.locationKey)
        let enabled = Self.isSameFolder(location, as: inbox)
        if enabled != isEnabled {
            isEnabled = enabled
        }
        if enabled {
            watch()
            usualLocationName = Self.displayName(of: defaults.string(forKey: Self.previousLocationKey))
        } else {
            stopWatching()
            // Another location was picked in the toolbar, or none was ever changed:
            // that's where screenshots go now, and there's nothing to put back.
            defaults.removeObject(forKey: Self.previousLocationKey)
            usualLocationName = Self.displayName(of: location)
        }
    }

    /// The switch in Settings.
    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != isEnabled else { return }
        if enabled {
            turnOn()
        } else {
            turnOff()
        }
        refresh()
    }

    private func turnOn() {
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            Log.app.error("No folder for screenshots: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            return
        }
        defaults.set(system.string(forKey: Self.locationKey) ?? "", forKey: Self.previousLocationKey)
        system.set(inbox.path, forKey: Self.locationKey)
        Log.app.info("Screenshots now go to the shelf")
    }

    private func turnOff() {
        // Anything that has just arrived still goes on the shelf.
        sweep()
        let previous = defaults.string(forKey: Self.previousLocationKey) ?? ""
        if previous.isEmpty || Self.isSameFolder(previous, as: inbox) {
            // macOS's default: the Desktop.
            system.removeObject(forKey: Self.locationKey)
        } else {
            system.set(previous, forKey: Self.locationKey)
        }
        defaults.removeObject(forKey: Self.previousLocationKey)
        Log.app.info("Screenshots go back to where they went before")
    }

    // MARK: - Watching the folder

    /// A folder reports a change whenever a file in it is added, removed or renamed.
    private func watch() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let descriptor = open(inbox.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.app.error("Can't watch the screenshots folder, error \(errno, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func folderChanged() {
        // The folder itself was deleted or moved away: watch a new one in its place.
        if let events = watcher?.data, !events.isDisjoint(with: [.delete, .rename]) {
            stopWatching()
            watch()
        }
        scheduleSweep()
    }

    /// Waits for the folder to settle first: several changes in a row are one sweep.
    private func scheduleSweep() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self, settleTime] in
            try? await Task.sleep(for: .seconds(settleTime))
            guard !Task.isCancelled else { return }
            self?.sweep()
        }
    }

    /// Moves every file that has finished arriving onto the shelf, newest first, as
    /// temporary items. One still being written is left for a moment and tried again.
    func sweep() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox,
                                                                        includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return }
        let now = Date()
        var arrived: [(file: URL, created: Date)] = []
        var isStillArriving = false
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            // A file dated in the future (a clock set wrong) counts as arrived.
            if let modified = values.contentModificationDate,
               case let age = now.timeIntervalSince(modified), age >= 0, age < settleTime {
                isStillArriving = true
                continue
            }
            arrived.append((file, values.creationDate ?? .distantPast))
        }
        if isStillArriving {
            scheduleSweep()
        }
        guard !arrived.isEmpty else { return }

        let lifetime = lifetime()
        // The first draft becomes the first tile.
        let drafts = arrived.sorted { $0.created > $1.created }.compactMap { arrival -> ShelfItem.Draft? in
            do {
                var draft = ShelfItem.Draft(fileURL: try copies.moveIn(arrival.file), storageMode: .copy)
                draft.origin = .screenshot
                draft.lifetime = lifetime
                return draft
            } catch {
                Log.app.error("""
                    Couldn't put a screenshot on the shelf: \(error.logCode, privacy: .public), \
                    \(error.localizedDescription, privacy: .private)
                    """)
                return nil
            }
        }
        let added = store.add(drafts).added
        guard !added.isEmpty else { return }
        Log.app.info("Put \(added.count) screenshot(s) on the shelf")
        onAdded?(Set(added.map(\.id)))
    }

    // MARK: - Locations

    /// True when a location from macOS's setting is `folder`, however it's written:
    /// with "~", or a slash at the end.
    static func isSameFolder(_ location: String?, as folder: URL) -> Bool {
        guard let location, !location.isEmpty else { return false }
        let expanded = (location as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// "the Desktop" for macOS's default or the Desktop itself, otherwise the folder's
    /// name as Finder shows it.
    static func displayName(of location: String?) -> String {
        guard let location, !location.isEmpty else { return "the Desktop" }
        let path = URL(fileURLWithPath: (location as NSString).expandingTildeInPath).standardizedFileURL.path
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL.path
        if path == desktop { return "the Desktop" }
        return FileManager.default.displayName(atPath: path)
    }
}
