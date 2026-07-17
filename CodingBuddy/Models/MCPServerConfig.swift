//
//  MCPServerConfig.swift
//  CodingBuddy
//

import Foundation

/// One entry of the common `mcpServers` JSON shape used by Claude Code
/// (`~/.claude.json`, `.mcp.json`) and Cursor (`~/.cursor/mcp.json`).
nonisolated struct MCPServerConfig: Identifiable, Equatable, Hashable {
    /// JSON object key that identifies the server.
    var name: String
    /// Optional transport hint from JSON, e.g. `http` or `stdio`.
    var type: String?
    /// Remote transport endpoint, when the server is URL-based.
    var url: String?
    /// Local executable used for a stdio server.
    var command: String?
    /// Arguments passed to the local executable in source order.
    var args: [String] = []
    /// Keys of the `env` object (values stay in the source file).
    var envKeys: [String] = []
    /// Keys of the `headers` object.
    var headerKeys: [String] = []
    /// Where the definition lives: "user" or the project path.
    var scope: String

    /// Identity that keeps user and repository definitions distinct.
    var id: String { "\(scope)/\(name)" }
}
