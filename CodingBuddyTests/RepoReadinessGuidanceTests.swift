//
//  RepoReadinessGuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Deterministic catalog and routing coverage for Repo Readiness guidance.
struct RepoReadinessGuidanceTests {
    /// Every code and status pair produces a unique stable guidance identity.
    @Test func catalogCoversEveryCheckCodeAndStatus() {
        let guidance = RepoReadinessCheckCode.allCases.flatMap { code in
            RepoReadinessStatus.allCases.map { status in
                RepoReadinessGuidance.guidance(for: item(code: code, status: status))
            }
        }

        #expect(guidance.count == RepoReadinessCheckCode.allCases.count * RepoReadinessStatus.allCases.count)
        #expect(Set(guidance.map(\.id)).count == guidance.count)
        #expect(guidance.allSatisfy { !$0.explanation.isEmpty })
        #expect(guidance.allSatisfy { !$0.relevance.isEmpty })
        #expect(guidance.allSatisfy { !$0.consequence.isEmpty })

        let codeSpecificRelevance = RepoReadinessCheckCode.allCases.map { code in
            RepoReadinessGuidance.guidance(for: item(code: code, status: .warn)).relevance
        }
        #expect(Set(codeSpecificRelevance).count == RepoReadinessCheckCode.allCases.count)
    }

    /// Explanation copy comes from the observed item detail, not its localized title.
    @Test func explanationReusesItemDetailAndIdentityIgnoresDisplayCopy() {
        let first = item(
            code: .governance,
            status: .warn,
            title: "Agent governance file",
            detail: "The governance file is incomplete."
        )
        let localizedCopy = item(
            code: .governance,
            status: .warn,
            title: "Agenten-Regeldatei",
            detail: "Die Regeldatei ist unvollstaendig."
        )
        let firstGuidance = RepoReadinessGuidance.guidance(for: first)
        let localizedGuidance = RepoReadinessGuidance.guidance(for: localizedCopy)

        #expect(firstGuidance.explanation == first.detail)
        #expect(localizedGuidance.explanation == localizedCopy.detail)
        #expect(firstGuidance.id == localizedGuidance.id)
        #expect(firstGuidance.recommendedAction.id == localizedGuidance.recommendedAction.id)
        #expect(firstGuidance.technicalEvidence.map(\.id) == localizedGuidance.technicalEvidence.map(\.id))
    }

    /// Passing checks render a neutral healthy state instead of an unavailable control.
    @Test func passingChecksRequireNoAction() {
        for code in RepoReadinessCheckCode.allCases {
            let guidance = RepoReadinessGuidance.guidance(for: item(code: code, status: .pass))
            let action = guidance.recommendedAction

            guard case let .notNeeded(reason) = action.availability else {
                Issue.record("Expected pass guidance for \(code.rawValue) to require no action")
                continue
            }

            #expect(!reason.isEmpty)
            #expect(action.id == "repo-readiness.action.\(code.rawValue).not-needed")
            #expect(action.safetyClass == .readOnly)
            #expect(guidance.alternatives.isEmpty)
        }
    }

    /// Warning and failure checks route to the same available read-only reveal action.
    @Test func warningAndFailureChecksRevealRepository() {
        for code in RepoReadinessCheckCode.allCases {
            for status in [RepoReadinessStatus.warn, .fail] {
                let action = RepoReadinessGuidance.guidance(
                    for: item(code: code, status: status)
                ).recommendedAction

                #expect(action.id == RepoReadinessGuidance.revealRepositoryActionID)
                #expect(action.availability == .available)
                #expect(action.safetyClass == .readOnly)
                #expect(action.effort == .low)
            }
        }
    }

    /// CI receives the accurate glossary term while lightweight Git markers do not imply a dirty worktree.
    @Test func glossaryTermsMatchScannerMeaning() {
        for status in RepoReadinessStatus.allCases {
            let ciGuidance = RepoReadinessGuidance.guidance(
                for: item(code: .ciWorkflow, status: status)
            )
            let repositoryStateGuidance = RepoReadinessGuidance.guidance(
                for: item(code: .repositoryState, status: status)
            )

            #expect(ciGuidance.glossaryTerms == [.ci])
            #expect(!repositoryStateGuidance.glossaryTerms.contains(.dirtyWorktree))
        }
    }

    /// Evidence exposes only stable check/status/source metadata and sanitizes the source path.
    @Test func evidenceIsStableBoundedAndDoesNotLeakItemCopy() {
        let sensitiveTitle = "TOKEN_TITLE"
        let sensitiveDetail = "TOKEN_DETAIL"
        let sensitiveRemediation = "TOKEN_REMEDIATION"
        let source = ".github/workflows/\n\tci.yml"
        let guidance = RepoReadinessGuidance.guidance(
            for: item(
                code: .ciWorkflow,
                status: .fail,
                title: sensitiveTitle,
                detail: sensitiveDetail,
                source: source,
                remediationHint: sensitiveRemediation
            )
        )
        let evidence = guidance.technicalEvidence
        let evidenceText = evidence.map(\.sanitizedValue).joined(separator: " ")

        #expect(evidence.map(\.id) == [
            "repo-readiness.evidence.check",
            "repo-readiness.evidence.status",
            "repo-readiness.evidence.source",
        ])
        #expect(evidence.map(\.sanitizedValue) == ["ciWorkflow", "fail", ".github/workflows/ ci.yml"])
        #expect(!evidenceText.contains(sensitiveTitle))
        #expect(!evidenceText.contains(sensitiveDetail))
        #expect(!evidenceText.contains(sensitiveRemediation))
        #expect(!evidenceText.contains("\n"))
        #expect(!evidenceText.contains("\t"))
    }

    /// The model action identity is the exact route consumed by RepoReadinessView.
    @Test func revealRepositoryActionRoutingIDIsStable() {
        #expect(
            RepoReadinessGuidance.revealRepositoryActionID
                == "repo-readiness.action.reveal-repository"
        )
    }

    /// Creates one catalog input without involving the scanner or filesystem.
    private func item(
        code: RepoReadinessCheckCode,
        status: RepoReadinessStatus,
        title: String = "Localized title",
        detail: String = "Localized observed detail",
        source: String = "README.md",
        remediationHint: String = "Localized remediation"
    ) -> RepoReadinessItem {
        RepoReadinessItem(
            code: code,
            status: status,
            title: title,
            detail: detail,
            source: source,
            remediationHint: remediationHint
        )
    }
}
