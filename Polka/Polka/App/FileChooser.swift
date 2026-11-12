import AppKit

/// The standard Open dialog, for "Add New", "File": the same one apps and websites
/// show when you choose a file.
@MainActor
final class FileChooser {
    private let focus: FocusReturner
    /// The dialog while it's open, so choosing "File" again brings it forward.
    private var openPanel: NSOpenPanel?

    init(focus: FocusReturner) {
        self.focus = focus
    }

    /// Shows the dialog. `add` gets what was chosen, and isn't called on Cancel.
    func choose(then add: @escaping @MainActor ([URL]) -> Void) {
        if let openPanel {
            NSApp.activate()
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        focus.rememberFrontmostApp()

        let panel = NSOpenPanel()
        // Folders too, and several at once, as when dragging them in.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders to add to the shelf."
        openPanel = panel

        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.openPanel = nil
                let urls = response == .OK ? panel.urls : []
                Log.app.debug("Open dialog closed with \(urls.count) item(s)")
                self?.finish()
                if !urls.isEmpty { add(urls) }
            }
        }
        panel.orderFrontRegardless()
    }

    /// If Settings is open too, it keeps the focus, as after Quick Look.
    private func finish() {
        let settingsIsOpen = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSOpenPanel)
        }
        if !settingsIsOpen {
            focus.handBack(after: "Open dialog")
        }
    }
}
