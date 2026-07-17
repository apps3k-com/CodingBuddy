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
        let mcpServers: [String: TOMLValue]
        switch table.value(at: ["mcp_servers"]) {
        case nil:
            return CodexConfigReadResult(serverResults: [], isComplete: true)
        case .table(let values):
            mcpServers = values
        default:
            return CodexConfigReadResult(serverResults: [], isComplete: false)
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

            let url = optionalString(in: server, at: ["url"])
            let command = optionalString(in: server, at: ["command"])
            let arguments = optionalStringArray(in: server, at: ["args"])
            let bearerTokenEnvVar = optionalString(in: server, at: ["bearer_token_env_var"])
            let inlineEnvironment = optionalStringTableKeys(in: server, at: ["env"])
            let serverIsComplete = enabled != nil
                && hasValidEnvVarAllowlist
                && url.isValid
                && command.isValid
                && arguments.isValid
                && bearerTokenEnvVar.isValid
                && inlineEnvironment.isValid
            isComplete = isComplete && serverIsComplete
            let mappedServer = CodexMCPServer(
                name: name,
                url: url.value,
                command: command.value,
                args: arguments.value ?? [],
                bearerTokenEnvVar: bearerTokenEnvVar.value,
                inlineEnvKeys: inlineEnvironment.value ?? [],
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

    /// Distinguishes an omitted optional string from a present value of the wrong type.
    private static func optionalString(
        in table: TOMLTable,
        at path: [String]
    ) -> (value: String?, isValid: Bool) {
        switch table.value(at: path) {
        case nil:
            return (nil, true)
        case .string(let value):
            return (value, true)
        default:
            return (nil, false)
        }
    }

    /// Distinguishes an omitted string array from malformed or mixed arrays.
    private static func optionalStringArray(
        in table: TOMLTable,
        at path: [String]
    ) -> (value: [String]?, isValid: Bool) {
        switch table.value(at: path) {
        case nil:
            return (nil, true)
        case .array:
            guard let values = table.stringArray(at: path) else { return (nil, false) }
            return (values, true)
        default:
            return (nil, false)
        }
    }

    /// Returns inline environment names only when the table contains string values throughout.
    private static func optionalStringTableKeys(
        in table: TOMLTable,
        at path: [String]
    ) -> (value: [String]?, isValid: Bool) {
        switch table.value(at: path) {
        case nil:
            return (nil, true)
        case .table(let values):
            guard values.values.allSatisfy({ value in
                if case .string = value { return true }
                return false
            }) else {
                return (nil, false)
            }
            return (values.keys.sorted(), true)
        default:
            return (nil, false)
        }
    }
}
