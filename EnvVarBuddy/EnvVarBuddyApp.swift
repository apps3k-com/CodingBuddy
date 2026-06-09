//
//  EnvVarBuddyApp.swift
//  EnvVarBuddy
//

import SwiftUI

@main
struct EnvVarBuddyApp: App {
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceRaw)?.colorScheme
    }

    var body: some Scene {
        // A single-window utility: `Window` prevents a second instance whose
        // file watchers and writes would race against the first one.
        Window("EnvVarBuddy", id: "main") {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 820, height: 520)

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }
}
