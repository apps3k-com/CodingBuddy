//
//  WorkflowMaintenanceGuidanceLocalizationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Localization and accessibility coverage for the issue #100 guidance surfaces.
struct WorkflowMaintenanceGuidanceLocalizationTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var sourceURLs: [URL] {
        [
            "CodingBuddy/Services/AgentPRGuidance.swift",
            "CodingBuddy/Services/PackageMaintenanceGuidance.swift",
            "CodingBuddy/Views/AgentPRMonitorView.swift",
            "CodingBuddy/Views/PackageMaintenanceView.swift",
        ].map { repositoryRoot.appendingPathComponent($0) }
    }

    private var localizableCatalogURL: URL {
        repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    private func scopedLocalizedKeys() throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"localized:\s*"([^"]+)""#)
        var keys = Set<String>()

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                if key.hasPrefix("Agent PR guidance")
                    || key.hasPrefix("Agent PR inspector")
                    || key.hasPrefix("Package guidance") {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: localizableCatalogURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(root?["strings"] as? [String: [String: Any]])
    }

    @Test func everyWorkflowAndMaintenanceGuidanceKeyHasGermanCopy() throws {
        let keys = try scopedLocalizedKeys()
        let strings = try catalogStrings()

        #expect(keys.count == 139)
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

    @Test func dynamicAccessibilityLabelsUseLocalizedPositionalFormats() throws {
        let strings = try catalogStrings()
        let expectedFormats = [
            "Agent PR inspector header accessibility label": ["%1$lld", "%2$@", "%3$@"],
            "Package guidance inspector header accessibility label": ["%1$@", "%2$@"],
        ]

        for (key, placeholders) in expectedFormats {
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            let value = try #require(unit["value"] as? String)
            for placeholder in placeholders {
                #expect(value.contains(placeholder))
            }
        }
    }

    @Test func bothInspectorsRetainVoiceOverHeadersAndFeatureGates() throws {
        let agentSource = try String(contentsOf: sourceURLs[2], encoding: .utf8)
        let packageSource = try String(contentsOf: sourceURLs[3], encoding: .utf8)

        for source in [agentSource, packageSource] {
            #expect(source.contains("FeatureFlag.explainableGuidance.isEnabled"))
            #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        }
        #expect(agentSource.contains("Agent PR inspector header accessibility label"))
        #expect(packageSource.contains("Package guidance inspector header accessibility label"))
    }
}
