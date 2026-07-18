//
//  CapabilityHygieneLocalizationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Keeps analyzer finding copy synchronized with the German String Catalog.
nonisolated struct CapabilityHygieneLocalizationTests {
    /// Repository root resolved from this synchronized test source.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every analyzer finding message has translated German copy.
    @Test func analyzerFindingCopyHasGermanTranslations() throws {
        let analyzerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "CodingBuddy/Services/CapabilityHygieneAnalyzer.swift"
            ),
            encoding: .utf8
        )
        let strings = try catalogStrings()
        let expectedKeys = [
            "Capability hygiene exact duplicate explanation",
            "Capability hygiene exact duplicate recommendation",
            "Capability hygiene shadowing explanation format",
            "Capability hygiene shadowing recommendation",
            "Capability hygiene possible overlap explanation format",
            "Capability hygiene possible overlap recommendation",
        ]

        for key in expectedKeys {
            #expect(analyzerSource.contains("localized: \"\(key)\""))
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated")
            let value = try #require(unit["value"] as? String)
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Dynamic German messages retain the rule identifier and token-count placeholders.
    @Test func analyzerFindingFormatsRetainGermanPlaceholders() throws {
        let strings = try catalogStrings()

        let shadowing = try germanValue(
            for: "Capability hygiene shadowing explanation format",
            strings: strings
        )
        let overlap = try germanValue(
            for: "Capability hygiene possible overlap explanation format",
            strings: strings
        )

        #expect(shadowing.contains("%1$@"))
        #expect(overlap.contains("%1$lld"))
    }

    /// Loads raw String Catalog entries for key and translation-state checks.
    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    /// Returns one translated German catalog value.
    private func germanValue(
        for key: String,
        strings: [String: [String: Any]]
    ) throws -> String {
        let entry = try #require(strings[key])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let german = try #require(localizations["de"] as? [String: Any])
        let unit = try #require(german["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }
}
