//
//  SecretsTerminologyTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing

/// Regression coverage for the German developer-facing `Secrets` terminology.
struct SecretsTerminologyTests {
    /// German terms that should not represent developer secrets in interface copy.
    private var bannedGermanSecretTerms: [String] {
        [
            "Geheimnis",
            "Geheimwert",
            "geheime Werte",
            "geheimnisartig"
        ]
    }

    /// Finds the repository-local String Catalog from this test source file.
    private var localizableCatalogURL: URL {
        repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
    }

    /// Finds the German user guide source in the repository wiki docs.
    private var germanUserGuideURL: URL {
        repositoryRoot.appendingPathComponent("docs/wiki/Benutzerhandbuch-DE.md")
    }

    /// Resolves the repository root relative to this test source file.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    /// Verifies no banned German secret terminology appears in a text value.
    private func expectNoBannedSecretTerms(in text: String) {
        for term in bannedGermanSecretTerms {
            #expect(!text.localizedStandardContains(term))
        }
    }

    /// Ensures German UI copy keeps `Secrets` as the domain term.
    @Test func germanSecretUiCopyUsesDeveloperTerm() throws {
        let strings = try catalogStrings()
        let keys = [
            "Hide secrets",
            "Keep secrets revealed for",
            "Reveal secrets",
            "Values that look like secrets (TOKEN, KEY, PASSWORD, …) are masked until you authenticate with Touch ID or your password.",
            "reveal secret values"
        ]

        for key in keys {
            let translation = try germanTranslation(for: key, in: strings)
            #expect(translation.contains("Secret"))
            expectNoBannedSecretTerms(in: translation)
        }
    }

    /// Ensures no German String Catalog value regresses to literal secret wording.
    @Test func germanCatalogCopyAvoidsLiteralSecretTerms() throws {
        let strings = try catalogStrings()

        for entry in strings.values {
            let localizations = entry["localizations"] as? [String: Any]
            let german = localizations?["de"] as? [String: Any]
            let unit = german?["stringUnit"] as? [String: Any]
            guard let translation = unit?["value"] as? String else { continue }

            expectNoBannedSecretTerms(in: translation)
        }
    }

    /// Ensures German documentation uses the same developer-facing terminology.
    @Test func germanUserGuideUsesSecretsTerminology() throws {
        let text = try String(contentsOf: germanUserGuideURL, encoding: .utf8)

        #expect(text.contains("## Secrets bleiben maskiert"))
        #expect(text.contains("zeigt keine Secret-Werte an"))
        #expect(text.contains("Secret-Werte werden nie angezeigt"))
        #expect(text.contains("Werte, die wie Secrets aussehen"))
        #expect(text.contains("wie lange Secrets nach der Authentifizierung sichtbar bleiben"))
        expectNoBannedSecretTerms(in: text)
    }

    /// Ensures the long reveal duration names CodingBuddy explicitly.
    @Test func unlockDurationCopyNamesCodingBuddy() throws {
        let strings = try catalogStrings()
        let text = try String(contentsOf: germanUserGuideURL, encoding: .utf8)

        #expect(try germanTranslation(for: "Until CodingBuddy quits", in: strings) == "Bis CodingBuddy beendet wird")
        #expect(!strings.keys.contains("Until quit"))
        #expect(text.contains("bis CodingBuddy beendet wird"))
        #expect(!text.localizedCaseInsensitiveContains("bis zum Beenden"))
    }
}
