//
//  AgentDiagnostic.swift
//  CodingBuddy
//

import Foundation

/// Severity levels used by Agent Doctor findings.
nonisolated enum AgentDiagnosticSeverity: String, CaseIterable, Sendable {
    /// A finding that points to a broken configuration file or unusable state.
    case error
    /// A finding that can break one workflow but does not make the tool unreadable.
    case warning
    /// A finding that explains missing optional setup without requiring action.
    case info
}

/// Agentic-coding tool or local subsystem that produced a diagnostic.
nonisolated enum AgentDiagnosticTool: String, CaseIterable, Sendable {
    /// The user's zsh startup files and shell environment.
    case zsh
    /// OpenAI Codex local configuration.
    case codex
    /// Claude Code local configuration.
    case claudeCode
    /// Cursor local configuration.
    case cursor
    /// Craft Agents local configuration.
    case craftAgents
    /// The shared `mcp-remote` OAuth credential cache.
    case mcpAuth

    /// Human-readable product name for table labels and navigation badges.
    var displayName: String {
        switch self {
        case .zsh: String(localized: "zsh")
        case .codex: String(localized: "Codex")
        case .claudeCode: String(localized: "Claude Code")
        case .cursor: String(localized: "Cursor")
        case .craftAgents: String(localized: "Craft Agents")
        case .mcpAuth: String(localized: "MCP Auth")
        }
    }
}

/// Stable diagnostic kind; tests assert these instead of localized prose.
nonisolated enum AgentDiagnosticCode: String, CaseIterable, Sendable {
    /// Expected tool configuration directory is absent.
    case missingDirectory
    /// None of the zsh startup files managed by CodingBuddy exist.
    case missingZshStartupFiles
    /// A JSON configuration file exists but cannot be parsed as JSON.
    case invalidConfigFile
    /// A config references an environment variable that its environment file does not define.
    case missingReferencedEnvVar
    /// A credential-bearing file is readable or writable by more users than expected.
    case unsafePermissions
    /// A cached OAuth access token has expired.
    case expiredCredential
    /// An OAuth cache entry exists without the token file needed for a complete login.
    case incompleteCredential
}

/// One read-only Agent Doctor finding. It intentionally stores metadata and
/// localized summary text only — never secret values.
nonisolated struct AgentDiagnostic: Identifiable, Equatable, Hashable, Sendable {
    /// Machine-readable diagnostic category.
    let code: AgentDiagnosticCode
    /// Severity used for filtering, badges, and table iconography.
    let severity: AgentDiagnosticSeverity
    /// Tool or subsystem that owns the finding.
    let tool: AgentDiagnosticTool
    /// Localized one-line finding title.
    let title: String
    /// Localized short explanation for the finding.
    let detail: String
    /// Non-secret source identifier such as a path or credential hash.
    let source: String
    /// Optional non-secret subject such as an environment variable name or file mode.
    let subject: String?
    /// Localized next action shown to the user.
    let suggestion: String

    /// Stable identity for SwiftUI table selection and diffing.
    var id: String {
        [tool.rawValue, code.rawValue, source, subject ?? ""].joined(separator: "|")
    }

    /// Creates an informational finding for a tool directory that does not exist yet.
    static func missingDirectory(tool: AgentDiagnosticTool, path: String) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .missingDirectory,
            severity: .info,
            tool: tool,
            title: String(localized: "Configuration directory missing"),
            detail: String(localized: "\(tool.displayName) has not created its configuration directory yet."),
            source: path,
            subject: nil,
            suggestion: String(localized: "Set up the tool first, then refresh Agent Doctor.")
        )
    }

    /// Creates an informational finding when no managed zsh startup file exists.
    static func missingZshStartupFiles(homePath: String, files: String) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .missingZshStartupFiles,
            severity: .info,
            tool: .zsh,
            title: String(localized: "No zsh startup files found"),
            detail: String(localized: "CodingBuddy did not find any managed zsh startup file in this home directory."),
            source: homePath,
            subject: files,
            suggestion: String(localized: "Create a zsh startup file or add your first variable in CodingBuddy.")
        )
    }

    /// Creates an error finding for an unreadable JSON configuration file.
    static func invalidConfigFile(tool: AgentDiagnosticTool, path: String) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .invalidConfigFile,
            severity: .error,
            tool: tool,
            title: String(localized: "Configuration file is not valid JSON"),
            detail: String(localized: "CodingBuddy could not parse this configuration file."),
            source: path,
            subject: nil,
            suggestion: String(localized: "Open the file and fix the JSON syntax.")
        )
    }

    /// Creates a warning for a referenced environment variable that is not defined locally.
    static func missingReferencedEnvVar(
        tool: AgentDiagnosticTool,
        name: String,
        source: String
    ) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .missingReferencedEnvVar,
            severity: .warning,
            tool: tool,
            title: String(localized: "Referenced environment variable is missing"),
            detail: String(localized: "\(tool.displayName) references \(name), but CodingBuddy cannot find it in the tool environment file."),
            source: source,
            subject: name,
            suggestion: String(localized: "Define the variable in the matching tool environment file.")
        )
    }

    /// Creates a warning for a credential file with broader permissions than expected.
    static func unsafePermissions(
        tool: AgentDiagnosticTool,
        path: String,
        actualMode: String,
        expectedMode: String
    ) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .unsafePermissions,
            severity: .warning,
            tool: tool,
            title: String(localized: "Credential file permissions are too broad"),
            detail: String(localized: "Current mode is \(actualMode); expected \(expectedMode)."),
            source: path,
            subject: actualMode,
            suggestion: String(localized: "Restrict the file so only your user can read and write it.")
        )
    }

    /// Creates a warning for a cached OAuth credential whose access token is expired.
    static func expiredCredential(tool: AgentDiagnosticTool, name: String, source: String) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .expiredCredential,
            severity: .warning,
            tool: tool,
            title: String(localized: "OAuth access token appears expired"),
            detail: String(localized: "The cached MCP credential may need a fresh login."),
            source: source,
            subject: name,
            suggestion: String(localized: "Reset the entry in MCP Auth if the server no longer connects.")
        )
    }

    /// Creates a warning for an OAuth cache entry that is missing its tokens file.
    static func incompleteCredential(tool: AgentDiagnosticTool, name: String, source: String) -> AgentDiagnostic {
        AgentDiagnostic(
            code: .incompleteCredential,
            severity: .warning,
            tool: tool,
            title: String(localized: "OAuth login cache is incomplete"),
            detail: String(localized: "The MCP Auth entry has no tokens file."),
            source: source,
            subject: name,
            suggestion: String(localized: "Reset the entry and reconnect the MCP server.")
        )
    }
}
