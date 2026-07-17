//
//  GitHubProjectDriftRegressionTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Focused regressions for lifecycle reason and persisted-policy drift.
struct GitHubProjectDriftRegressionTests {
    /// Stable fixture timestamp.
    private let now = Date(timeIntervalSince1970: 1_784_282_400)

    /// Completion reasons are checked even when issue state and terminal lane already agree.
    @Test func terminalLaneCompletionReasonConflictsAreReported() {
        let field = makeField()
        let items = [
            makeItem(id: "DONE_ITEM", reason: .notPlanned, optionID: "DONE"),
            makeItem(id: "CANCELED_ITEM", reason: .completed, optionID: "CANCELED"),
        ]

        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: makeSnapshot(field: field, items: items),
            fieldID: field.id,
            policy: classifiedPolicy(field: field)
        )

        let conflicts = assessment.findings.filter {
            $0.title == String(localized: "Issue completion reason conflicts with the lane")
        }
        #expect(Set(conflicts.map(\.itemID)) == ["DONE_ITEM", "CANCELED_ITEM"])
        #expect(conflicts.allSatisfy { $0.severity == .warning })
    }

    /// Removed option mappings cannot produce a healthy assessment while moves fail closed.
    @Test func removedPersistedOptionMappingRequiresReconfiguration() {
        let field = makeField()
        let item = makeItem(id: "ITEM", reason: .completed, optionID: "DONE")
        let snapshot = makeSnapshot(field: field, items: [item])
        var policy = classifiedPolicy(field: field)
        policy.roleByOptionID["REMOVED"] = .review

        let analyzer = GitHubProjectDriftAnalyzer()
        let assessment = analyzer.assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )

        #expect(!policy.completelyClassifies(field))
        #expect(assessment.state == .configurationRequired)
        #expect(!assessment.isProvenHealthy)
        #expect(!assessment.evidenceGaps.isEmpty)
        #expect(analyzer.moveRisk(
            snapshot: snapshot,
            item: item,
            fieldID: field.id,
            destinationOptionID: "TODO",
            policy: policy
        ) == .unknown)
    }

    /// Field definition with active, completed, and canceled lanes.
    private func makeField() -> GitHubProjectSingleSelectField {
        GitHubProjectSingleSelectField(
            id: "STATUS",
            name: "Status",
            updatedAt: now,
            options: [
                GitHubProjectSingleSelectOption(
                    id: "TODO",
                    name: "Todo",
                    description: nil,
                    color: .gray
                ),
                GitHubProjectSingleSelectOption(
                    id: "DONE",
                    name: "Done",
                    description: nil,
                    color: .green
                ),
                GitHubProjectSingleSelectOption(
                    id: "CANCELED",
                    name: "Canceled",
                    description: nil,
                    color: .red
                ),
            ]
        )
    }

    /// Complete lifecycle semantics for every current field option.
    private func classifiedPolicy(
        field: GitHubProjectSingleSelectField
    ) -> GitHubProjectDriftPolicy {
        var policy = GitHubProjectDriftPolicy.empty(projectID: "PROJECT", fieldID: field.id)
        policy.roleByOptionID = [
            "TODO": .inProgress,
            "DONE": .done,
            "CANCELED": .canceled,
        ]
        return policy
    }

    /// Closed issue fixture with complete relation and field evidence.
    private func makeItem(
        id: String,
        reason: GitHubProjectIssueStateReason,
        optionID: String
    ) -> GitHubProjectItem {
        GitHubProjectItem(
            id: id,
            updatedAt: now,
            isArchived: false,
            content: GitHubProjectItemContent(
                id: "CONTENT_\(id)",
                kind: .issue,
                title: id,
                number: 1,
                url: URL(string: "https://github.com/apps3k-com/CodingBuddy/issues/1"),
                repository: GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
                state: .closed,
                issueStateReason: reason,
                isDraftPullRequest: false,
                updatedAt: now,
                terminalAt: now,
                parent: nil,
                subIssues: [],
                linkedContent: [],
                relationCoverage: .notApplicable
            ),
            singleSelectValues: [
                GitHubProjectSingleSelectValue(
                    fieldID: "STATUS",
                    optionID: optionID,
                    name: optionID,
                    updatedAt: now
                ),
            ],
            fieldValuesComplete: true
        )
    }

    /// Complete snapshot fixture for deterministic analyzer output.
    private func makeSnapshot(
        field: GitHubProjectSingleSelectField,
        items: [GitHubProjectItem]
    ) -> GitHubProjectSnapshot {
        GitHubProjectSnapshot(
            organization: GitHubProjectOrganization(id: "ORG", login: "apps3k-com"),
            project: GitHubProjectSummary(
                id: "PROJECT",
                number: 13,
                title: "CodingBuddy",
                url: URL(string: "https://github.com/orgs/apps3k-com/projects/13")!,
                isClosed: false,
                viewerCanUpdate: true,
                updatedAt: now
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
            capturedAt: now
        )
    }
}
