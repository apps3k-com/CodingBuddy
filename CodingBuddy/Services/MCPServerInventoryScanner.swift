//
//  MCPServerInventoryScanner.swift
//  CodingBuddy
//

import Foundation

/// Read-only scanner that normalizes MCP server definitions across supported tools.
///
/// The scanner reuses CodingBuddy's existing TOML/JSON readers and never
/// displays secret values. URL summaries strip user info, query strings, and
/// fragments; command summaries redact obvious token-bearing flag values.
nonisolated struct MCPServerInventoryScanner: Sendable {
    /// Home directory whose agent-tool configuration should be inspected.
    let homeDirectory: URL

    /// Filesystem access used for deterministic local reads.
    private var fileManager: FileManager { .default }

    /// Loads all supported MCP server definitions in stable display order.
    func items() -> [MCPServerInventoryItem] {
        (codexItems() + claudeCodeItems() + cursorItems())
            .sorted { lhs, rhs in
                (lhs.tool.displayName, lhs.scope, lhs.name, lhs.sourcePath)
                    < (rhs.tool.displayName, rhs.scope, rhs.name, rhs.sourcePath)
            }
    }

    /// Normalizes `~/.codex/config.toml` against `~/.codex/mcp.env`.
    private func codexItems() -> [MCPServerInventoryItem] {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        guard let configText = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }

        let envURL = codexDirectory.appendingPathComponent("mcp.env")
        let definedEnvNames = Set(
            (try? String(contentsOf: envURL, encoding: .utf8))
                .map(ShellConfigParser.assignments(in:))?
                .map(\.name) ?? []
        )

        return CodexConfigReader.servers(in: configText).map { server in
            let referenced = unique(server.referencedEnvVarNames)
            let missing = referenced.filter { !definedEnvNames.contains($0) }
            return MCPServerInventoryItem(
                tool: .codex,
                name: server.name,
                scope: String(localized: "User"),
                sourcePath: configURL.path,
                transport: .infer(type: nil, url: server.url, command: server.command),
                summary: summary(url: server.url, command: server.command, args: server.args),
                envVarNames: unique(referenced + server.inlineEnvKeys),
                missingEnvVarNames: missing,
                headerKeys: []
            )
        }
    }

    /// Normalizes user and existing-project Claude Code MCP definitions.
    private func claudeCodeItems() -> [MCPServerInventoryItem] {
        let claudeJSON = homeDirectory.appendingPathComponent(".claude.json")
        guard let text = try? String(contentsOf: claudeJSON, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any]
        else { return [] }

        var rows: [MCPServerInventoryItem] = []
        if let userServers = root["mcpServers"] as? [String: Any] {
            rows += MCPServersJSONReader.servers(fromDictionary: userServers, scope: userScope).map {
                item(from: $0, tool: .claudeCode, sourcePath: claudeJSON.path)
            }
        }

        for (path, value) in (root["projects"] as? [String: Any]) ?? [:] {
            guard fileManager.fileExists(atPath: path) else { continue }
            var projectServers: [MCPServerConfig] = []
            if let project = value as? [String: Any],
               let mcpServers = project["mcpServers"] as? [String: Any] {
                projectServers = MCPServersJSONReader.servers(fromDictionary: mcpServers, scope: path)
                rows += projectServers.map {
                    item(from: $0, tool: .claudeCode, sourcePath: claudeJSON.path)
                }
            }

            let namesFromClaudeJSON = Set(projectServers.map(\.name))
            let localMCPJSON = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            if let localText = try? String(contentsOf: localMCPJSON, encoding: .utf8) {
                rows += MCPServersJSONReader.servers(inDocument: localText, scope: path)
                    .filter { !namesFromClaudeJSON.contains($0.name) }
                    .map { item(from: $0, tool: .claudeCode, sourcePath: localMCPJSON.path) }
            }
        }
        return rows
    }

    /// Normalizes Cursor's user-level `~/.cursor/mcp.json`.
    private func cursorItems() -> [MCPServerInventoryItem] {
        let mcpJSON = homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("mcp.json")
        guard let text = try? String(contentsOf: mcpJSON, encoding: .utf8) else { return [] }
        return MCPServersJSONReader.servers(inDocument: text, scope: userScope).map {
            item(from: $0, tool: .cursor, sourcePath: mcpJSON.path)
        }
    }

    /// Converts a shared JSON MCP server model into an inventory row.
    private func item(from server: MCPServerConfig, tool: AITool, sourcePath: String) -> MCPServerInventoryItem {
        MCPServerInventoryItem(
            tool: tool,
            name: server.name,
            scope: server.scope == userScope ? String(localized: "User") : server.scope,
            sourcePath: sourcePath,
            transport: .infer(type: server.type, url: server.url, command: server.command),
            summary: summary(url: server.url, command: server.command, args: server.args),
            envVarNames: server.envKeys,
            missingEnvVarNames: [],
            headerKeys: server.headerKeys
        )
    }

    /// Internal unlocalized marker for user-level configuration.
    private var userScope: String { "user" }

    /// Returns unique values while preserving input order.
    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Builds a redacted transport summary for table display.
    private func summary(url: String?, command: String?, args: [String]) -> String {
        if let url {
            return sanitizedURL(url)
        }
        let parts = [command].compactMap(\.self) + redactedArgs(args)
        return parts.isEmpty ? String(localized: "Unknown") : parts.joined(separator: " ")
    }

    /// Removes credential-bearing URL parts before display.
    private func sanitizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              components.scheme != nil,
              components.host != nil
        else {
            return String(localized: "Invalid URL")
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? String(localized: "Invalid URL")
    }

    /// Redacts obvious token-bearing flag values without hiding useful package names.
    private func redactedArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var redactNext = false
        for arg in args {
            if redactNext {
                result.append("••••••••")
                redactNext = false
                continue
            }

            if looksAbsoluteURL(arg) {
                result.append(sanitizedURL(arg))
                continue
            }

            let flagName = arg
                .split(separator: "=", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-")) } ?? arg
            let normalizedFlagName = flagName.replacingOccurrences(of: "-", with: "_")
            if SecretDetector.isSensitive(name: normalizedFlagName) {
                if let equals = arg.firstIndex(of: "=") {
                    result.append(String(arg[...equals]) + "••••••••")
                } else {
                    result.append(arg)
                    redactNext = true
                }
            } else {
                result.append(sanitizedArgument(arg))
            }
        }
        return result
    }

    /// Sanitizes standalone URL arguments or `--flag=<url>` values.
    private func sanitizedArgument(_ value: String) -> String {
        if looksAbsoluteURL(value) {
            return sanitizedURL(value)
        }
        guard let equals = value.firstIndex(of: "=") else { return value }
        let prefix = String(value[...equals])
        let suffix = String(value[value.index(after: equals)...])
        guard looksAbsoluteURL(suffix) else { return value }
        return prefix + sanitizedURL(suffix)
    }

    /// Checks whether a value carries an absolute URL scheme before sanitizing.
    private func looksAbsoluteURL(_ value: String) -> Bool {
        guard let schemeSeparator = value.range(of: "://") else { return false }
        let scheme = value[..<schemeSeparator.lowerBound]
        guard !scheme.isEmpty else { return false }
        return scheme.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
        }
    }
}
