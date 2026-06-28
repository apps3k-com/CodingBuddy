//
//  CredentialResetCopyTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Static coverage for the destructive credential reset strings required by issue #56.
struct CredentialResetCopyTests {
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

    /// Ensures all credential reset dialog keys have non-empty German translations.
    @Test func credentialResetDialogCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()
        let requiredKeys = [
            "Move credentials for “%@” to the Trash?",
            "Move Server Credentials to Trash",
            "Move all MCP credentials to the Trash?",
            "Move All MCP Credentials to Trash",
            "Every connected server will ask you to log in again.",
            "Move “%@” to the Trash?",
            "Move Secret File to Trash",
            "Move the encrypted credential store to the Trash?",
            "Move Credential Store to Trash",
            "Every Craft connector will ask you to log in again.",
            "The next connection will trigger a fresh OAuth login.",
            "Cancel"
        ]

        for key in requiredKeys {
            let translation = try germanTranslation(for: key, in: strings)
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
