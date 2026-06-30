//
//  AppSettingsTests.swift
//  CodingBuddyTests
//

import AppKit
import Testing
@testable import CodingBuddy

@MainActor
struct AppSettingsTests {

    @Test func lightMapsToAqua() {
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
    }

    @Test func darkMapsToDarkAqua() {
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func autoFollowsTheSystem() {
        // nil resets NSApp.appearance so the app tracks the system setting.
        #expect(AppearanceMode.auto.nsAppearance == nil)
    }

    @Test func defaultTextEditorFallsBackToSystemDefaultWithoutApplicationPath() {
        let preference = DefaultTextEditorPreference.fromStoredValues(
            bundleIdentifier: "com.example.Editor",
            applicationPath: "  ",
            displayName: "Example Editor"
        )

        #expect(preference == .systemDefault)
    }

    @Test func defaultTextEditorRestoresStoredApplicationMetadata() {
        let preference = DefaultTextEditorPreference.fromStoredValues(
            bundleIdentifier: "com.example.Editor",
            applicationPath: "/Applications/Example Editor.app",
            displayName: "Example Editor"
        )

        #expect(preference == .application(
            bundleIdentifier: "com.example.Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Example Editor.app"),
            displayName: "Example Editor"
        ))
    }

    @Test func defaultTextEditorPersistsAndResetsUserDefaultsValues() {
        let suiteName = "CodingBuddyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DefaultTextEditorPreference.application(
            bundleIdentifier: "com.example.Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Example Editor.app"),
            displayName: "Example Editor"
        )
        .save(to: defaults)

        #expect(DefaultTextEditorPreference.load(from: defaults) == .application(
            bundleIdentifier: "com.example.Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Example Editor.app"),
            displayName: "Example Editor"
        ))

        DefaultTextEditorPreference.reset(in: defaults)

        #expect(DefaultTextEditorPreference.load(from: defaults) == .systemDefault)
    }
}
