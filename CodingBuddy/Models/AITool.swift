//
//  AITool.swift
//  CodingBuddy
//

import Foundation

/// AI coding tools with their own sidebar section. Cases are added as the
/// corresponding sections ship (Claude Code, Cursor, Craft Agents follow).
nonisolated enum AITool: String, CaseIterable, Identifiable, Hashable {
    case codex
    case claudeCode
    case cursor

    var id: String { rawValue }

    /// Product names are proper nouns — displayed verbatim, not localized.
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "terminal"
        case .claudeCode: "bubble.left.and.bubble.right"
        case .cursor: "cursorarrow"
        }
    }

    var featureFlag: FeatureFlag {
        switch self {
        case .codex: .aiToolsCodex
        case .claudeCode: .aiToolsClaudeCode
        case .cursor: .aiToolsCursor
        }
    }
}
