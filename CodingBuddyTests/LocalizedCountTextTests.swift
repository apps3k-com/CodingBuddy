//
//  LocalizedCountTextTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Focused coverage for localized count labels used by navigation subtitles and import actions.
struct LocalizedCountTextTests {
    /// Finds the repository-local String Catalog from this test source file.
    private var localizableCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    /// Loads String Catalog entries as raw JSON dictionaries for focused key checks.
    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: localizableCatalogURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(root?["strings"] as? [String: [String: Any]])
    }

    /// Returns the German translation for a catalog key.
    private func germanTranslation(for key: String, in strings: [String: [String: Any]]) throws -> String {
        let entry = try #require(strings[key])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let german = try #require(localizations["de"] as? [String: Any])
        let unit = try #require(german["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }

    /// Verifies the shared count formatter chooses singular copy only for exactly one.
    @Test func countTextUsesSingularOnlyForOne() {
        #expect(
            LocalizedCountText.countText(
                0,
                singular: "1 variable",
                pluralFormat: "%lld variables"
            ) == "0 variables"
        )
        #expect(
            LocalizedCountText.countText(
                1,
                singular: "1 variable",
                pluralFormat: "%lld variables"
            ) == "1 variable"
        )
        #expect(
            LocalizedCountText.countText(
                2,
                singular: "1 variable",
                pluralFormat: "%lld variables"
            ) == "2 variables"
        )
    }

    /// Ensures every count label used by the UI has a non-empty German translation.
    @Test func countCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()
        let requiredKeys = [
            "1 variable",
            "%lld variables",
            "1 server",
            "%lld servers",
            "1 file",
            "%lld files",
            "Import 1 Variable",
            "Import %lld Variables"
        ]

        for key in requiredKeys {
            let translation = try germanTranslation(for: key, in: strings)
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
