//
//  PRAttentionLocalizationTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Localization and accessibility coverage for issue #106's attention queue.
struct PRAttentionLocalizationTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var sourceURLs: [URL] {
        [
            "CodingBuddy/Models/PRAttentionQueue.swift",
            "CodingBuddy/Views/PRAttentionQueueView.swift",
        ].map { repositoryRoot.appendingPathComponent($0) }
    }

    private var catalogURL: URL {
        repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    @Test func namedAttentionCopyHasEnglishDefaultsAndGermanTranslations() throws {
        let defaults = try sourceDefaultValues()
        let strings = try catalogStrings()

        #expect(!defaults.isEmpty)
        for (key, english) in defaults where key.hasPrefix("Attention ") {
            #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(try germanValue(for: key, strings: strings).isEmpty == false)
        }
    }

    @Test func directAttentionInterfaceCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()
        let keys = [
            "Attention Queue",
            "Focus",
            "Open PR Monitor",
            "Open the full pull request monitor",
            "Refresh watched repositories",
            "Priority",
            "Why now",
            "Add a fine-grained read-only token before CodingBuddy can rank pull request work.",
            "No watched repositories",
            "Choose repositories in Agent PR Monitor to build your attention queue.",
            "Loading attention queue...",
            "Attention queue unavailable",
            "Some repository snapshots are not current. Other results remain available.",
            "No pull requests need sorting",
            "CodingBuddy did not find open pull requests in the current repository snapshots.",
            "Select a pull request",
            "Choose a queue row to understand its priority and recommended next action.",
            "Signal",
            "Recommended",
        ]

        for key in keys {
            #expect(try germanValue(for: key, strings: strings).isEmpty == false)
        }
    }

    @Test func inspectorAccessibilityFormatKeepsPositionalPlaceholders() throws {
        let key = "Attention inspector header accessibility label"
        let english = try #require(sourceDefaultValues()[key])
        let german = try germanValue(for: key, strings: catalogStrings())

        for placeholder in ["%1$@", "%2$lld", "%3$@", "%4$@"] {
            #expect(english.contains(placeholder))
            #expect(german.contains(placeholder))
        }
    }

    @Test func queueHeaderAndPriorityLabelsRemainVoiceOverSpecific() throws {
        let source = try String(contentsOf: sourceURLs[1], encoding: .utf8)

        #expect(source.contains(".accessibilityHint(Text(priority.explanation))"))
        #expect(source.contains(".accessibilityLabel(Text(headerAccessibilityLabel(for: item)))"))
        #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(source.contains("Attention inspector header accessibility label"))
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

    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    private func germanValue(
        for key: String,
        strings: [String: [String: Any]]
    ) throws -> String {
        let entry = try #require(strings[key])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let german = try #require(localizations["de"] as? [String: Any])
        let unit = try #require(german["stringUnit"] as? [String: Any])
        #expect(unit["state"] as? String == "translated")
        return try #require(unit["value"] as? String)
    }
}
