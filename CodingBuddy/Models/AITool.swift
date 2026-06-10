//
//  AITool.swift
//  CodingBuddy
//

import Foundation

/// AI coding tools with their own sidebar section. Cases are added as the
/// corresponding sections ship (Claude Code, Cursor, Craft Agents follow).
nonisolated enum AITool: String, CaseIterable, Identifiable, Hashable {
    case codex

    var id: String { rawValue }

    /// Product names are proper nouns — displayed verbatim, not localized.
    var displayName: String {
        switch self {
        case .codex: "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "terminal"
        }
    }

    var featureFlag: FeatureFlag {
        switch self {
        case .codex: .aiToolsCodex
        }
    }
}
