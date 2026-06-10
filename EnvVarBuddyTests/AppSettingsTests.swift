//
//  AppSettingsTests.swift
//  EnvVarBuddyTests
//

import AppKit
import Testing
@testable import EnvVarBuddy

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
}
