import Foundation

/// Groups a discovered agent context entry by its role in the repository.
nonisolated enum AgentContextKind: String, CaseIterable, Sendable {
    /// Top-level agent governance files such as AGENTS.md or CLAUDE.md.
    case governance

    /// Cursor-specific rule configuration.
    case cursorRules

    /// Project-local MCP server configuration.
    case mcpConfig

    /// Project-local Codex configuration.
    case codexConfig

    /// Repository documentation that may contain developer setup guidance.
    case documentation

    /// Human-readable name for the context kind.
    var displayName: String {
        switch self {
        case .governance:
            String(localized: "Governance")
        case .cursorRules:
            String(localized: "Cursor Rules")
        case .mcpConfig:
            String(localized: "MCP Config")
        case .codexConfig:
            String(localized: "Codex Config")
        case .documentation:
            String(localized: "Documentation")
        }
    }
}

/// Describes the file-system shape of a context entry.
nonisolated enum AgentContextEntryType: String, CaseIterable, Sendable {
    /// A regular file.
    case file

    /// A directory.
    case directory

    /// A symbolic link.
    case symlink

    /// An expected entry that is not present.
    case missing

    /// An entry exists, but does not match a supported file-system type.
    case unexpected

    /// Human-readable name for the entry type.
    var displayName: String {
        switch self {
        case .file:
            String(localized: "File")
        case .directory:
            String(localized: "Directory")
        case .symlink:
            String(localized: "Symlink")
        case .missing:
            String(localized: "Missing")
        case .unexpected:
            String(localized: "Unexpected")
        }
    }
}

/// Deterministic signals raised by the agent context scanner.
nonisolated enum AgentContextWarningCode: String, CaseIterable, Sendable {
    /// AGENTS.md is absent from the selected repository root.
    case missingAgentsMarkdown

    /// CLAUDE.md is absent from the selected repository root.
    case missingClaudeMarkdown

    /// AGENTS.md and CLAUDE.md both exist, so users may need to align the rules.
    case bothGovernanceFilesPresent

    /// A discovered file has zero bytes.
    case emptyFile

    /// A discovered file is larger than the deterministic size threshold.
    case oversizedFile

    /// A project-local .mcp.json file exists.
    case projectLocalMCPConfigPresent

    /// A project-local .codex entry exists.
    case codexProjectConfigPresent

    /// The entry exists, but it is neither a regular file, directory, nor symlink.
    case unexpectedType

    /// The entry is a symlink and is reported without traversing the target.
    case symlinkNotTraversed

    /// Severity used for visual grouping and badge counts.
    var severity: AgentDiagnosticSeverity {
        switch self {
        case .projectLocalMCPConfigPresent, .codexProjectConfigPresent:
            .info
        default:
            .warning
        }
    }

    /// Human-readable signal name.
    var displayName: String {
        switch self {
        case .missingAgentsMarkdown:
            String(localized: "Missing AGENTS.md")
        case .missingClaudeMarkdown:
            String(localized: "Missing CLAUDE.md")
        case .bothGovernanceFilesPresent:
            String(localized: "Both governance files present")
        case .emptyFile:
            String(localized: "Empty file")
        case .oversizedFile:
            String(localized: "Large file")
        case .projectLocalMCPConfigPresent:
            String(localized: "Project MCP config present")
        case .codexProjectConfigPresent:
            String(localized: "Codex project config present")
        case .unexpectedType:
            String(localized: "Unexpected file type")
        case .symlinkNotTraversed:
            String(localized: "Symlink target not inspected")
        }
    }
}

/// A discovered or expected agent context entry in a selected repository.
nonisolated struct AgentContextItem: Identifiable, Equatable, Hashable, Sendable {
    /// Repository-relative path shown to the user.
    let relativePath: String

    /// Absolute URL for present entries or the expected URL for missing entries.
    let url: URL

    /// Semantic grouping used by the inspector UI.
    let kind: AgentContextKind

    /// File-system shape of the entry.
    let entryType: AgentContextEntryType

    /// File size in bytes when available.
    let byteCount: Int?

    /// Last modification date when available.
    let modifiedAt: Date?

    /// Deterministic scanner signals for this entry.
    let warnings: [AgentContextWarningCode]

    /// Stable identifier for SwiftUI table selection.
    var id: String { relativePath }

    /// Whether this entry exists on disk.
    var exists: Bool { entryType != .missing }

    /// Returns true when the item matches a free-text filter.
    func matches(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let haystack = [
            relativePath,
            kind.rawValue,
            kind.displayName,
            entryType.rawValue,
            entryType.displayName,
            warnings.map(\.rawValue).joined(separator: " "),
            warnings.map(\.displayName).joined(separator: " ")
        ]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(trimmed)

        return haystack
    }
}
