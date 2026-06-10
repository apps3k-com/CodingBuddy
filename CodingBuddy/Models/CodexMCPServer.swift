//
//  CodexMCPServer.swift
//  CodingBuddy
//

import Foundation

/// One `[mcp_servers.X]` entry from `~/.codex/config.toml` (read-only view).
nonisolated struct CodexMCPServer: Identifiable, Equatable, Hashable {
    var name: String
    var url: String?
    var command: String?
    var args: [String] = []
    /// Name of the env variable Codex reads the bearer token from.
    var bearerTokenEnvVar: String?
    /// Keys of the inline `env = { … }` table (values stay in the TOML).
    var inlineEnvKeys: [String] = []
    /// `env_vars` allowlist passed through from the Codex process env.
    var envVarAllowlist: [String] = []

    var id: String { name }

    /// Env variable names this server expects to exist in the environment.
    var referencedEnvVarNames: [String] {
        (bearerTokenEnvVar.map { [$0] } ?? []) + envVarAllowlist
    }
}
