//
//  CapabilityHygieneAnalyzerTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Resource, identity, and evidence tests for deterministic capability analysis.
nonisolated struct CapabilityHygieneAnalyzerTests {
    /// Creates one complete public fixture occurrence.
    private func item(
        kind: CapabilityKind = .skill,
        consumer: CapabilityConsumer = .codex,
        identity: String,
        sourcePath: String,
        scope: String = "user",
        repositoryUsage: [String] = [],
        activationState: CapabilityActivationState = .enabled,
        fingerprintContent: String? = nil
    ) -> CapabilityInventoryItem {
        CapabilityInventoryItem(
            kind: kind,
            consumer: consumer,
            runtimeIdentity: identity,
            sourcePath: sourcePath,
            effectiveScope: scope,
            repositoryUsage: repositoryUsage,
            registrationState: kind == .mcpServer ? .configured : .installed,
            activationState: activationState,
            sourceStatus: .complete,
            canonicalFingerprint: .publicContent(
                schemaVersion: "test-v1",
                data: Data((fingerprintContent ?? sourcePath).utf8)
            )
        )
    }

    /// Unknown and explicitly disabled occurrences never enter relation analysis.
    @Test func analysisRequiresExplicitEnabledEvidence() {
        let enabled = item(identity: "review", sourcePath: "/enabled", fingerprintContent: "same")
        let disabled = item(
            identity: "review",
            sourcePath: "/disabled",
            activationState: .disabled,
            fingerprintContent: "same"
        )
        let unknown = item(
            identity: "review",
            sourcePath: "/unknown",
            activationState: .unknown,
            fingerprintContent: "same"
        )

        let result = CapabilityHygieneAnalyzer.analyze(in: [enabled, disabled, unknown])

        #expect(result.findings.isEmpty)
    }

    /// Provider namespaces alone are provenance, not semantic similarity.
    @Test func pluginMarketplaceSuffixDoesNotCreatePossibleOverlap() {
        let notion = item(kind: .plugin, identity: "notion@claude-plugins-official", sourcePath: "/notion")
        let context = item(kind: .plugin, identity: "context7@claude-plugins-official", sourcePath: "/context7")

        let result = CapabilityHygieneAnalyzer.analyze(in: [notion, context])

        #expect(result.findings.isEmpty)
        #expect(!result.isTruncated)
    }

    /// Candidate and output budgets fail closed instead of retaining quadratic output.
    @Test func overlapBudgetReportsTruncatedCoverage() {
        let items = (0..<200).map { index in
            item(identity: "github-security-review-\(index)", sourcePath: "/\(index)")
        }

        let result = CapabilityHygieneAnalyzer.analyze(
            in: items,
            limits: .init(maximumOverlapComparisons: 50, maximumFindings: 10)
        )

        #expect(result.isTruncated)
        #expect(result.examinedOverlapComparisons <= 50)
        #expect(result.findings.count <= 10)
    }

    /// Shadowing evidence is valid only in a shared, explicit evaluation context.
    @Test func shadowingRequiresApplicableEvaluationScope() {
        let winner = item(
            kind: .mcpServer,
            consumer: .claudeCode,
            identity: "review",
            sourcePath: "/local",
            scope: "/repo",
            repositoryUsage: ["/repo"]
        )
        let loser = item(
            kind: .mcpServer,
            consumer: .claudeCode,
            identity: "review",
            sourcePath: "/user",
            scope: "user"
        )
        let valid = CapabilityPrecedenceEvidence(
            provider: .claudeCode,
            ruleIdentifier: "claude-mcp-local-over-user-v1",
            evaluationScope: "/repo",
            winnerItemID: winner.id,
            loserItemID: loser.id
        )
        let unrelated = CapabilityPrecedenceEvidence(
            provider: .claudeCode,
            ruleIdentifier: "claude-mcp-local-over-user-v1",
            evaluationScope: "/other-repo",
            winnerItemID: winner.id,
            loserItemID: loser.id
        )

        #expect(CapabilityHygieneAnalyzer.findings(in: [winner, loser], precedenceEvidence: [valid])
            .contains { $0.kind == .shadowing })
        #expect(!CapabilityHygieneAnalyzer.findings(in: [winner, loser], precedenceEvidence: [unrelated])
            .contains { $0.kind == .shadowing })
    }

    /// Compact labels never alter the exact provider identity used by the analyzer.
    @Test func longRuntimeIdentitiesRemainDistinct() {
        let prefix = String(repeating: "x", count: 200)
        let first = item(identity: prefix + "-one", sourcePath: "/one")
        let second = item(identity: prefix + "-two", sourcePath: "/two")

        #expect(first.runtimeIdentity != second.runtimeIdentity)
        #expect(first.displayIdentity == second.displayIdentity)
        #expect(CapabilityHygieneAnalyzer.findings(in: [first, second]).isEmpty)
    }
}
