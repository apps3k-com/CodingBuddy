//
//  CodexStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Source of truth for the Codex section: the editable `~/.codex/mcp.env`
/// (plain dotenv, kept at mode 600) and the read-only MCP server list from
/// `~/.codex/config.toml`.
@Observable
final class CodexStore {
    /// Directory containing Codex configuration and its dedicated MCP environment file.
    let codexDirectory: URL

    private(set) var directoryExists = false
    private(set) var variables: [EnvFileVariable] = []
    private(set) var servers: [CodexMCPServer] = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let writer: ShellConfigWriter
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    /// Creates a store with injectable configuration and backup locations.
    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        backupDirectory: URL? = nil
    ) {
        self.codexDirectory = codexDirectory
        /// Backup destination shared with other guarded configuration writers.
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        // mcp.env holds credentials: files this writer creates start at 0600.
        self.writer = ShellConfigWriter(backupDirectory: backups, createMode: 0o600)
        reload()
        startWatching()
    }

    /// Credential-bearing dotenv file managed with owner-only creation permissions.
    var mcpEnvURL: URL { codexDirectory.appendingPathComponent("mcp.env") }
    /// Read-only Codex configuration used to discover MCP server references.
    var configTOMLURL: URL { codexDirectory.appendingPathComponent("config.toml") }

    // MARK: - Loading

    /// Reloads environment assignments and MCP server definitions from disk.
    func reload() {
        directoryExists = FileManager.default.fileExists(atPath: codexDirectory.path)
        variables = (try? String(contentsOf: mcpEnvURL, encoding: .utf8))
            .map(ShellConfigParser.assignments(in:)) ?? []
        servers = (try? String(contentsOf: configTOMLURL, encoding: .utf8))
            .map(CodexConfigReader.servers(in:)) ?? []
    }

    /// Env variable names referenced by servers but defined nowhere in
    /// mcp.env — the "where does Codex read this from?" warning.
    var missingEnvVarNames: [String] {
        let defined = Set(variables.map(\.name))
        var seen = Set<String>()
        return servers.flatMap(\.referencedEnvVarNames)
            .filter { !defined.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Mutations (mcp.env)

    /// Revalidates and updates one assignment while preserving its source line semantics.
    @discardableResult
    func update(_ variable: EnvFileVariable, name: String, rawValue: String) -> Bool {
        perform {
            try writer.updateVariable(
                variable, newName: name, newRawValue: rawValue,
                exported: false, at: mcpEnvURL
            )
        }
    }

    /// Adds a non-exported assignment to Codex's dedicated MCP environment file.
    @discardableResult
    func add(name: String, rawValue: String) -> Bool {
        perform {
            try writer.addVariables([(name, rawValue)], to: mcpEnvURL, exportStyle: .none)
        }
    }

    /// Revalidates and removes one assignment from the MCP environment file.
    @discardableResult
    func delete(_ variable: EnvFileVariable) -> Bool {
        perform {
            try writer.deleteVariable(variable, at: mcpEnvURL)
        }
    }

    private func perform(_ mutation: () throws -> Void) -> Bool {
        monitor.cancelPending()
        do {
            try mutation()
            lastError = nil
            reload()
            startWatching()
            return true
        } catch {
            lastError = error.localizedDescription
            reload()
            startWatching()
            return false
        }
    }

    // MARK: - File watching

    private func startWatching() {
        // Watch the two files directly — the directory holds chatty SQLite
        // WAL files. The directory (or its parent) is only watched while
        // something is missing, to catch creation.
        var urls: [URL] = []
        for file in [mcpEnvURL, configTOMLURL] where FileManager.default.fileExists(atPath: file.path) {
            urls.append(file)
        }
        if urls.count < 2 {
            urls.append(directoryExists ? codexDirectory : codexDirectory.deletingLastPathComponent())
        }
        monitor.watch(urls)
    }
}
