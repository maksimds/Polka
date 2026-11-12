import SwiftUI

@main
struct PolkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Polka", systemImage: "tray.full") {
            MenuBarMenu(loginItem: appDelegate.loginItem,
                        openSettings: { appDelegate.showSettings() })
        }
        .commands {
            // Polka's own menu bar shows while it's the active app (after a click on its
            // Dock icon, or Cmd-Tab). Settings isn't a SwiftUI Settings scene, so SwiftUI
            // leaves the usual Settings… item out of the Polka menu; this puts it back.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

/// The menu under Polka's menu bar icon.
private struct MenuBarMenu: View {
    @ObservedObject var loginItem: LoginItem
    let openSettings: @MainActor () -> Void

    var body: some View {
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        // A Toggle in a menu shows up as a checkmark item.
        Toggle("Open at Login", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))
        Divider()
        Button("Quit Polka") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
