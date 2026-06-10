//
//  MCPServerConfig.swift
//  CodingBuddy
//

import Foundation

/// One entry of the common `mcpServers` JSON shape used by Claude Code
/// (`~/.claude.json`, `.mcp.json`) and Cursor (`~/.cursor/mcp.json`).
nonisolated struct MCPServerConfig: Identifiable, Equatable, Hashable {
    var name: String
    var url: String?
    var command: String?
    var args: [String] = []
    /// Keys of the `env` object (values stay in the source file).
    var envKeys: [String] = []
    /// Keys of the `headers` object.
    var headerKeys: [String] = []
    /// Where the definition lives: "user" or the project path.
    var scope: String

    var id: String { "\(scope)/\(name)" }
}
