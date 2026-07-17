//
//  CodexMCPServer.swift
//  CodingBuddy
//

import Foundation

/// One `[mcp_servers.X]` entry from `~/.codex/config.toml` (read-only view).
nonisolated struct CodexMCPServer: Identifiable, Equatable, Hashable {
    /// TOML table key that identifies the server.
    var name: String
    /// Remote transport endpoint, when the server is URL-based.
    var url: String?
    /// Local executable used for a stdio server.
    var command: String?
    /// Arguments passed to the local executable in source order.
    var args: [String] = []
    /// Name of the env variable Codex reads the bearer token from.
    var bearerTokenEnvVar: String?
    /// Keys of the inline `env = { … }` table (values stay in the TOML).
    var inlineEnvKeys: [String] = []
    /// `env_vars` allowlist passed through from the Codex process env.
    var envVarAllowlist: [String] = []
    /// Effective state from the server table; Codex defaults an omitted value to enabled.
    var isEnabled: Bool = true

    /// Stable identity within the Codex MCP configuration.
    var id: String { name }

    /// Env variable names this server expects to exist in the environment.
    var referencedEnvVarNames: [String] {
        (bearerTokenEnvVar.map { [$0] } ?? []) + envVarAllowlist
    }
}
