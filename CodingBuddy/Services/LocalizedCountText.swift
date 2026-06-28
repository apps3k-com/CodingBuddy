//
//  LocalizedCountText.swift
//  CodingBuddy
//

import Foundation

/// Formats localized count labels that need explicit singular and plural copy.
nonisolated enum LocalizedCountText {
    /// Returns the localized variable count for navigation subtitles.
    static func variables(_ count: Int) -> String {
        countText(
            count,
            singular: String(localized: "1 variable"),
            pluralFormat: String(localized: "%lld variables")
        )
    }

    /// Returns the localized server count for navigation subtitles.
    static func servers(_ count: Int) -> String {
        countText(
            count,
            singular: String(localized: "1 server"),
            pluralFormat: String(localized: "%lld servers")
        )
    }

    /// Returns the localized file count for credential table rows.
    static func files(_ count: Int) -> String {
        countText(
            count,
            singular: String(localized: "1 file"),
            pluralFormat: String(localized: "%lld files")
        )
    }

    /// Returns the localized import action for the selected variable count.
    static func importVariables(_ count: Int) -> String {
        countText(
            count,
            singular: String(localized: "Import 1 Variable"),
            pluralFormat: String(localized: "Import %lld Variables")
        )
    }

    /// Chooses singular copy for exactly one and formats every other count with the plural template.
    static func countText(_ count: Int, singular: String, pluralFormat: String) -> String {
        guard count != 1 else { return singular }
        return String(format: pluralFormat, Int64(count))
    }
}
