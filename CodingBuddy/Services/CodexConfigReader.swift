//
//  CodexConfigReader.swift
//  CodingBuddy
//

import Foundation

/// One Codex MCP server plus the schema evidence needed for conservative scanning.
nonisolated struct CodexMCPServerReadResult: Equatable {
    /// Supported fields retained for inventory display.
    let server: CodexMCPServer
    /// Effective enabled state, or nil when an explicitly configured value has the wrong type.
    let enabledState: Bool?
    /// Whether all supported fields on this server have valid schema types.
    let isComplete: Bool
}

/// Codex MCP extraction plus syntax and schema completeness.
nonisolated struct CodexConfigReadResult: Equatable {
    /// Direct MCP server declarations in deterministic name order.
    let serverResults: [CodexMCPServerReadResult]
    /// False when TOML parsing or supported Codex field validation was incomplete.
    let isComplete: Bool

    /// Compatibility view for callers that do not consume diagnostics.
    var servers: [CodexMCPServer] { serverResults.map(\.server) }
}

/// Maps the parsed `~/.codex/config.toml` onto the MCP servers it defines.
nonisolated enum CodexConfigReader {

    /// Extracts direct MCP server tables, ignoring unrelated and nested tool tables.
    static func servers(in tomlText: String) -> [CodexMCPServer] {
        read(tomlText).servers
    }

    /// Maps an already parsed table so security scans do not parse bounded input twice.
    static func servers(in table: TOMLTable) -> [CodexMCPServer] {
        read(in: table).servers
    }

    /// Parses TOML and preserves both parser and Codex schema diagnostics.
    static func read(_ tomlText: String) -> CodexConfigReadResult {
        read(TOMLReader.parseWithDiagnostics(tomlText))
    }

    /// Maps an existing parse result without parsing bounded input twice.
    static func read(_ parseResult: TOMLParseResult) -> CodexConfigReadResult {
        let semanticResult = read(in: parseResult.table)
        return CodexConfigReadResult(
            serverResults: semanticResult.serverResults,
            isComplete: parseResult.isComplete && semanticResult.isComplete
        )
    }

    /// Validates supported Codex field types while retaining usable server metadata.
    static func read(in table: TOMLTable) -> CodexConfigReadResult {
        guard let mcpServers = table.table(at: ["mcp_servers"]) else {
            return CodexConfigReadResult(serverResults: [], isComplete: true)
        }

        // Subtables like [mcp_servers.X.tools.Y] nest INSIDE their server's
        // table, so iterating the direct children yields servers only.
        var results: [CodexMCPServerReadResult] = []
        var isComplete = true
        for name in mcpServers.keys.sorted() {
            guard case .table(let serverValues) = mcpServers[name] else {
                isComplete = false
                continue
            }
            let server = TOMLTable(values: serverValues)

            let enabled: Bool?
            switch server.value(at: ["enabled"]) {
            case nil:
                enabled = true
            case .bool(let value):
                enabled = value
            default:
                enabled = nil
            }

            let envVarAllowlist: [String]
            let hasValidEnvVarAllowlist: Bool
            switch server.value(at: ["env_vars"]) {
            case nil:
                envVarAllowlist = []
                hasValidEnvVarAllowlist = true
            case .array:
                if let values = server.stringArray(at: ["env_vars"]) {
                    envVarAllowlist = values
                    hasValidEnvVarAllowlist = true
                } else {
                    envVarAllowlist = []
                    hasValidEnvVarAllowlist = false
                }
            default:
                envVarAllowlist = []
                hasValidEnvVarAllowlist = false
            }

            let serverIsComplete = enabled != nil && hasValidEnvVarAllowlist
            isComplete = isComplete && serverIsComplete
            let mappedServer = CodexMCPServer(
                name: name,
                url: server.string(at: ["url"]),
                command: server.string(at: ["command"]),
                args: server.stringArray(at: ["args"]) ?? [],
                bearerTokenEnvVar: server.string(at: ["bearer_token_env_var"]),
                inlineEnvKeys: (server.table(at: ["env"]) ?? [:]).keys.sorted(),
                envVarAllowlist: envVarAllowlist,
                isEnabled: enabled ?? false
            )
            results.append(CodexMCPServerReadResult(
                server: mappedServer,
                enabledState: enabled,
                isComplete: serverIsComplete
            ))
        }
        return CodexConfigReadResult(serverResults: results, isComplete: isComplete)
    }
}
