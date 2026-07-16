//
//  AITool.swift
//  CodingBuddy
//

import Foundation

/// AI coding tools with their own sidebar section. Cases are added as the
/// corresponding sections ship (Claude Code, Cursor, Craft Agents follow).
nonisolated enum AITool: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// OpenAI Codex configuration and diagnostics.
    case codex
    /// Anthropic Claude Code configuration and diagnostics.
    case claudeCode
    /// Cursor editor configuration and diagnostics.
    case cursor
    /// Craft Agents configuration and diagnostics.
    case craftAgents

    /// Stable persistence and selection identity.
    var id: String { rawValue }

    /// Product names are proper nouns — displayed verbatim, not localized.
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .craftAgents: "Craft Agents"
        }
    }

    /// SF Symbol used to distinguish the tool in navigation.
    var systemImage: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode: "bubble.left.and.bubble.right"
        case .cursor: "cursorarrow"
        case .craftAgents: "sparkles"
        }
    }

    /// Feature flag that controls whether the tool's section is available.
    var featureFlag: FeatureFlag {
        switch self {
        case .codex: .aiToolsCodex
        case .claudeCode: .aiToolsClaudeCode
        case .cursor: .aiToolsCursor
        case .craftAgents: .aiToolsCraftAgent
        }
    }
}
