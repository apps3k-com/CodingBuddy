//
//  MenuActions.swift
//  EnvVarBuddy
//

import Foundation
import Observation

/// Bridges menu-bar commands to the main window's view state. Commands bump a
/// counter; the variable list observes the counters and runs the action.
@Observable
final class MenuActions {
    var importRequest = 0
    var exportRequest = 0
    var settingsRequest = 0
}

/// Wiki pages opened from the Help menu, mirrored per app language.
nonisolated enum HelpDestination {
    case userGuide
    case wiki

    private static var isGerman: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? false
    }

    var url: URL {
        let base = "https://github.com/apps3k-com/EnvVarBuddy/wiki"
        switch self {
        case .userGuide:
            let page = Self.isGerman ? "Benutzerhandbuch-DE" : "User-Guide-EN"
            return URL(string: "\(base)/\(page)")!
        case .wiki:
            return URL(string: base)!
        }
    }
}
