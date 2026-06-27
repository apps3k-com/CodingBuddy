//
//  AgentDoctorScanner.swift
//  CodingBuddy
//

import Foundation

/// Read-only health scanner for local agentic-coding configuration.
///
/// The scanner is deliberately deterministic: it inspects files CodingBuddy
/// already understands and returns metadata-only findings. It never executes
/// tools, probes networks, or reads secret values into diagnostic text.
nonisolated struct AgentDoctorScanner: Sendable {
    /// Home directory whose dot-directories should be inspected.
    let homeDirectory: URL

    /// Filesystem access used for deterministic local inspection.
    private var fileManager: FileManager { .default }

    /// Runs all v1 Agent Doctor checks in stable, UI-friendly order.
    func diagnostics() -> [AgentDiagnostic] {
        var diagnostics: [AgentDiagnostic] = []
        diagnostics += directoryDiagnostics()
        diagnostics += zshDiagnostics()
        diagnostics += codexDiagnostics()
        diagnostics += jsonDiagnostics()
        diagnostics += mcpAuthDiagnostics()
        return diagnostics
    }

    /// Codex configuration directory under the inspected home directory.
    private var codexDirectory: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Claude Code configuration directory under the inspected home directory.
    private var claudeDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Cursor configuration directory under the inspected home directory.
    private var cursorDirectory: URL {
        homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
    }

    /// Craft Agents configuration directory under the inspected home directory.
    private var craftDirectory: URL {
        homeDirectory.appendingPathComponent(".craft-agent", isDirectory: true)
    }

    /// Shared `mcp-remote` credential cache directory under the inspected home directory.
    private var mcpAuthDirectory: URL {
        homeDirectory.appendingPathComponent(".mcp-auth", isDirectory: true)
    }

    /// Reports tool directories that have not been created yet.
    private func directoryDiagnostics() -> [AgentDiagnostic] {
        [
            (.codex, codexDirectory),
            (.claudeCode, claudeDirectory),
            (.cursor, cursorDirectory),
            (.craftAgents, craftDirectory),
            (.mcpAuth, mcpAuthDirectory),
        ].compactMap { tool, url in
            isDirectory(url)
                ? nil
                : .missingDirectory(tool: tool, path: url.path)
        }
    }

    /// Reports missing zsh startup state for the files CodingBuddy manages.
    private func zshDiagnostics() -> [AgentDiagnostic] {
        let files = ShellConfigFile.allCases.map { ($0, $0.url(in: homeDirectory)) }
        let hasStartupFile = files.contains { _, url in
            isFile(url)
        }
        guard !hasStartupFile else { return [] }

        return [
            .missingZshStartupFiles(
                homePath: homeDirectory.path,
                files: ShellConfigFile.allCases.map(\.rawValue).joined(separator: ", ")
            ),
        ]
    }

    /// Reports Codex env-file permission and referenced-variable issues.
    private func codexDiagnostics() -> [AgentDiagnostic] {
        guard isDirectory(codexDirectory) else { return [] }

        var diagnostics: [AgentDiagnostic] = []
        let mcpEnv = codexDirectory.appendingPathComponent("mcp.env")
        let config = codexDirectory.appendingPathComponent("config.toml")

        if fileManager.fileExists(atPath: mcpEnv.path) {
            diagnostics += unsafePermissionDiagnostics(
                url: mcpEnv,
                tool: .codex,
                expectedMode: 0o600
            )
        }

        guard let configText = try? String(contentsOf: config, encoding: .utf8) else {
            return diagnostics
        }
        let defined = Set(
            (try? String(contentsOf: mcpEnv, encoding: .utf8))
                .map(ShellConfigParser.assignments(in:))?
                .map(\.name) ?? []
        )
        var seen = Set<String>()
        for name in CodexConfigReader.servers(in: configText).flatMap(\.referencedEnvVarNames)
            where !defined.contains(name) && seen.insert(name).inserted {
            diagnostics.append(.missingReferencedEnvVar(tool: .codex, name: name, source: config.path))
        }
        return diagnostics
    }

    /// Reports malformed JSON in supported agent configuration files.
    private func jsonDiagnostics() -> [AgentDiagnostic] {
        let files: [(AgentDiagnosticTool, URL)] = [
            (.claudeCode, claudeDirectory.appendingPathComponent("settings.json")),
            (.claudeCode, claudeDirectory.appendingPathComponent("settings.local.json")),
            (.claudeCode, homeDirectory.appendingPathComponent(".claude.json")),
            (.cursor, cursorDirectory.appendingPathComponent("mcp.json")),
            (.craftAgents, craftDirectory.appendingPathComponent("config.json")),
        ]
        return files.compactMap { tool, url in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) == nil
            else { return nil }
            return .invalidConfigFile(tool: tool, path: url.path)
        }
    }

    /// Reports stale, incomplete, or broadly-readable MCP Auth cache entries.
    private func mcpAuthDiagnostics() -> [AgentDiagnostic] {
        guard isDirectory(mcpAuthDirectory) else { return [] }

        let knownURLs = MCPAuthScanner.configuredServerURLs(homeDirectory: homeDirectory)
        return MCPAuthScanner.scan(root: mcpAuthDirectory, knownServerURLs: knownURLs).flatMap { entry in
            var diagnostics = entry.files.flatMap(mcpAuthPermissionDiagnostics)
            let name = String(entry.hash.prefix(12))
            switch entry.status {
            case .active:
                break
            case .expired:
                diagnostics.append(.expiredCredential(tool: .mcpAuth, name: name, source: entry.id))
            case .incomplete:
                diagnostics.append(.incompleteCredential(tool: .mcpAuth, name: name, source: entry.id))
            }
            return diagnostics
        }
    }

    /// Returns true only when the path exists and is a directory.
    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Returns true only when the path exists and is not a directory.
    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Checks credential-bearing MCP Auth files for owner-only permissions.
    private func mcpAuthPermissionDiagnostics(file: MCPAuthFile) -> [AgentDiagnostic] {
        guard file.kind == .tokens || file.kind == .clientInfo || file.kind == .codeVerifier else { return [] }
        return unsafePermissionDiagnostics(url: file.url, tool: .mcpAuth, expectedMode: 0o600)
    }

    /// Reports files that are readable or writable by group or other users.
    private func unsafePermissionDiagnostics(
        url: URL,
        tool: AgentDiagnosticTool,
        expectedMode: Int
    ) -> [AgentDiagnostic] {
        guard let rawMode = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        else { return [] }

        let actualMode = rawMode & 0o777
        guard actualMode & 0o077 != 0 else { return [] }
        return [
            .unsafePermissions(
                tool: tool,
                path: url.path,
                actualMode: String(actualMode, radix: 8),
                expectedMode: String(expectedMode, radix: 8)
            ),
        ]
    }
}
