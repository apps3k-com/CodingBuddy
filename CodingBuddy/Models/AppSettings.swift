//
//  AppSettings.swift
//  CodingBuddy
//

import AppKit
import SwiftUI

/// Appearance preference stored in UserDefaults ("appearanceMode").
nonisolated enum AppearanceMode: String, CaseIterable {
    case auto
    case light
    case dark

    /// nil means "follow the system appearance".
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the preference app-wide. `NSApp.appearance` (unlike
    /// `preferredColorScheme`) resets every window to the system appearance
    /// when set back to nil.
    @MainActor func apply() {
        NSApp.appearance = nsAppearance
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

/// Default external editor preference for text-like repository files.
nonisolated enum DefaultTextEditorPreference: Equatable, Sendable {
    /// UserDefaults key for the selected editor bundle identifier.
    static let bundleIdentifierKey = "defaultTextEditorBundleIdentifier"
    /// UserDefaults key for the selected editor application path.
    static let applicationPathKey = "defaultTextEditorApplicationPath"
    /// UserDefaults key for the selected editor display name.
    static let displayNameKey = "defaultTextEditorDisplayName"

    /// Let Launch Services choose the app.
    case systemDefault
    /// Open text-like files with a selected macOS application.
    case application(bundleIdentifier: String?, applicationURL: URL, displayName: String)

    /// Loads the persisted editor preference.
    static func load(from defaults: UserDefaults = .standard) -> DefaultTextEditorPreference {
        fromStoredValues(
            bundleIdentifier: defaults.string(forKey: bundleIdentifierKey),
            applicationPath: defaults.string(forKey: applicationPathKey),
            displayName: defaults.string(forKey: displayNameKey)
        )
    }

    /// Builds a preference from raw values, trimming empty strings to the system default.
    static func fromStoredValues(
        bundleIdentifier: String?,
        applicationPath: String?,
        displayName: String?
    ) -> DefaultTextEditorPreference {
        let trimmedPath = applicationPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPath.isEmpty else { return .systemDefault }

        let trimmedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = trimmedDisplayName.flatMap { $0.isEmpty ? nil : $0 }
        return .application(
            bundleIdentifier: trimmedBundleIdentifier?.isEmpty == false ? trimmedBundleIdentifier : nil,
            applicationURL: URL(fileURLWithPath: trimmedPath),
            displayName: resolvedDisplayName
                ?? URL(fileURLWithPath: trimmedPath).deletingPathExtension().lastPathComponent
        )
    }

    /// Creates a preference for a selected application bundle.
    static func application(at url: URL) -> DefaultTextEditorPreference {
        .application(
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
            applicationURL: url,
            displayName: FileManager.default.displayName(atPath: url.path)
        )
    }

    /// Persists this preference into UserDefaults.
    func save(to defaults: UserDefaults = .standard) {
        switch self {
        case .systemDefault:
            Self.reset(in: defaults)
        case .application(let bundleIdentifier, let applicationURL, let displayName):
            defaults.set(bundleIdentifier ?? "", forKey: Self.bundleIdentifierKey)
            defaults.set(applicationURL.path, forKey: Self.applicationPathKey)
            defaults.set(displayName, forKey: Self.displayNameKey)
        }
    }

    /// Removes all persisted editor preference values.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bundleIdentifierKey)
        defaults.removeObject(forKey: applicationPathKey)
        defaults.removeObject(forKey: displayNameKey)
    }

    /// User-facing name for Settings.
    var displayName: String {
        switch self {
        case .systemDefault:
            String(localized: "System Default")
        case .application(_, _, let displayName):
            displayName
        }
    }
}
