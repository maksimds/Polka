import AppKit
import Quartz

/// Right-click > Share: macOS's share popover, the one Finder shows for a file, with
/// AirDrop, Mail, Messages, Notes, people you share with often, and "Edit Extensions".
/// It points at the tile, as Finder's points at the icon.
///
/// Like Quick Look, it activates Polka. A share extension's window (Messages, Notes,
/// Reminders) is drawn in Polka's own process, and a window from an inactive app opens
/// behind the app you're in and can't take typing. Unlike Quick Look, the shelf stays
/// open meanwhile: the popover points at a tile on it, and the service you pick may
/// show itself in the same spot.
@MainActor
final class ShareController: NSObject {
    private let focus: FocusReturner
    /// Kept while its popover is up, rather than counting on AppKit to.
    private var picker: NSSharingServicePicker?
    private var resignObserver: NSObjectProtocol?

    /// True from `share` until the popover closes without a choice, or the service
    /// picked from it is done. The shelf stays open meanwhile.
    private(set) var isSharing = false
    /// Sharing is over, either way.
    var onFinished: (@MainActor () -> Void)?

    init(focus: FocusReturner) {
        self.focus = focus
        super.init()
        // A fallback for a service that never says it's done: once you've gone to
        // another app (or Mail has opened its message), sharing no longer holds the
        // shelf open.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(because: "Polka is no longer active") }
        }
    }

    /// Shows the popover for `objects` (see `objects(for:)`), pointing at `rect` in
    /// `view`, from below where there's room, since the shelf hangs from the top of the
    /// screen.
    func share(_ objects: [Any], from view: NSView, at rect: NSRect) {
        guard !objects.isEmpty, view.window != nil else { return }
        if !isSharing {
            isSharing = true
            focus.rememberFrontmostApp()
        }
        NSApp.activate()

        let picker = NSSharingServicePicker(items: objects)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        Log.app.debug("Share showing \(objects.count) item(s)")
    }

    /// What each item is to the share services: a file as the file Polka opens (a kept
    /// copy's original while it can be found, as with Quick Look), a link as its web
    /// address, and text as plain text, so Mail, Messages and Notes all take it.
    /// Links that aren't web addresses, saved before that rule, stay out, as they do
    /// for opening.
    nonisolated static func objects(for items: [ShelfItem]) -> [Any] {
        items.compactMap { item -> Any? in
            switch item.source {
            case .file:
                return item.urlToOpen()
            case .link(let url):
                return LinkInput.isWebAddress(url) ? url : nil
            case .text(let text):
                return text
            }
        }
    }

    // MARK: - Finishing

    /// Runs once per sharing, from whichever signal comes first.
    private func finish(because reason: String) {
        guard isSharing else { return }
        isSharing = false
        picker = nil
        Log.app.debug("Share finished: \(reason, privacy: .public)")
        // Settings or Quick Look, if open, keeps the focus. `handBack` does nothing if
        // another app already has it, such as Mail with a new message.
        if !isAnotherPolkaWindowOpen {
            focus.handBack(after: "Share")
        }
        onFinished?()
    }

    /// Settings and Quick Look. The share service's own window may still be on its way
    /// out at this point, so it doesn't count.
    private var isAnotherPolkaWindowOpen: Bool {
        NSApp.windows.contains { window in
            window.isVisible && (window.delegate is SettingsWindowController || window is QLPreviewPanel)
        }
    }
}

// MARK: - The popover and the service

// AppKit's sharing protocols aren't marked for the main thread. The popover is a
// window and only calls its delegate on it; the service makes no such promise, so its
// news hops over.

extension ShareController: NSSharingServicePickerDelegate {
    /// Called as the popover closes: with the service picked, or nil if it was
    /// dismissed (Esc, or a click elsewhere).
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            picker = nil
            guard let service else {
                finish(because: "dismissed")
                return
            }
            // Its title can be a person's name, from the row of people you share with.
            Log.app.debug("Sharing with \(service.title, privacy: .private)")
        }
    }

    /// Hears from the service itself, so the shelf knows when it's done.
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }
}

extension ShareController: NSSharingServiceDelegate {
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.finish(because: "shared") }
    }

    /// Cancelling the service's window counts as failing, with a "user cancelled" error.
    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any],
                                    error: any Error) {
        let code = error.logCode
        Task { @MainActor in
            Log.app.debug("Sharing ended without sharing: \(code, privacy: .public)")
            self.finish(because: "not shared")
        }
    }
}
