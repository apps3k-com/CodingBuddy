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
                repositoryName: String(localized: "User"),
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

            let localMCPJSON = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            if let localText = try? String(contentsOf: localMCPJSON, encoding: .utf8) {
                rows += MCPServersJSONReader.servers(inDocument: localText, scope: path)
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
            repositoryName: repositoryName(for: server.scope),
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

    /// Derives a stable repository/workspace name for display without shelling out.
    private func repositoryName(for scope: String) -> String {
        guard scope != userScope else { return String(localized: "User") }
        let scopeURL = URL(fileURLWithPath: scope).standardizedFileURL
        if let gitRoot = nearestGitRoot(from: scopeURL) {
            return gitRoot.lastPathComponent
        }
        return scopeURL.lastPathComponent.isEmpty ? String(localized: "Unknown") : scopeURL.lastPathComponent
    }

    /// Walks from a project path to the nearest valid `.git` directory or gitdir file.
    private func nearestGitRoot(from url: URL) -> URL? {
        var current = url
        while current.path != current.deletingLastPathComponent().path {
            switch gitMarkerState(at: current.appendingPathComponent(".git")) {
            case .valid:
                return current
            case .invalid:
                return nil
            case .missing:
                current.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// Filesystem state for a potential `.git` marker.
    private enum GitMarkerState {
        /// No marker exists at the inspected path.
        case missing
        /// The marker proves the current folder is a Git root.
        case valid
        /// A marker exists but is unsafe or malformed.
        case invalid
    }

    /// Classifies `.git` as absent, a valid directory/gitdir file, or an unsafe marker.
    private func gitMarkerState(at url: URL) -> GitMarkerState {
        if isSymbolicLink(url) {
            return .invalid
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }

        if isDirectory.boolValue {
            return .valid
        }

        return isValidGitdirFile(url) ? .valid : .invalid
    }

    /// Returns true when the URL is a symbolic link entry.
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Validates the `.git` file format used by Git worktrees.
    private func isValidGitdirFile(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else {
            return false
        }

        let rawPath = trimmed
            .dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return false
        }

        let targetURL = URL(
            fileURLWithPath: rawPath,
            relativeTo: url.deletingLastPathComponent()
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

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
        var redactHeaderNext = false
        for arg in args {
            if redactNext {
                result.append("••••••••")
                redactNext = false
                continue
            }

            if redactHeaderNext {
                result.append(redactedHeader(arg))
                redactHeaderNext = false
                continue
            }

            if arg == "-H" || arg == "--header" {
                result.append(arg)
                redactHeaderNext = true
                continue
            }

            if arg.hasPrefix("--header=") {
                let value = String(arg.dropFirst("--header=".count))
                result.append("--header=" + redactedHeader(value))
                continue
            }

            if arg.hasPrefix("-H"), arg.count > 2 {
                let attached = String(arg.dropFirst(2))
                if attached.hasPrefix("=") {
                    result.append("-H=" + redactedHeader(String(attached.dropFirst())))
                } else {
                    result.append("-H" + redactedHeader(attached))
                }
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

    /// Masks credential-bearing header values while retaining safe header names and values.
    private func redactedHeader(_ value: String) -> String {
        guard let colon = value.firstIndex(of: ":") else { return "••••••••" }
        let name = String(value[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "••••••••" }
        guard !isSensitiveHeaderName(name) else {
            return "\(name): ••••••••"
        }
        let headerValue = String(value[value.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        let sanitizedValue = sanitizedArgument(headerValue)
        if headerValue.contains("://"), sanitizedValue == headerValue {
            return "\(name): ••••••••"
        }
        guard !sanitizedValue.isEmpty else { return "\(name):" }
        return "\(name): \(sanitizedValue)"
    }

    /// Classifies standard authentication headers and token-like custom header names.
    private func isSensitiveHeaderName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        let knownSensitiveNames: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
        ]
        guard !knownSensitiveNames.contains(normalized) else { return true }

        let detectorName = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return SecretDetector.isSensitive(name: detectorName)
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
