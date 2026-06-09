//
//  EnvVarBuddyApp.swift
//  EnvVarBuddy
//

import AppKit
import SwiftUI

@main
struct EnvVarBuddyApp: App {
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @State private var menuActions = MenuActions()

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceRaw)?.colorScheme
    }

    var body: some Scene {
        // A single-window utility: `Window` prevents a second instance whose
        // file watchers and writes would race against the first one.
        Window("EnvVarBuddy", id: "main") {
            ContentView()
                .environment(menuActions)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 820, height: 520)
        .commands {
            CommandGroup(replacing: .importExport) {
                if FeatureFlag.envImportExport.isEnabled {
                    Button("Import from .env…") { menuActions.importRequest += 1 }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    Button("Export visible as .env…") { menuActions.exportRequest += 1 }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                }
            }
            CommandGroup(replacing: .help) {
                Button("EnvVarBuddy Help") {
                    NSWorkspace.shared.open(HelpDestination.userGuide.url)
                }
                .keyboardShortcut("?", modifiers: .command)
                Button("Documentation (Wiki)") {
                    NSWorkspace.shared.open(HelpDestination.wiki.url)
                }
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }
}
