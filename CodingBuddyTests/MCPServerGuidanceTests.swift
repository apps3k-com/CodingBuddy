//
//  MCPServerGuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct MCPServerGuidanceTests {
    @Test func missingVariablesRecommendToolAndDescribeStartupAndAuthenticationFailure() {
        let item = makeItem(missingEnvVarNames: ["SERVICE_API_KEY"])
        let guidance = MCPServerGuidance.guidance(
            for: item,
            canOpenTool: true,
            canOpenSource: true
        )

        #expect(guidance.id == "mcp-inventory.guidance.missing-environment-variables.\(item.id)")
        #expect(guidance.recommendedAction.id == MCPServerGuidance.openToolActionID)
        #expect(guidance.recommendedAction.availability == .available)
        #expect(guidance.alternatives.map(\.id) == [MCPServerGuidance.openSourceActionID])
        #expect(guidance.consequence == String(
            localized: "MCP guidance missing environment variables consequence",
            defaultValue:
                "The server may fail to start, or authentication may fail, until the missing variables are defined."
        ))
        #expect(guidance.glossaryTerms == [.mcp, .scope])
    }

    @Test func missingVariablesFallBackToSourceWhenToolCannotOpen() {
        let guidance = MCPServerGuidance.guidance(
            for: makeItem(missingEnvVarNames: ["SERVICE_API_KEY"]),
            canOpenTool: false,
            canOpenSource: true
        )

        #expect(guidance.recommendedAction.id == MCPServerGuidance.openSourceActionID)
        #expect(guidance.recommendedAction.availability == .available)
        #expect(guidance.alternatives.map(\.id) == [MCPServerGuidance.openToolActionID])
        guard case let .unavailable(reason) = guidance.alternatives[0].availability else {
            Issue.record("Expected the unavailable tool action to explain why it cannot open")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func configuredStateRequiresNoActionAndDisclosesTestLimits() {
        let item = makeItem()
        let guidance = MCPServerGuidance.guidance(
            for: item,
            canOpenTool: true,
            canOpenSource: true
        )

        #expect(guidance.id == "mcp-inventory.guidance.configured.\(item.id)")
        guard case let .notNeeded(reason) = guidance.recommendedAction.availability else {
            Issue.record("Expected configured inventory guidance to require no action")
            return
        }
        #expect(!reason.isEmpty)
        #expect(guidance.relevance == String(
            localized: "MCP guidance configured relevance",
            defaultValue:
                "This is a configuration-only result. CodingBuddy has not tested network reachability or authentication."
        ))
        #expect(guidance.alternatives.isEmpty)
        #expect(guidance.glossaryTerms == [.mcp, .scope])
    }

    @Test func unknownTransportPrefersSourceAndNeverReportsNoActionNeeded() {
        let item = makeItem(transport: .unknown)
        let guidance = MCPServerGuidance.guidance(
            for: item,
            canOpenTool: true,
            canOpenSource: true
        )

        #expect(guidance.id == "mcp-inventory.guidance.unknown-transport.\(item.id)")
        #expect(guidance.recommendedAction.id == MCPServerGuidance.openSourceActionID)
        #expect(guidance.recommendedAction.availability == .available)
        #expect(guidance.alternatives.map(\.id) == [MCPServerGuidance.openToolActionID])
        if case .notNeeded = guidance.recommendedAction.availability {
            Issue.record("Unknown transport must not be presented as healthy")
        }
        #expect(guidance.glossaryTerms == [.mcp, .scope])
    }

    @Test func unknownTransportFallsBackToToolAndExplainsUnavailableSource() {
        let guidance = MCPServerGuidance.guidance(
            for: makeItem(transport: .unknown),
            canOpenTool: true,
            canOpenSource: false
        )

        #expect(guidance.recommendedAction.id == MCPServerGuidance.openToolActionID)
        #expect(guidance.recommendedAction.availability == .available)
        #expect(guidance.alternatives.map(\.id) == [MCPServerGuidance.openSourceActionID])
        guard case let .unavailable(reason) = guidance.alternatives[0].availability else {
            Issue.record("Expected the source alternative to explain why it cannot open")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func unknownTransportExplainsWhenNeitherActionCanOpen() {
        let guidance = MCPServerGuidance.guidance(
            for: makeItem(transport: .unknown),
            canOpenTool: false,
            canOpenSource: false
        )

        #expect(guidance.recommendedAction.id == MCPServerGuidance.openToolActionID)
        guard case let .unavailable(toolReason) = guidance.recommendedAction.availability else {
            Issue.record("Expected the primary tool action to be unavailable")
            return
        }
        guard case let .unavailable(sourceReason) = guidance.alternatives[0].availability else {
            Issue.record("Expected the source alternative to be unavailable")
            return
        }
        #expect(!toolReason.isEmpty)
        #expect(!sourceReason.isEmpty)
    }

    @Test func missingVariablesExplainWhenNeitherActionCanOpen() {
        let guidance = MCPServerGuidance.guidance(
            for: makeItem(missingEnvVarNames: ["SERVICE_API_KEY"]),
            canOpenTool: false,
            canOpenSource: false
        )

        #expect(guidance.recommendedAction.id == MCPServerGuidance.openToolActionID)
        guard case let .unavailable(toolReason) = guidance.recommendedAction.availability else {
            Issue.record("Expected the primary tool action to be unavailable")
            return
        }
        guard case let .unavailable(sourceReason) = guidance.alternatives[0].availability else {
            Issue.record("Expected the source alternative to be unavailable")
            return
        }
        #expect(!toolReason.isEmpty)
        #expect(!sourceReason.isEmpty)
    }

    @Test func actionAndEvidenceIdentifiersAreStableAndDeterministic() {
        let item = makeItem(missingEnvVarNames: ["SERVICE_API_KEY", "TEAM_ID"])
        let first = MCPServerGuidance.guidance(for: item, canOpenTool: true, canOpenSource: false)
        let second = MCPServerGuidance.guidance(for: item, canOpenTool: true, canOpenSource: false)

        #expect(MCPServerGuidance.openToolActionID == "mcp-inventory.action.open-tool")
        #expect(MCPServerGuidance.openSourceActionID == "mcp-inventory.action.open-source")
        #expect(first == second)
        #expect(first.technicalEvidence.map(\.id) == [
            "mcp-inventory.evidence.server",
            "mcp-inventory.evidence.tool",
            "mcp-inventory.evidence.transport",
            "mcp-inventory.evidence.configuration-summary",
            "mcp-inventory.evidence.missing-environment-variables",
        ])
        #expect(first.technicalEvidence.last?.sanitizedValue == "SERVICE_API_KEY, TEAM_ID")
    }

    @Test func serversWithTheSameStateRetainDistinctGuidanceIdentity() {
        let first = makeItem()
        var second = makeItem()
        second.name = "another-server"

        let firstGuidance = MCPServerGuidance.guidance(
            for: first,
            canOpenTool: true,
            canOpenSource: true
        )
        let secondGuidance = MCPServerGuidance.guidance(
            for: second,
            canOpenTool: true,
            canOpenSource: true
        )
        #expect(firstGuidance.id != secondGuidance.id)
    }

    @Test func guidanceUsesRedactedSummaryAndNamesWithoutLeakingExcludedFields() {
        let item = MCPServerInventoryItem(
            tool: .codex,
            name: "safe-server-name",
            scope: "scope-RAW-SECRET-VALUE",
            repositoryName: "repository-RAW-SECRET-VALUE",
            sourcePath: "/tmp/user:password@example.test/config?token=RAW-SECRET-VALUE",
            transport: .http,
            summary: "https://example.test/mcp",
            envVarNames: ["SERVICE_TOKEN"],
            missingEnvVarNames: ["SERVICE_TOKEN"],
            headerKeys: ["Authorization-RAW-SECRET-VALUE"]
        )
        let guidance = MCPServerGuidance.guidance(for: item, canOpenTool: true, canOpenSource: true)
        let rendered = allText(in: guidance)

        #expect(rendered.contains("safe-server-name"))
        #expect(rendered.contains("https://example.test/mcp"))
        #expect(rendered.contains("SERVICE_TOKEN"))
        #expect(!rendered.contains("RAW-SECRET-VALUE"))
        #expect(!rendered.contains("user:password@"))
        #expect(!rendered.contains("?token="))
    }

    @Test func evidenceRemovesControlsBoundsTextAndRejectsInvalidVariableNames() {
        let longSummary = String(repeating: "x", count: 300)
        let item = MCPServerInventoryItem(
            tool: .codex,
            name: "server\nname",
            scope: "User",
            repositoryName: "User",
            sourcePath: "/tmp/config.toml",
            transport: .stdio,
            summary: longSummary,
            envVarNames: [],
            missingEnvVarNames: ["VALID_NAME", "not valid\nRAW_SECRET"],
            headerKeys: []
        )

        let evidence = MCPServerGuidance.guidance(
            for: item,
            canOpenTool: true,
            canOpenSource: true
        ).technicalEvidence

        #expect(evidence[0].sanitizedValue == "server name")
        #expect(evidence[3].sanitizedValue.count == 240)
        #expect(evidence[3].sanitizedValue.hasSuffix("..."))
        #expect(evidence.last?.sanitizedValue == "VALID_NAME")
        #expect(!evidence.map(\.sanitizedValue).joined().contains("RAW_SECRET"))
    }

    private func makeItem(
        transport: MCPServerTransport = .stdio,
        missingEnvVarNames: [String] = []
    ) -> MCPServerInventoryItem {
        MCPServerInventoryItem(
            tool: .codex,
            name: "example-server",
            scope: "User",
            repositoryName: "User",
            sourcePath: "/tmp/config.toml",
            transport: transport,
            summary: "npx @example/mcp-server",
            envVarNames: ["SERVICE_API_KEY", "TEAM_ID"],
            missingEnvVarNames: missingEnvVarNames,
            headerKeys: []
        )
    }

    private func allText(in guidance: Guidance) -> String {
        let actions = [guidance.recommendedAction] + guidance.alternatives
        let actionText = actions.flatMap { action -> [String] in
            let reason: String
            switch action.availability {
            case .available:
                reason = ""
            case .notNeeded(let value), .unavailable(let value):
                reason = value
            }
            return [action.title, action.expectedResult, reason]
        }
        let evidenceText = guidance.technicalEvidence.flatMap { [$0.label, $0.sanitizedValue] }
        return ([guidance.explanation, guidance.relevance, guidance.consequence] + actionText + evidenceText)
            .joined(separator: "\n")
    }
}
