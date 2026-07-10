//
//  HealthGuidanceLocalizationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Keeps health and security guidance copy synchronized with the German String Catalog.
struct HealthGuidanceLocalizationTests {
    /// Repository root resolved from this synchronized test source.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Production sources that introduce or reuse localized guidance keys in issue #101.
    private var guidanceSourceURLs: [URL] {
        return [
            repositoryRoot.appendingPathComponent("CodingBuddy/Services/AgentDoctorGuidance.swift"),
            repositoryRoot.appendingPathComponent("CodingBuddy/Services/RepoReadinessGuidance.swift"),
            repositoryRoot.appendingPathComponent("CodingBuddy/Services/MCPServerGuidance.swift"),
            repositoryRoot.appendingPathComponent("CodingBuddy/Views/MCPServerInventoryView.swift"),
        ]
    }

    /// Repository-local String Catalog.
    private var localizableCatalogURL: URL {
        repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    /// Every literal `String(localized:)` key used by the guidance slice has German copy.
    @Test func healthGuidanceKeysHaveGermanTranslations() throws {
        let keys = try localizedKeys()
        let strings = try catalogStrings()

        #expect(keys.count >= 87)
        for key in keys {
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated")
            let value = try #require(unit["value"] as? String)
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Protects selected-item context for VoiceOver across all three guidance inspectors.
    @Test func guidanceInspectorsRetainAccessibleStatusHeaders() throws {
        let expectations = [
            (
                "CodingBuddy/Views/AgentDoctorView.swift",
                ["diagnostic.severity.localizedTitle", "diagnostic.title"]
            ),
            (
                "CodingBuddy/Views/MCPServerInventoryView.swift",
                ["item.inventoryConfigurationStatusTitle", "item.name"]
            ),
            (
                "CodingBuddy/Views/RepoReadinessView.swift",
                ["item.status.displayName", "item.title"]
            ),
        ]

        for (path, contextFragments) in expectations {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
            #expect(source.contains(".accessibilityLabel("))
            for fragment in contextFragments {
                #expect(source.contains(fragment))
            }
        }
    }

    /// Extracts only literal localization keys, avoiding a second manually maintained key list.
    private func localizedKeys() throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"localized:\s*\"([^\"]+)\""#)
        var keys = Set<String>()

        for url in guidanceSourceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        return keys
    }

    /// Loads raw String Catalog entries for key and translation-state checks.
    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: localizableCatalogURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(root?["strings"] as? [String: [String: Any]])
    }
}
