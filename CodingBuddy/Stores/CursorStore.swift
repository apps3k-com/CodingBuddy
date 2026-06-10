//
//  CursorStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Source of truth for the Cursor section: `~/.cursor/mcp.json` — the server
/// list is read-only, the per-server `env` values are editable (patched
/// value-precise, never rewritten as a whole).
@Observable
final class CursorStore {

    nonisolated struct EnvEntry: Identifiable, Equatable, Hashable {
        var server: String
        var key: String
        var value: String

        var id: String { "\(server):\(key)" }
    }

    enum CursorError: LocalizedError {
        case fileChangedExternally
        case noEnvBlock

        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .noEnvBlock:
                String(localized: "This server has no “env” object — add one in Cursor first.")
            }
        }
    }

    let cursorDirectory: URL

    private(set) var directoryExists = false
    private(set) var servers: [MCPServerConfig] = []
    private(set) var envEntries: [EnvEntry] = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let fileWriter: SafeFileWriter
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    init(
        cursorDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true),
        backupDirectory: URL? = nil
    ) {
        self.cursorDirectory = cursorDirectory
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        self.fileWriter = SafeFileWriter(backupDirectory: backups)
        reload()
        startWatching()
    }

    var mcpJSONURL: URL { cursorDirectory.appendingPathComponent("mcp.json") }

    // MARK: - Loading

    func reload() {
        directoryExists = FileManager.default.fileExists(atPath: cursorDirectory.path)
        guard let text = try? String(contentsOf: mcpJSONURL, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any]
        else {
            servers = []
            envEntries = []
            return
        }
        servers = MCPServersJSONReader.servers(fromDictionary: mcpServers, scope: "user")
        envEntries = mcpServers.flatMap { name, value -> [EnvEntry] in
            guard let server = value as? [String: Any],
                  let env = server["env"] as? [String: Any] else { return [] }
            return env.compactMap { key, value in
                (value as? String).map { EnvEntry(server: name, key: key, value: $0) }
            }
        }
        .sorted { ($0.server, $0.key) < ($1.server, $1.key) }
    }

    // MARK: - Mutations

    func update(_ entry: EnvEntry, newValue: String) {
        perform {
            let text = try String(contentsOf: mcpJSONURL, encoding: .utf8)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.replaceString(
                in: text, at: ["mcpServers", entry.server, "env", entry.key], with: newValue)
            try fileWriter.write(patched, to: mcpJSONURL)
        }
    }

    func add(key: String, value: String, toServer server: String) {
        perform {
            let text = try String(contentsOf: mcpJSONURL, encoding: .utf8)
            do {
                let patched = try JSONPatcher.insertPair(
                    in: text, at: ["mcpServers", server, "env"], key: key, value: value)
                try fileWriter.write(patched, to: mcpJSONURL)
            } catch JSONPatcher.PatchError.pathNotFound {
                throw CursorError.noEnvBlock
            }
        }
    }

    func delete(_ entry: EnvEntry) {
        perform {
            let text = try String(contentsOf: mcpJSONURL, encoding: .utf8)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.removePair(
                in: text, at: ["mcpServers", entry.server, "env", entry.key])
            try fileWriter.write(patched, to: mcpJSONURL)
        }
    }

    /// The displayed value must still be on disk — Cursor rewrites its own
    /// config, and patching a stale document would be a blind write.
    private func revalidate(_ entry: EnvEntry, in text: String) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any],
              let server = mcpServers[entry.server] as? [String: Any],
              let env = server["env"] as? [String: Any],
              env[entry.key] as? String == entry.value
        else { throw CursorError.fileChangedExternally }
    }

    private func perform(_ mutation: () throws -> Void) {
        monitor.cancelPending()
        do {
            try mutation()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        startWatching()
    }

    // MARK: - File watching

    private func startWatching() {
        if FileManager.default.fileExists(atPath: mcpJSONURL.path) {
            monitor.watch([mcpJSONURL])
        } else {
            monitor.watch([directoryExists ? cursorDirectory : cursorDirectory.deletingLastPathComponent()])
        }
    }
}
