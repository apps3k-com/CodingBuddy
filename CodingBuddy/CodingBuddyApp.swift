//
//  CodingBuddyApp.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// AppKit lifecycle bridge for best-effort expired snapshot cleanup on quit.
private final class CodingBuddyApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Removes only expired snapshots so a fresh Launch Services handoff can finish.
    func applicationWillTerminate(_ notification: Notification) {
        AgentContextScanner.cleanupExpiredPrivateSnapshots()
    }
}

/// Menu-bar equivalents for essential credential toolbar actions.
private struct CredentialCommands: Commands {
    @FocusedValue(\.mcpAuthCommandActions) private var actions
    @FocusedValue(\.secretLockCommandAction) private var secretLockAction
    /// Root command bridge used when no modal cleartext editor owns focus.
    let menuActions: MenuActions

    /// Context-sensitive commands enabled by the active MCP Auth view.
    var body: some Commands {
        CommandMenu("Credentials") {
            Button("View Credential Files…") {
                actions?.viewSelectedFiles?()
            }
            .disabled(actions?.viewSelectedFiles == nil)

            Button("Lock All Revealed Secrets") {
                if let secretLockAction {
                    secretLockAction()
                } else {
                    menuActions.lockSecretsRequest += 1
                }
            }

            Divider()

            Button("Show Credential Recovery in Finder") {
                actions?.showRecoveryFiles?()
            }
            .disabled(actions?.showRecoveryFiles == nil)

            Button("Reset All MCP Credentials…", role: .destructive) {
                actions?.resetAllCredentials?()
            }
            .disabled(actions?.resetAllCredentials == nil)
        }
    }
}

/// Context-sensitive import and export commands for the active shell-variable view.
private struct EnvironmentTransferCommands: Commands {
    @FocusedValue(\.envTransferCommandActions) private var actions

    /// Commands disappear behind the feature flag and remain disabled without a complete scope.
    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            if FeatureFlag.envImportExport.isEnabled {
                Button("Import from .env…") {
                    actions?.importEnvironment?()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.importEnvironment == nil)

                Button("Export visible as .env…") {
                    actions?.exportEnvironment?()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportEnvironment == nil)
            }
        }
    }
}

@main
/// Single-window macOS application entry point and command-menu owner.
struct CodingBuddyApp: App {
    @NSApplicationDelegateAdaptor(CodingBuddyApplicationDelegate.self) private var appDelegate
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @State private var menuActions = MenuActions()
    @Environment(\.openWindow) private var openWindow

    /// Migrates legacy settings before SwiftUI initializes persisted state.
    init() {
        // Before any store or @AppStorage reads: carry over settings and
        // backups from the pre-rename identity (apps3k.EnvVarBuddy).
        LegacyMigration.run()
        AgentContextScanner.cleanupExpiredPrivateSnapshots()
    }

    /// Product name — a proper noun, deliberately exempt from the String
    /// Catalog (passing a `String` value avoids LocalizedStringKey extraction).
    private static let productName = "CodingBuddy"

    /// Main utility window and application-level command groups.
    var body: some Scene {
        // A single-window utility: `Window` prevents a second instance whose
        // file watchers and writes would race against the first one.
        Window(Self.productName, id: "main") {
            ContentView()
                .environment(menuActions)
                .onChange(of: appearanceRaw, initial: true) {
                    AppearanceMode(rawValue: appearanceRaw)?.apply()
                }
        }
        .defaultSize(width: 820, height: 520)
        .commands {
            // Settings open as a sheet over the main window (instead of the
            // separate window a `Settings` scene would create), so the menu
            // item is provided manually.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "main")
                    menuActions.settingsRequested = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            EnvironmentTransferCommands()
            CredentialCommands(menuActions: menuActions)
            CommandGroup(replacing: .help) {
                Button("CodingBuddy Help") {
                    NSWorkspace.shared.open(HelpDestination.userGuide.url)
                }
                .keyboardShortcut("?", modifiers: .command)
                Button("Documentation (Wiki)") {
                    NSWorkspace.shared.open(HelpDestination.wiki.url)
                }
            }
        }
    }
}
