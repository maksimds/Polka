//
//  PolkaApp.swift
//  Polka
//
//  Created by Denis on 7/11/26.
//

import SwiftUI

@main
struct PolkaApp: App {
    var body: some Scene {
        MenuBarExtra("Polka", systemImage: "tray.full") {
            Button("Quit Polka") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
