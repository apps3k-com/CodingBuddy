//
//  GitHubProjectsUXRegressionTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Source and String Catalog contracts for the GitHub Projects UX safety pass.
nonisolated struct GitHubProjectsUXRegressionTests {
    /// Repository root derived without reading user configuration or dotfiles.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Critical copy introduced or previously missed by the generic source extractor.
    private let criticalKeys = [
        "Search Project items",
        "Confirm Project move",
        "Type",
        "Title",
        "Lifecycle policy requires configuration",
        "No single-select fields",
        "Project fields unavailable",
        "No Project items",
        "Project items unavailable",
        "No matching Project items",
        "Reset Filters",
        "Filter repositories",
        "Filter planning drift",
        "Drift assessment incomplete",
        "Drift assessment unavailable",
        "Drift assessment is incomplete. Known findings are shown, but CodingBuddy cannot confirm an all-clear.",
        "Read-only access. GitHub does not allow this account to update Project items.",
        "No accessible Projects",
        "No organization Projects are visible to the current GitHub authorization. Check organization access and Project permissions.",
        "Unavailable value: %@",
        "Project move remains unverified. GitHub verification failed: %@",
        "Unavailable references",
        "Remove unavailable references",
        "Incomplete policy evidence",
        "GitHub returned an incomplete field or workflow list. Missing policy references are preserved until a complete refresh proves they were removed.",
        "%@, %@, %@, %@, %@",
        "Refresh Project. Snapshot age: %@. Captured: %@.",
        "Showing snapshot captured %@ (%@). Refresh failed: %@",
        "Move “%@” from “%@” to “%@”. %@",
    ]

    /// Every critical key exists and has a complete German translation.
    @Test func criticalProjectUXCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()

        for key in criticalKeys {
            let entry = try #require(strings[key], "Missing catalog key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated", "Untranslated catalog key: \(key)")
            #expect((unit["value"] as? String)?.isEmpty == false, "Empty German value: \(key)")
        }
    }

    /// German confirmation, snapshot, and accessibility formats preserve typed arguments in order.
    @Test func criticalProjectUXFormatsPreservePlaceholders() throws {
        let strings = try catalogStrings()
        let formatKeys = criticalKeys.filter { $0.contains("%") }

        for key in formatKeys {
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            let value = try #require(unit["value"] as? String)
            #expect(placeholders(in: value) == placeholders(in: key), "Placeholder mismatch: \(key)")
        }
    }

    /// View-only SwiftUI constructors missed by the original extractor remain catalog-backed.
    @Test func projectViewStaticKeysAreCatalogBacked() throws {
        let strings = try catalogStrings()
        let source = try projectViewSource()
        let patterns = [
            #"(?:Text|Label|Button|Link|ContentUnavailableView|Section|Picker|TextField|Menu|Toggle|navigationTitle|help|accessibilityLabel|accessibilityHint|TableColumn|LabeledContent)\(\s*\"([^\"]+)\""#,
            #"\.searchable\([^\n]+prompt:\s*\"([^\"]+)\""#,
            #"\.confirmationDialog\(\s*\"([^\"]+)\""#,
        ]

        for key in try extractedKeys(from: source, patterns: patterns) where !key.contains(#"\("#) {
            let entry = try #require(
                strings[key],
                "Missing catalog key extracted from GitHubProjectsView: \(key)"
            )
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated", "Untranslated catalog key: \(key)")
            #expect((unit["value"] as? String)?.isEmpty == false, "Empty German value: \(key)")
        }
    }

    /// Safety, accessibility, responsive layout, and lazy-board fixes remain explicit in source.
    @Test func verifiedProjectUXRegressionContractsRemainPresent() throws {
        let source = try projectViewSource()

        #expect(source.contains("Move “%@” from “%@” to “%@”. %@"))
        #expect(source.contains(#".accessibilityLabel("Filter repositories")"#))
        #expect(source.contains(#".accessibilityLabel("Filter planning drift")"#))
        #expect(source.contains("snapshot.capturedAt"))
        #expect(source.contains("@AccessibilityFocusState"))
        #expect(source.contains("AccessibilityNotification.Announcement"))
        #expect(source.contains("sideBySideInspectorMinimumWidth: CGFloat = 820"))
        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains(#"Dictionary(grouping: projection.rows, by: \.columnID)"#))
        #expect(source.contains("LazyVStack"))
        #expect(source.contains("Reset Filters"))
        #expect(source.contains("case .partial"))
        #expect(source.contains("case .configurationRequired"))
        #expect(source.contains("case .ambiguous:"))
        #expect(source.contains("return ambiguousMoveStatusMessage"))
        #expect(source.contains("project.viewerCanUpdate == false"))
        #expect(source.contains(".frame(minHeight: 150"))
        #expect(source.contains(".frame(minHeight: 130, idealHeight: 210"))
        #expect(source.contains("save(sanitizedDraft)"))
        #expect(source.contains("fieldsComplete: fieldsComplete"))
        #expect(source.contains("workflowsComplete: workflowsComplete"))
        #expect(source.contains("if store.preferences.selectedProjectID == nil"))
        #expect(source.contains("if store.preferences.selectedFieldID == nil"))
        #expect(source.contains("sourceControlsLocked"))
        #expect(source.contains("sourceControlsLocked\n                    || store.snapshot == nil"))
        #expect(source.contains("row.item.content.referenceLabel"))
        #expect(source.contains("driftAccessibilityLabel(row.findings)"))
    }

    /// Policy cleanup preserves identities whose provider connection was not read completely.
    @Test func policyCleanupRequiresCompleteProviderEvidence() {
        var policy = GitHubProjectDriftPolicy.empty(projectID: "PROJECT", fieldID: "STATUS")
        policy.roleByOptionID = ["CURRENT": .review, "MISSING": .done]
        policy.expectedWorkflowIDs = ["CURRENT-WORKFLOW", "MISSING-WORKFLOW"]

        let incomplete = policy.removingUnavailableReferences(
            currentOptionIDs: ["CURRENT"],
            currentWorkflowIDs: ["CURRENT-WORKFLOW"],
            fieldsComplete: false,
            workflowsComplete: false
        )
        #expect(incomplete == policy)

        let complete = policy.removingUnavailableReferences(
            currentOptionIDs: ["CURRENT"],
            currentWorkflowIDs: ["CURRENT-WORKFLOW"],
            fieldsComplete: true,
            workflowsComplete: true
        )
        #expect(complete.roleByOptionID == ["CURRENT": .review])
        #expect(complete.expectedWorkflowIDs == ["CURRENT-WORKFLOW"])
    }

    /// Removed provider options receive warning lanes while genuinely empty values stay unassigned.
    @Test func removedFieldValueRemainsDistinctFromNoValueAcrossProjectionModes() throws {
        let field = GitHubProjectSingleSelectField(
            id: "STATUS",
            name: "Status",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            options: [GitHubProjectSingleSelectOption(
                id: "CURRENT",
                name: "Current",
                description: nil,
                color: .green
            )]
        )
        let stale = projectItem(id: "STALE", optionID: "REMOVED", optionName: "Legacy review")
        let unassigned = projectItem(id: "EMPTY", optionID: nil, optionName: nil)
        let snapshot = projectSnapshot(field: field, items: [stale, unassigned])
        let assessment = GitHubProjectDriftAssessment(
            state: .partial,
            findings: [],
            unclassifiedOptionIDs: [],
            evidenceGaps: ["Removed option"]
        )

        let projection = try #require(GitHubProjectBoardProjection.make(
            snapshot: snapshot,
            fieldID: field.id,
            assessment: assessment,
            filter: GitHubProjectBoardFilter()
        ))
        let staleRow = try #require(projection.rows.first { $0.id == "STALE" })
        let emptyRow = try #require(projection.rows.first { $0.id == "EMPTY" })
        let unavailableID = GitHubProjectBoardColumn.unavailableValueID(optionID: "REMOVED")

        #expect(staleRow.selectedValue?.name == "Legacy review")
        #expect(staleRow.selectedOption == nil)
        #expect(staleRow.hasUnavailableValue)
        #expect(staleRow.columnID == unavailableID)
        #expect(emptyRow.selectedValue == nil)
        #expect(emptyRow.columnID == GitHubProjectBoardColumn.noValueID)
        #expect(projection.rows(columnID: unavailableID).map(\.id) == ["STALE"])
        #expect(projection.rows(columnID: GitHubProjectBoardColumn.noValueID).map(\.id) == ["EMPTY"])
        #expect(projection.columns.first { $0.id == unavailableID }?.displayName.contains("Legacy review") == true)
        #expect(projection.tableItemIDs == projection.boardItemIDs)
    }

    /// Reads the owned Project view source.
    private func projectViewSource() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("CodingBuddy/Views/GitHubProjectsView.swift"),
            encoding: .utf8
        )
    }

    /// Minimal provider item fixture for stale-value projection behavior.
    private func projectItem(id: String, optionID: String?, optionName: String?) -> GitHubProjectItem {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return GitHubProjectItem(
            id: id,
            updatedAt: timestamp,
            isArchived: false,
            content: GitHubProjectItemContent(
                id: "CONTENT-\(id)",
                kind: .issue,
                title: id,
                number: 1,
                url: URL(string: "https://github.com/apps3k-com/CodingBuddy/issues/1"),
                repository: GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
                state: .open,
                issueStateReason: nil,
                isDraftPullRequest: false,
                updatedAt: timestamp,
                terminalAt: nil,
                parent: nil,
                subIssues: [],
                linkedContent: [],
                relationCoverage: .notApplicable
            ),
            singleSelectValues: optionID.map { id in
                [GitHubProjectSingleSelectValue(
                    fieldID: "STATUS",
                    optionID: id,
                    name: optionName ?? id,
                    updatedAt: timestamp
                )]
            } ?? [],
            fieldValuesComplete: true
        )
    }

    /// Complete snapshot fixture that isolates board projection semantics.
    private func projectSnapshot(
        field: GitHubProjectSingleSelectField,
        items: [GitHubProjectItem]
    ) -> GitHubProjectSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return GitHubProjectSnapshot(
            organization: GitHubProjectOrganization(id: "ORG", login: "apps3k-com"),
            project: GitHubProjectSummary(
                id: "PROJECT",
                number: 13,
                title: "CodingBuddy",
                url: URL(string: "https://github.com/orgs/apps3k-com/projects/13")!,
                isClosed: false,
                viewerCanUpdate: true,
                updatedAt: timestamp
            ),
            fields: [field],
            items: items,
            workflows: [],
            coverage: GitHubProjectSnapshotCoverage(
                fieldsComplete: true,
                itemsComplete: true,
                workflowsComplete: true,
                incompleteFieldValueItemIDs: [],
                incompleteRelationshipItemIDs: []
            ),
            principalID: "VIEWER",
            capturedAt: timestamp
        )
    }

    /// Extracts static string arguments for the supplied source patterns.
    private func extractedKeys(from source: String, patterns: [String]) throws -> Set<String> {
        var keys: Set<String> = []
        for pattern in patterns {
            let expression = try NSRegularExpression(pattern: pattern)
            let sourceRange = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: sourceRange) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[range]))
            }
        }
        return keys
    }

    /// Ordered Foundation format placeholders in one catalog string.
    private func placeholders(in value: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: #"%lld|%@"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression?.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        } ?? []
    }

    /// Decodes the source-language String Catalog.
    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings")
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: [String: Any]])
    }
}
