//
//  CredentialEmptyStateCopyTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Static coverage for the credential empty-state strings required by issue #58.
struct CredentialEmptyStateCopyTests {
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

    /// Ensures credential empty states explain how credentials appear next.
    @Test func credentialEmptyStateCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()
        let requiredKeys = [
            "Connect to a remote MCP server first. CodingBuddy will list cached OAuth credentials here after they exist.",
            "Connect to an MCP server that uses OAuth. Its cached credentials will appear here.",
            "Set up Craft Agents or connect a Craft connector. Credential files will appear here when Craft creates them."
        ]

        for key in requiredKeys {
            let translation = try germanTranslation(for: key, in: strings)
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        #expect(!strings.keys.contains("~/.mcp-auth does not exist — nothing to manage."))
    }
}
