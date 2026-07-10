//
//  GuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct GuidanceTests {
    @Test func stableIdentityDoesNotDependOnDisplayText() {
        let first = makeGuidance(
            explanation: "Plain explanation",
            actionTitle: "Open settings",
            evidenceLabel: "Source"
        )
        let localizedCopy = makeGuidance(
            explanation: "Einfache Erklaerung",
            actionTitle: "Einstellungen oeffnen",
            evidenceLabel: "Quelle"
        )

        #expect(first.id == "guidance.test")
        #expect(first.recommendedAction.id == "action.open-settings")
        #expect(first.technicalEvidence.first?.id == "evidence.source")
        #expect(first.id == localizedCopy.id)
        #expect(first.recommendedAction.id == localizedCopy.recommendedAction.id)
        #expect(first.technicalEvidence.first?.id == localizedCopy.technicalEvidence.first?.id)
        #expect(first != localizedCopy)
    }

    @Test func actionAvailabilityPreservesUnavailableReason() {
        let reason = "Connect a repository before running this action."
        let available = makeAction(id: "action.available", availability: .available)
        let unavailable = makeAction(id: "action.unavailable", availability: .unavailable(reason: reason))

        #expect(available.availability == .available)
        #expect(unavailable.availability == .unavailable(reason: reason))
        #expect(unavailable.availability != .unavailable(reason: "A different reason"))

        guard case let .unavailable(storedReason) = unavailable.availability else {
            Issue.record("Expected the action to be unavailable")
            return
        }
        #expect(storedReason == reason)
    }

    @Test func noActionNeededRemainsDistinctFromAnUnavailableAction() {
        let reason = "The current state is already healthy."
        let action = makeAction(id: "action.none", availability: .notNeeded(reason: reason))

        guard case let .notNeeded(storedReason) = action.availability else {
            Issue.record("Expected the action to report that no work is needed")
            return
        }

        #expect(storedReason == reason)
        #expect(action.availability != .unavailable(reason: reason))
    }

    @Test func alternativesRetainTheirDeclaredOrder() {
        let alternatives = [
            makeAction(id: "action.inspect"),
            makeAction(id: "action.retry"),
            makeAction(id: "action.dismiss"),
        ]
        let guidance = Guidance(
            id: "guidance.ordered-alternatives",
            explanation: "Explanation",
            relevance: "Relevance",
            consequence: "Consequence",
            recommendedAction: makeAction(id: "action.primary"),
            alternatives: alternatives,
            technicalEvidence: [],
            glossaryTerms: []
        )

        #expect(guidance.alternatives.map(\.id) == [
            "action.inspect",
            "action.retry",
            "action.dismiss",
        ])
    }

    @Test func glossaryCoversEveryTermWithUniqueStableIdentityAndText() {
        let expectedTerms: [DeveloperTerm] = [
            .ci,
            .pr,
            .mcp,
            .oauth,
            .scope,
            .dirtyWorktree,
            .aheadBehind,
            .packagePin,
            .directDependency,
        ]
        let entries = DeveloperTerm.allCases.map(DeveloperGlossary.entry(for:))

        #expect(DeveloperTerm.allCases == expectedTerms)
        #expect(entries.count == 9)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.map(\.term) == expectedTerms)
        #expect(entries.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(entries.allSatisfy { !$0.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(entries.map(\.id) == [
            "ci",
            "pr",
            "mcp",
            "oauth",
            "scope",
            "dirty-worktree",
            "ahead-behind",
            "package-pin",
            "direct-dependency",
        ])
    }

    @Test func effortAndSafetyClassificationsHaveStableRawValues() {
        #expect(GuidanceEffort.allCases.map(\.rawValue) == ["low", "medium", "high"])
        #expect(GuidanceSafetyClass.allCases.map(\.rawValue) == [
            "readOnly",
            "reversible",
            "requiresConfirmation",
        ])
    }

    private func makeGuidance(
        explanation: String,
        actionTitle: String,
        evidenceLabel: String
    ) -> Guidance {
        Guidance(
            id: "guidance.test",
            explanation: explanation,
            relevance: "Why this matters",
            consequence: "What can happen",
            recommendedAction: RecommendedAction(
                id: "action.open-settings",
                title: actionTitle,
                expectedResult: "The setting can be reviewed.",
                effort: .low,
                safetyClass: .readOnly,
                availability: .available
            ),
            alternatives: [],
            technicalEvidence: [
                TechnicalEvidence(
                    id: "evidence.source",
                    label: evidenceLabel,
                    sanitizedValue: "config.toml"
                ),
            ],
            glossaryTerms: [.mcp]
        )
    }

    private func makeAction(
        id: String,
        availability: ActionAvailability = .available
    ) -> RecommendedAction {
        RecommendedAction(
            id: id,
            title: "Action",
            expectedResult: "Expected result",
            effort: .low,
            safetyClass: .readOnly,
            availability: availability
        )
    }
}
