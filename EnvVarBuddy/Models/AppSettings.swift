//
//  AppSettings.swift
//  EnvVarBuddy
//

import SwiftUI

/// Appearance preference stored in UserDefaults ("appearanceMode").
nonisolated enum AppearanceMode: String, CaseIterable {
    case auto
    case light
    case dark

    /// nil means "follow the system appearance".
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Display language preference stored in UserDefaults ("appLanguage").
/// Applied via the standard AppleLanguages per-app override, which takes
/// effect on the next launch.
nonisolated enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case german = "de"

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
