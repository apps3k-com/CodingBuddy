//
//  AgentDoctorGuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct AgentDoctorGuidanceTests {
    @Test func catalogCoversEveryDiagnosticCodeWithCompleteDeterministicGuidance() {
        let guidance = AgentDiagnosticCode.allCases.map { code in
            AgentDoctorGuidance.guidance(for: makeDiagnostic(code: code), canOpenSource: true)
        }

        #expect(guidance.count == AgentDiagnosticCode.allCases.count)
        #expect(Set(guidance.map(\.id)).count == guidance.count)
        #expect(guidance.map(\.id) == AgentDiagnosticCode.allCases.map {
            let diagnostic = makeDiagnostic(code: $0)
            return "agent-doctor.guidance.\(diagnostic.id)"
        })
        #expect(guidance.allSatisfy { !$0.explanation.isEmpty })
        #expect(guidance.allSatisfy { !$0.relevance.isEmpty })
        #expect(guidance.allSatisfy { !$0.consequence.isEmpty })
        #expect(guidance.allSatisfy { !$0.recommendedAction.title.isEmpty })
        #expect(guidance.allSatisfy { !$0.recommendedAction.expectedResult.isEmpty })
        #expect(guidance.allSatisfy { !$0.technicalEvidence.isEmpty })
    }

    @Test func missingDirectoryOpensItsDestinationAndOnlyOffersAUsableSource() {
        let diagnostic = makeDiagnostic(code: .missingDirectory)
        let withoutSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)
        let withSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: true)

        #expect(withoutSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
        #expect(withoutSource.recommendedAction.availability == .available)
        #expect(withoutSource.alternatives.isEmpty)
        #expect(withSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
        #expect(withSource.alternatives.map(\.id) == [AgentDoctorGuidance.openSourceActionID])
        #expect(withSource.alternatives.first?.availability == .available)
    }

    @Test func missingZshStartupFilesNeverOfferTheHomeDirectoryAsASourceFile() {
        let diagnostic = makeDiagnostic(code: .missingZshStartupFiles)

        for canOpenSource in [false, true] {
            let guidance = AgentDoctorGuidance.guidance(
                for: diagnostic,
                canOpenSource: canOpenSource
            )
            #expect(guidance.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
            #expect(guidance.alternatives.isEmpty)
        }
    }

    @Test func invalidJSONPrefersTheSourceAndFallsBackToTheOwningDestination() throws {
        let diagnostic = makeDiagnostic(code: .invalidConfigFile)
        let withSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: true)
        let withoutSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)

        #expect(withSource.recommendedAction.id == AgentDoctorGuidance.openSourceActionID)
        #expect(withSource.recommendedAction.availability == .available)
        #expect(withSource.alternatives.map(\.id) == [AgentDoctorGuidance.openDestinationActionID])
        #expect(withSource.alternatives.first?.availability == .available)

        #expect(withoutSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
        #expect(withoutSource.recommendedAction.availability == .available)
        #expect(withoutSource.alternatives.map(\.id) == [AgentDoctorGuidance.openSourceActionID])
        let unavailableSource = try #require(withoutSource.alternatives.first)
        try expectUnavailable(unavailableSource)
    }

    @Test func missingVariableOpensTheToolBeforeItsSourceAlternative() throws {
        let diagnostic = makeDiagnostic(code: .missingReferencedEnvVar)
        let withSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: true)
        let withoutSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)

        #expect(withSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
        #expect(withSource.recommendedAction.availability == .available)
        #expect(withSource.alternatives.map(\.id) == [AgentDoctorGuidance.openSourceActionID])
        #expect(withSource.alternatives.first?.availability == .available)

        #expect(withoutSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
        let sourceFallback = try #require(withoutSource.alternatives.first)
        #expect(sourceFallback.id == AgentDoctorGuidance.openSourceActionID)
        try expectUnavailable(sourceFallback)
    }

    @Test func unsafePermissionsRecommendAnUnavailableRepairBeforeSourceInspection() throws {
        let diagnostic = makeDiagnostic(code: .unsafePermissions)
        let guidance = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: true)

        #expect(guidance.recommendedAction.id == AgentDoctorGuidance.restrictPermissionsActionID)
        #expect(guidance.recommendedAction.safetyClass == .requiresConfirmation)
        try expectUnavailable(guidance.recommendedAction)
        #expect(guidance.alternatives.map(\.id) == [AgentDoctorGuidance.openSourceActionID])
        #expect(guidance.alternatives.first?.availability == .available)

        let withoutSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)
        let unavailableSource = try #require(withoutSource.alternatives.first)
        try expectUnavailable(unavailableSource)
    }

    @Test func credentialFindingsOpenMCPAuthBeforeTheirSourceAlternative() throws {
        for code in [AgentDiagnosticCode.expiredCredential, .incompleteCredential] {
            let diagnostic = makeDiagnostic(code: code)
            let withSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: true)
            let withoutSource = AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)

            #expect(withSource.recommendedAction.id == AgentDoctorGuidance.openDestinationActionID)
            #expect(withSource.recommendedAction.availability == .available)
            #expect(withSource.alternatives.map(\.id) == [AgentDoctorGuidance.openSourceActionID])
            #expect(withSource.alternatives.first?.availability == .available)

            let sourceFallback = try #require(withoutSource.alternatives.first)
            #expect(sourceFallback.id == AgentDoctorGuidance.openSourceActionID)
            try expectUnavailable(sourceFallback)
        }
    }

    @Test func destinationResolverKeepsCredentialRoutingSafe() {
        let malformedCredential = AgentDiagnostic(
            code: .expiredCredential,
            severity: .warning,
            tool: .codex,
            title: "Expired",
            detail: "Expired",
            source: "credential-entry",
            subject: nil,
            suggestion: "Inspect"
        )
        let regularFinding = makeDiagnostic(code: .invalidConfigFile)

        #expect(AgentDoctorGuidance.destinationTool(for: malformedCredential) == .mcpAuth)
        #expect(AgentDoctorGuidance.destinationTool(for: regularFinding) == regularFinding.tool)
    }

    @Test func sameCodeFindingsRetainDistinctGuidanceIdentity() {
        let first = makeDiagnostic(code: .invalidConfigFile)
        let second = AgentDiagnostic(
            code: first.code,
            severity: first.severity,
            tool: first.tool,
            title: first.title,
            detail: first.detail,
            source: "/Users/example/.claude/other.json",
            subject: first.subject,
            suggestion: first.suggestion
        )

        let firstGuidance = AgentDoctorGuidance.guidance(for: first, canOpenSource: true)
        let secondGuidance = AgentDoctorGuidance.guidance(for: second, canOpenSource: true)
        #expect(firstGuidance.id != secondGuidance.id)
    }

    @Test func glossaryTermsStayRelevantAndOrderedForEachDiagnosticCode() {
        for code in AgentDiagnosticCode.allCases {
            let guidance = AgentDoctorGuidance.guidance(
                for: makeDiagnostic(code: code),
                canOpenSource: true
            )
            let expected: [DeveloperTerm]
            switch code {
            case .missingReferencedEnvVar:
                expected = [.mcp]
            case .expiredCredential, .incompleteCredential:
                expected = [.mcp, .oauth]
            case .missingDirectory, .missingZshStartupFiles, .invalidConfigFile, .unsafePermissions:
                expected = []
            }

            #expect(guidance.glossaryTerms == expected)
        }
    }

    @Test func actionIdentifiersAreStableAndEveryCatalogActionUsesOneOfThem() {
        #expect(AgentDoctorGuidance.openDestinationActionID == "agent-doctor.action.open-destination")
        #expect(AgentDoctorGuidance.openSourceActionID == "agent-doctor.action.open-source")
        #expect(AgentDoctorGuidance.restrictPermissionsActionID == "agent-doctor.action.restrict-permissions")

        let stableIDs = Set([
            AgentDoctorGuidance.openDestinationActionID,
            AgentDoctorGuidance.openSourceActionID,
            AgentDoctorGuidance.restrictPermissionsActionID,
        ])
        let catalogActionIDs = AgentDiagnosticCode.allCases.flatMap { code in
            let guidance = AgentDoctorGuidance.guidance(
                for: makeDiagnostic(code: code),
                canOpenSource: true
            )
            return [guidance.recommendedAction.id] + guidance.alternatives.map(\.id)
        }

        #expect(Set(catalogActionIDs).isSubset(of: stableIDs))
        #expect(Set(catalogActionIDs) == stableIDs)
    }

    @Test func evidenceIncludesOnlyValidatedShapesFromTheSanitizedModelContract() {
        let missingVariable = AgentDoctorGuidance.guidance(
            for: makeDiagnostic(code: .missingReferencedEnvVar),
            canOpenSource: true
        )
        #expect(missingVariable.technicalEvidence.map(\.sanitizedValue) == [
            AgentDiagnosticCode.missingReferencedEnvVar.rawValue,
            AgentDiagnosticTool.codex.displayName,
            "/Users/example/.codex/config.toml",
            "MCP_TOKEN",
        ])

        let permissions = AgentDoctorGuidance.guidance(
            for: makeDiagnostic(code: .unsafePermissions),
            canOpenSource: true
        )
        #expect(permissions.technicalEvidence.map(\.sanitizedValue) == [
            AgentDiagnosticCode.unsafePermissions.rawValue,
            AgentDiagnosticTool.codex.displayName,
            "/Users/example/.codex/mcp.env",
            "644",
        ])

        let credential = AgentDoctorGuidance.guidance(
            for: makeDiagnostic(code: .expiredCredential),
            canOpenSource: false
        )
        #expect(credential.technicalEvidence.map(\.sanitizedValue) == [
            AgentDiagnosticCode.expiredCredential.rawValue,
            AgentDiagnosticTool.mcpAuth.displayName,
            "abcdef123456",
        ])
    }

    @Test func guidanceNeverSynthesizesSecretValuesOAuthURLsOrRawConfigProse() {
        let secrets = [
            "raw-token-value",
            "https://user:secret@example.com/oauth",
            #"{"access_token":"raw-config-secret"}"#,
        ]

        for code in AgentDiagnosticCode.allCases {
            let diagnostic = AgentDiagnostic(
                code: code,
                severity: .warning,
                tool: code == .expiredCredential || code == .incompleteCredential ? .mcpAuth : .codex,
                title: secrets[0],
                detail: secrets[2],
                source: secrets[1],
                subject: secrets[0],
                suggestion: secrets[2]
            )
            let rendered = renderedGuidance(
                AgentDoctorGuidance.guidance(for: diagnostic, canOpenSource: false)
            )

            for secret in secrets {
                #expect(!rendered.contains(secret))
            }
        }
    }

    private func makeDiagnostic(code: AgentDiagnosticCode) -> AgentDiagnostic {
        let tool: AgentDiagnosticTool
        let source: String
        let subject: String?

        switch code {
        case .missingDirectory:
            tool = .codex
            source = "/Users/example/.codex"
            subject = nil
        case .missingZshStartupFiles:
            tool = .zsh
            source = "/Users/example"
            subject = ".zshenv, .zprofile, .zshrc"
        case .invalidConfigFile:
            tool = .claudeCode
            source = "/Users/example/.claude/settings.json"
            subject = nil
        case .missingReferencedEnvVar:
            tool = .codex
            source = "/Users/example/.codex/config.toml"
            subject = "MCP_TOKEN"
        case .unsafePermissions:
            tool = .codex
            source = "/Users/example/.codex/mcp.env"
            subject = "644"
        case .expiredCredential, .incompleteCredential:
            tool = .mcpAuth
            source = "mcp-remote-1.0.0/abcdef1234567890abcdef1234567890"
            subject = "abcdef123456"
        }

        return AgentDiagnostic(
            code: code,
            severity: .warning,
            tool: tool,
            title: "Diagnostic title",
            detail: "Diagnostic detail",
            source: source,
            subject: subject,
            suggestion: "Diagnostic suggestion"
        )
    }

    private func expectUnavailable(_ action: RecommendedAction) throws {
        guard case let .unavailable(reason) = action.availability else {
            Issue.record("Expected action \(action.id) to be unavailable")
            return
        }
        #expect(!reason.isEmpty)
    }

    private func renderedGuidance(_ guidance: Guidance) -> String {
        let actions = [guidance.recommendedAction] + guidance.alternatives
        let actionText = actions.flatMap { action in
            [action.title, action.expectedResult, availabilityReason(action.availability)]
        }
        let evidenceText = guidance.technicalEvidence.flatMap { evidence in
            [evidence.label, evidence.sanitizedValue]
        }
        return (
            [guidance.explanation, guidance.relevance, guidance.consequence]
                + actionText
                + evidenceText
        ).joined(separator: "\n")
    }

    private func availabilityReason(_ availability: ActionAvailability) -> String {
        switch availability {
        case .available:
            ""
        case .notNeeded(let reason), .unavailable(let reason):
            reason
        }
    }
}
