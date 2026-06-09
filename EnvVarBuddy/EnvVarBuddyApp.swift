//
//  EnvVarBuddyApp.swift
//  EnvVarBuddy
//

import SwiftUI

@main
struct EnvVarBuddyApp: App {
    var body: some Scene {
        // A single-window utility: `Window` prevents a second instance whose
        // file watchers and writes would race against the first one.
        Window("EnvVarBuddy", id: "main") {
            ContentView()
        }
        .defaultSize(width: 820, height: 520)
    }
}
