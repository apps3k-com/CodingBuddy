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

    private func catalogRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: localizableCatalogURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(root)
    }

    private func catalogStrings() throws -> [String: [String: Any]] {
        try #require(catalogRoot()["strings"] as? [String: [String: Any]])
    }

    private func sourceDefaultValues() throws -> [String: String] {
        let expression = try NSRegularExpression(
            pattern: #"localized:\s*\"([^\"]+)\"\s*,\s*defaultValue:\s*\"((?:\\.|[^\"\\])*)\""#
        )
        var values: [String: String] = [:]
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source),
                      let valueRange = Range(match.range(at: 2), in: source) else { continue }
                values[String(source[keyRange])] = String(source[valueRange])
            }
        }
        return values
    }

    @Test func everyWorkflowAndMaintenanceGuidanceKeyHasEnglishAndGermanCopy() throws {
        let keys = try scopedLocalizedKeys()
        let strings = try catalogStrings()
        let englishDefaults = try sourceDefaultValues()

        #expect(!keys.isEmpty)
        #expect(try catalogRoot()["sourceLanguage"] as? String == "en")
        for key in keys {
            let english = try #require(englishDefaults[key])
            #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let englishDefaults = try sourceDefaultValues()
        let expectedFormats = [
            "Agent PR inspector header accessibility label": ["%1$lld", "%2$@", "%3$@"],
            "Package guidance inspector header accessibility label": ["%1$@", "%2$@"],
        ]

        for (key, placeholders) in expectedFormats {
            let english = try #require(englishDefaults[key])
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            let value = try #require(unit["value"] as? String)
            for placeholder in placeholders {
                #expect(english.contains(placeholder))
                #expect(value.contains(placeholder))
            }
        }
    }

    @Test func bothInspectorsRetainVoiceOverHeadersAndFeatureGates() throws {
        let agentSource = try String(contentsOf: sourceURLs[2], encoding: .utf8)
        let packageSource = try String(contentsOf: sourceURLs[3], encoding: .utf8)

        let agentHeader = try #require(agentSource.slice(
            from: "@ViewBuilder private var inspectorHeader",
            to: "private var headerContent"
        ))
        let agentLabel = try #require(agentSource.slice(
            from: "private var headerAccessibilityLabel",
            to: "/// Route availability used to prevent the guidance component"
        ))
        let packageHeader = try #require(packageSource.slice(
            from: "@ViewBuilder\n    private var packageHeader",
            to: "private var packageHeaderContent"
        ))
        let packageLabel = try #require(packageSource.slice(
            from: "private var guidanceHeaderAccessibilityLabel",
            to: "private var statusExplanation"
        ))

        #expect(agentHeader.contains("FeatureFlag.explainableGuidance.isEnabled"))
        #expect(agentHeader.contains(".accessibilityElement(children: .combine)"))
        #expect(agentHeader.contains(".accessibilityLabel(Text(headerAccessibilityLabel))"))
        #expect(agentHeader.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(agentLabel.contains("Agent PR inspector header accessibility label"))
        #expect(packageHeader.contains("if guidance != nil"))
        #expect(packageHeader.contains(".accessibilityElement(children: .combine)"))
        #expect(packageHeader.contains(
            ".accessibilityLabel(Text(verbatim: guidanceHeaderAccessibilityLabel))"
        ))
        #expect(packageHeader.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(packageLabel.contains("Package guidance inspector header accessibility label"))
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
              let end = range(of: endMarker, range: start..<endIndex)?.lowerBound else {
            return nil
        }
        return String(self[start..<end])
    }
}
