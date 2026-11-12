import AppKit
import Combine

/// Removes temporary items once their time is up: at launch, when the next item is
/// due, and after the Mac wakes, because timers don't run while it sleeps.
@MainActor
final class ExpirySweeper {
    private let store: ShelfStore
    private var timer: Timer?
    private var nextExpiryWatcher: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?

    init(store: ShelfStore) {
        self.store = store
    }

    func start() {
        sweep()
        nextExpiryWatcher = store.$items
            .map { items in items.compactMap(\.expiresAt).min() }
            .removeDuplicates()
            .sink { [weak self] nextExpiry in self?.schedule(at: nextExpiry) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    func sweep() {
        let removed = store.removeExpired()
        if !removed.isEmpty {
            Log.storage.info("Removed \(removed.count) expired item(s)")
        }
    }

    private func schedule(at date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
