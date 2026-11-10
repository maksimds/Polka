import AppKit
import Combine
import ServiceManagement

/// Whether Polka opens by itself when you log in.
///
/// macOS stores this, not Polka: it's the same switch as Polka's row under
/// System Settings > General > Login Items, so either place can change it. Polka
/// reads the current state again whenever one of its menus opens.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false

    private let service = SMAppService.mainApp
    private var menuObserver: AnyCancellable?

    init() {
        refresh()
        menuObserver = NotificationCenter.default
            .publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.app.info("Open at login \(enabled ? "on" : "off", privacy: .public)")
        } catch {
            Log.app.error("""
                Couldn't turn open at login \(enabled ? "on" : "off", privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        refresh()

        // Turned off earlier in System Settings: macOS only lets it come back on
        // from there, so open that page instead of failing silently.
        if enabled, service.status == .requiresApproval {
            Log.app.info("Open at login needs approval, opening Login Items settings")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
