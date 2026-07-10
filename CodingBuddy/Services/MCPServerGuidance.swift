//
//  MCPServerGuidance.swift
//  CodingBuddy
//

import Foundation

/// Deterministic plain-language guidance for read-only MCP inventory rows.
nonisolated enum MCPServerGuidance {
    /// Stable action identifier routed to the owning tool's MCP editor.
    static let openToolActionID = "mcp-inventory.action.open-tool"
    /// Stable action identifier routed to the server's configuration source.
    static let openSourceActionID = "mcp-inventory.action.open-source"

    /// Builds guidance from inventory state and the actions the current surface can perform.
    static func guidance(
        for item: MCPServerInventoryItem,
        canOpenTool: Bool,
        canOpenSource: Bool
    ) -> Guidance {
        if item.hasMissingEnvVars {
            return missingEnvironmentGuidance(
                for: item,
                canOpenTool: canOpenTool,
                canOpenSource: canOpenSource
            )
        }

        if item.transport == .unknown {
            return unknownTransportGuidance(
                for: item,
                canOpenTool: canOpenTool,
                canOpenSource: canOpenSource
            )
        }

        return configuredGuidance(for: item)
    }

    /// Missing variables take priority because they can prevent startup or authentication.
    private static func missingEnvironmentGuidance(
        for item: MCPServerInventoryItem,
        canOpenTool: Bool,
        canOpenSource: Bool
    ) -> Guidance {
        let toolAction = openToolAction(isAvailable: canOpenTool)
        let sourceAction = openSourceAction(isAvailable: canOpenSource)
        let recommendation: RecommendedAction
        let alternatives: [RecommendedAction]

        if canOpenTool {
            recommendation = toolAction
            alternatives = [sourceAction]
        } else if canOpenSource {
            recommendation = sourceAction
            alternatives = [toolAction]
        } else {
            recommendation = toolAction
            alternatives = [sourceAction]
        }

        return Guidance(
            id: guidanceID(state: "missing-environment-variables", item: item),
            explanation: String(
                localized: "MCP guidance missing environment variables explanation",
                defaultValue:
                    "CodingBuddy could not find one or more environment variables referenced by this MCP server."
            ),
            relevance: String(
                localized: "MCP guidance missing environment variables relevance",
                defaultValue: "The owning tool may need these variables to start the server or authenticate with it."
            ),
            consequence: String(
                localized: "MCP guidance missing environment variables consequence",
                defaultValue:
                    "The server may fail to start, or authentication may fail, until the missing variables are defined."
            ),
            recommendedAction: recommendation,
            alternatives: alternatives,
            technicalEvidence: evidence(for: item),
            glossaryTerms: [.mcp, .scope]
        )
    }

    /// Unknown transport is a warning, not a claim that the server is healthy.
    private static func unknownTransportGuidance(
        for item: MCPServerInventoryItem,
        canOpenTool: Bool,
        canOpenSource: Bool
    ) -> Guidance {
        let toolAction = openToolAction(isAvailable: canOpenTool)
        let sourceAction = openSourceAction(isAvailable: canOpenSource)
        let recommendation: RecommendedAction
        let alternatives: [RecommendedAction]

        if canOpenSource {
            recommendation = sourceAction
            alternatives = [toolAction]
        } else {
            recommendation = toolAction
            alternatives = [sourceAction]
        }

        return Guidance(
            id: guidanceID(state: "unknown-transport", item: item),
            explanation: String(
                localized: "MCP guidance unknown transport explanation",
                defaultValue: "This server configuration does not identify a transport CodingBuddy recognizes."
            ),
            relevance: String(
                localized: "MCP guidance unknown transport relevance",
                defaultValue:
                    "Without a known transport, CodingBuddy cannot confirm how the owning tool should start or contact the server."
            ),
            consequence: String(
                localized: "MCP guidance unknown transport consequence",
                defaultValue:
                    "The owning tool may be unable to use the server, or the configuration may use a transport CodingBuddy does not understand."
            ),
            recommendedAction: recommendation,
            alternatives: alternatives,
            technicalEvidence: evidence(for: item),
            glossaryTerms: [.mcp, .scope]
        )
    }

    /// A configured row remains honest about checks the inventory does not perform.
    private static func configuredGuidance(for item: MCPServerInventoryItem) -> Guidance {
        Guidance(
            id: guidanceID(state: "configured", item: item),
            explanation: String(
                localized: "MCP guidance configured explanation",
                defaultValue:
                    "CodingBuddy recognized this server's transport and found no environment variables that it can prove are missing."
            ),
            relevance: String(
                localized: "MCP guidance configured relevance",
                defaultValue:
                    "This is a configuration-only result. CodingBuddy has not tested network reachability or authentication."
            ),
            consequence: String(
                localized: "MCP guidance configured consequence",
                defaultValue:
                    "The server can still fail at runtime if its process, network endpoint, or authentication is unavailable."
            ),
            recommendedAction: RecommendedAction(
                id: "mcp-inventory.action.not-needed",
                title: String(
                    localized: "MCP guidance no configuration change title",
                    defaultValue: "No issue detected by this scan"
                ),
                expectedResult: String(
                    localized: "MCP guidance no configuration change expected result",
                    defaultValue:
                        "No follow-up is required from the local evidence this inventory can check."
                ),
                effort: .low,
                safetyClass: .readOnly,
                availability: .notNeeded(
                    reason: String(
                        localized: "MCP guidance no configuration change reason",
                        defaultValue: "CodingBuddy found no configuration issue it can prove from this inventory data."
                    )
                )
            ),
            alternatives: [],
            technicalEvidence: evidence(for: item),
            glossaryTerms: [.mcp, .scope]
        )
    }

    /// Read-only action that opens the owning tool when that editor exists.
    private static func openToolAction(isAvailable: Bool) -> RecommendedAction {
        RecommendedAction(
            id: openToolActionID,
            title: String(localized: "Open Tool"),
            expectedResult: String(
                localized: "MCP guidance open tool expected result",
                defaultValue: "The owning tool's MCP configuration opens for inspection."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable
                ? .available
                : .unavailable(
                    reason: String(
                        localized: "MCP guidance open tool unavailable reason",
                        defaultValue: "CodingBuddy does not have a configuration view for this tool."
                    )
                )
        )
    }

    /// Read-only action that opens the existing local configuration source.
    private static func openSourceAction(isAvailable: Bool) -> RecommendedAction {
        RecommendedAction(
            id: openSourceActionID,
            title: String(localized: "Open Source"),
            expectedResult: String(
                localized: "MCP guidance open source expected result",
                defaultValue: "The configuration source opens for inspection."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable
                ? .available
                : .unavailable(
                    reason: String(
                        localized: "MCP guidance open source unavailable reason",
                        defaultValue: "The configuration source is not an existing local file."
                    )
                )
        )
    }

    /// Evidence is limited to identifier names and the scanner's redacted summary.
    private static func evidence(for item: MCPServerInventoryItem) -> [TechnicalEvidence] {
        var evidence = [
            TechnicalEvidence(
                id: "mcp-inventory.evidence.server",
                label: String(localized: "Server"),
                sanitizedValue: sanitizedDisplayValue(item.name)
            ),
            TechnicalEvidence(
                id: "mcp-inventory.evidence.tool",
                label: String(localized: "Tool"),
                sanitizedValue: item.tool.displayName
            ),
            TechnicalEvidence(
                id: "mcp-inventory.evidence.transport",
                label: String(localized: "Transport"),
                sanitizedValue: item.transport.displayName
            ),
            TechnicalEvidence(
                id: "mcp-inventory.evidence.configuration-summary",
                label: String(localized: "Command / URL"),
                sanitizedValue: sanitizedDisplayValue(item.summary)
            ),
        ]

        let missingVariableNames = item.missingEnvVarNames.filter(isEnvironmentVariableName)
        if !missingVariableNames.isEmpty {
            evidence.append(
                TechnicalEvidence(
                    id: "mcp-inventory.evidence.missing-environment-variables",
                    label: String(localized: "Missing variables"),
                    sanitizedValue: sanitizedDisplayValue(missingVariableNames.joined(separator: ", "))
                )
            )
        }
        return evidence
    }

    /// Removes control characters and bounds configuration-derived display text.
    private static func sanitizedDisplayValue(_ value: String) -> String {
        let withoutControls = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
        let collapsedWhitespace = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let maximumLength = 240

        guard collapsedWhitespace.count > maximumLength else { return collapsedWhitespace }
        return String(collapsedWhitespace.prefix(maximumLength - 3)) + "..."
    }

    /// Accepts only names with the portable environment-variable shape used by providers.
    private static func isEnvironmentVariableName(_ value: String) -> Bool {
        guard let first = value.utf8.first, isASCIILetter(first) || first == 95 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIILetter(byte) || (48...57).contains(byte) || byte == 95
        }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Combines the observed state with the inventory row identity for aggregation and SwiftUI.
    private static func guidanceID(state: String, item: MCPServerInventoryItem) -> String {
        "mcp-inventory.guidance.\(state).\(item.id)"
    }
}
