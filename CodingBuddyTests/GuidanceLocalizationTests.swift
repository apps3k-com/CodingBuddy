//
//  GuidanceLocalizationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Focused coverage for the guidance inspector and developer glossary copy added by issue #99.
struct GuidanceLocalizationTests {
    /// Every new String Catalog key introduced by the guidance localization slice.
    private var newGuidanceKeys: [String] {
        [
            "What this means",
            "Why it matters",
            "What could happen",
            "Recommended next step",
            "Alternatives",
            "Technical details",
            "Show or hide technical evidence and glossary definitions.",
            "Evidence",
            "Glossary",
            "Expected result",
            "Effort",
            "Unavailable: %@",
            "Recommended. Expected result: %@",
            "Alternative. Expected result: %@",
            "Guidance effort low",
            "Guidance effort medium",
            "Guidance effort high",
            "Guidance safety read only",
            "Guidance safety reversible",
            "Guidance safety requires confirmation",
            "Developer glossary CI title",
            "Developer glossary CI definition",
            "Developer glossary PR title",
            "Developer glossary PR definition",
            "Developer glossary MCP title",
            "Developer glossary MCP definition",
            "Developer glossary OAuth title",
            "Developer glossary OAuth definition",
            "Developer glossary scope title",
            "Developer glossary scope definition",
            "Developer glossary dirty worktree title",
            "Developer glossary dirty worktree definition",
            "Developer glossary ahead behind title",
            "Developer glossary ahead behind definition",
            "Developer glossary package pin title",
            "Developer glossary package pin definition",
            "Developer glossary direct dependency title",
            "Developer glossary direct dependency definition"
        ]
    }

    /// Finds the repository-local String Catalog from this test source file.
    private var localizableCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    /// Finds the reusable inspector source for focused accessibility regression checks.
    private var guidanceInspectorSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodingBuddy/Views/GuidanceInspectorSection.swift")
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

    /// Ensures the focused key list remains complete and every key exists in the catalog.
    @Test func catalogContainsEveryNewGuidanceKey() throws {
        let strings = try catalogStrings()

        #expect(newGuidanceKeys.count == 38)
        #expect(Set(newGuidanceKeys).count == newGuidanceKeys.count)
        for key in newGuidanceKeys {
            #expect(strings[key] != nil)
        }
    }

    /// Ensures every new guidance key has a nonempty German translation.
    @Test func newGuidanceCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()

        for key in newGuidanceKeys {
            let translation = try germanTranslation(for: key, in: strings)
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Protects the native VoiceOver hierarchy without adding a view-introspection dependency.
    @Test func inspectorRetainsAccessibilityHeadingsAndHints() throws {
        let source = try String(contentsOf: guidanceInspectorSourceURL, encoding: .utf8)
        let headingTraitCount = source.components(separatedBy: ".accessibilityAddTraits(.isHeader)").count - 1

        #expect(headingTraitCount == 7)
        #expect(source.contains(
            ".accessibilityHint(Text(\"Show or hide technical evidence and glossary definitions.\"))"
        ))
        #expect(source.contains(
            ".accessibilityHint(Text(\"Recommended. Expected result: \\(action.expectedResult)\"))"
        ))
        #expect(source.contains(
            ".accessibilityHint(Text(\"Alternative. Expected result: \\(action.expectedResult)\"))"
        ))
    }
}
