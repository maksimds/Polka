//
//  PolkaApp.swift
//  Polka
//
//  Created by Denis on 7/11/26.
//

import SwiftUI

@main
struct PolkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Polka", systemImage: "tray.full") {
            MenuBarMenu(loginItem: appDelegate.loginItem,
                        openSettings: { appDelegate.showSettings() })
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
