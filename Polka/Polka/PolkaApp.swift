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
    @StateObject private var loginItem = LoginItem()

    var body: some Scene {
        MenuBarExtra("Polka", systemImage: "tray.full") {
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
}
