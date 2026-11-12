import AppKit
import Quartz

/// Shows files in macOS's Quick Look panel, as pressing Space does in Finder: the
/// arrow keys move through several files, and Space or Esc closes it.
@MainActor
final class QuickLookController: NSObject {
    private let focus: FocusReturner
    /// What Quick Look is showing, or last showed.
    private var files: [URL] = []
    private var closeObserver: NSObjectProtocol?

    /// True from `show` until Quick Look closes.
    private(set) var isOpen = false

    init(focus: FocusReturner) {
        self.focus = focus
        super.init()
    }

    func show(_ files: [URL]) {
        guard !files.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.files = files
        if !isOpen {
            isOpen = true
            focus.rememberFrontmostApp()
        }
        NSApp.activate()
        observeClose(of: panel)

        if panel.isVisible {
            // Already open: show the new files in it.
            panel.updateController()
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.currentPreviewItemIndex = 0
        panel.orderFrontRegardless()
    }

    // MARK: - Control, passed on by the app delegate

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        Log.app.debug("Quick Look showing \(self.files.count) file(s)")
    }

    /// Quick Look lets go of its controller as it closes.
    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        // Checked a moment later, once the panel has actually gone.
        DispatchQueue.main.async { [weak self] in
            if !panel.isVisible { self?.finish() }
        }
    }

    // MARK: - Closing

    private func observeClose(of panel: QLPreviewPanel) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// Runs once per opening, from whichever closing signal comes first.
    private func finish() {
        guard isOpen else { return }
        isOpen = false
        // If Settings is open too, it keeps the focus.
        let settingsIsOpen = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is QLPreviewPanel)
        }
        if !settingsIsOpen {
            focus.handBack(after: "Quick Look")
        }
    }
}

// Quick Look's protocols aren't marked for the main thread, but the panel is a
// window and only ever calls these on it.

extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { files.indices.contains(index) ? files[index] as NSURL : nil }
    }
}

extension QuickLookController: QLPreviewPanelDelegate {
    /// Space closes it again, as in Finder. Esc and the arrow keys are built in.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
            panel.close()
            return true
        }
    }
}
