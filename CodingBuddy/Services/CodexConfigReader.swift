//
//  CodexConfigReader.swift
//  CodingBuddy
//

import Foundation

/// Maps the parsed `~/.codex/config.toml` onto the MCP servers it defines.
nonisolated enum CodexConfigReader {

    static func servers(in tomlText: String) -> [CodexMCPServer] {
        let table = TOMLReader.parse(tomlText)
        guard let mcpServers = table.table(at: ["mcp_servers"]) else { return [] }

        // Subtables like [mcp_servers.X.tools.Y] nest INSIDE their server's
        // table, so iterating the direct children yields servers only.
        return mcpServers.compactMap { name, value -> CodexMCPServer? in
            guard case .table(let serverValues) = value else { return nil }
            let server = TOMLTable(values: serverValues)
            return CodexMCPServer(
                name: name,
                url: server.string(at: ["url"]),
                command: server.string(at: ["command"]),
                args: server.stringArray(at: ["args"]) ?? [],
                bearerTokenEnvVar: server.string(at: ["bearer_token_env_var"]),
                inlineEnvKeys: (server.table(at: ["env"]) ?? [:]).keys.sorted(),
                envVarAllowlist: server.stringArray(at: ["env_vars"]) ?? []
            )
        }
        .sorted { $0.name < $1.name }
    }
}
