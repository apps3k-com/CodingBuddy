//
//  MenuActions.swift
//  CodingBuddy
//

import Foundation
import Observation
import SwiftUI

/// Bridges app-wide menu commands to the main window's view state.
@Observable
final class MenuActions {
    /// Monotonic request consumed by the root secret gate when no focused
    /// cleartext editor needs to resolve a draft first.
    var lockSecretsRequest = 0
    /// Consumed (reset to false) by the view when it presents the sheet — a
    /// counter would be missed when the main window is created right before
    /// the request, because onChange baselines on the already-bumped value.
    var settingsRequested = false
}

/// Context-sensitive MCP credential actions exposed to the macOS menu bar.
struct MCPAuthCommandActions {
    /// Opens the currently selected credential entry when one is selected.
    let viewSelectedFiles: (() -> Void)?
    /// Reveals the retained recovery transaction when one exists.
    let showRecoveryFiles: (() -> Void)?
    /// Presents the reset-all confirmation when the operation is available.
    let resetAllCredentials: (() -> Void)?
}

/// Context-sensitive environment transfer actions exposed by the active shell view.
struct EnvTransferCommandActions {
    /// Presents the importer when the active scope has complete source coverage.
    let importEnvironment: (() -> Void)?
    /// Authenticates as needed and exports the active, complete visible snapshot.
    let exportEnvironment: (() -> Void)?
}

private struct SecretLockCommandActionKey: FocusedValueKey {
    /// Context-sensitive lock action supplied by the focused cleartext editor.
    typealias Value = () -> Void
}

private struct MCPAuthCommandActionsKey: FocusedValueKey {
    /// Action bundle propagated from the focused credential-management scene.
    typealias Value = MCPAuthCommandActions
}

private struct EnvTransferCommandActionsKey: FocusedValueKey {
    /// Action bundle propagated from the active environment-variable scene.
    typealias Value = EnvTransferCommandActions
}

extension FocusedValues {
    /// Gives the focused editor first refusal over an app-wide secret lock so
    /// dirty cleartext is never discarded without an explicit choice.
    var secretLockCommandAction: (() -> Void)? {
        get { self[SecretLockCommandActionKey.self] }
        set { self[SecretLockCommandActionKey.self] = newValue }
    }

    /// MCP actions supplied by the active credential-management scene.
    var mcpAuthCommandActions: MCPAuthCommandActions? {
        get { self[MCPAuthCommandActionsKey.self] }
        set { self[MCPAuthCommandActionsKey.self] = newValue }
    }

    /// Import and export actions supplied only by a complete shell-variable scope.
    var envTransferCommandActions: EnvTransferCommandActions? {
        get { self[EnvTransferCommandActionsKey.self] }
        set { self[EnvTransferCommandActionsKey.self] = newValue }
    }
}

/// Wiki pages opened from the Help menu, mirrored per app language.
nonisolated enum HelpDestination {
    /// Localized end-user guide.
    case userGuide
    /// Wiki landing page for broader project documentation.
    case wiki

    private static var isGerman: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? false
    }

    /// Wiki URL resolved for the app's preferred language where applicable.
    var url: URL {
        let base = "https://github.com/apps3k-com/CodingBuddy/wiki"
        switch self {
        case .userGuide:
            let page = Self.isGerman ? "Benutzerhandbuch-DE" : "User-Guide-EN"
            return URL(string: "\(base)/\(page)")!
        case .wiki:
            return URL(string: base)!
        }
    }
}
