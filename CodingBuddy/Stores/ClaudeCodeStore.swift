//
//  ClaudeCodeStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Source of truth for the Claude Code section: the editable `env` blocks of
/// `~/.claude/settings.json` and `settings.local.json` (patched value-precise
/// via JSONPatcher, never rewritten as a whole) plus the read-only MCP server
/// overview from `~/.claude.json` and the projects' `.mcp.json` files.
@Observable
final class ClaudeCodeStore {

    nonisolated struct EnvEntry: Identifiable, Equatable, Hashable {
        enum Source: String, CaseIterable {
            case settings
            case settingsLocal

            var fileName: String {
                switch self {
                case .settings: "settings.json"
                case .settingsLocal: "settings.local.json"
                }
            }
        }

        var source: Source
        var key: String
        var value: String

        var id: String { "\(source.rawValue):\(key)" }
    }

    enum ClaudeCodeError: LocalizedError {
        case fileChangedExternally
        case noEnvBlock

        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .noEnvBlock:
                String(localized: "The file has no “env” section — add one in Claude Code first.")
            }
        }
    }

    let homeDirectory: URL

    private(set) var directoryExists = false
    private(set) var envEntries: [EnvEntry] = []
    private(set) var servers: [MCPServerConfig] = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let fileWriter: SafeFileWriter
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        self.fileWriter = SafeFileWriter(backupDirectory: backups)
        reload()
        startWatching()
    }

    var claudeDirectory: URL { homeDirectory.appendingPathComponent(".claude", isDirectory: true) }
    var claudeJSONURL: URL { homeDirectory.appendingPathComponent(".claude.json") }

    func url(for source: EnvEntry.Source) -> URL {
        claudeDirectory.appendingPathComponent(source.fileName)
    }

    // MARK: - Loading

    func reload() {
        directoryExists = FileManager.default.fileExists(atPath: claudeDirectory.path)
        envEntries = EnvEntry.Source.allCases.flatMap { entries(from: $0) }
        servers = loadServers()
    }

    private func entries(from source: EnvEntry.Source) -> [EnvEntry] {
        guard let text = try? String(contentsOf: url(for: source), encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let env = root["env"] as? [String: Any]
        else { return [] }
        return env.compactMap { key, value in
            (value as? String).map { EnvEntry(source: source, key: key, value: $0) }
        }
        .sorted { $0.key < $1.key }
    }

    /// `~/.claude.json` is rewritten by Claude Code constantly — strictly
    /// read-only here, and only the two relevant subtrees are touched.
    private func loadServers() -> [MCPServerConfig] {
        guard let text = try? String(contentsOf: claudeJSONURL, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any]
        else { return [] }

        var result: [MCPServerConfig] = []
        if let user = root["mcpServers"] as? [String: Any] {
            result += MCPServersJSONReader.servers(fromDictionary: user, scope: "user")
        }
        for (path, value) in (root["projects"] as? [String: Any]) ?? [:] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let project = value as? [String: Any],
               let mcpServers = project["mcpServers"] as? [String: Any] {
                result += MCPServersJSONReader.servers(fromDictionary: mcpServers, scope: path)
            }
            // Versionable project-scope definitions live next to the project.
            let mcpJSON = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            if let text = try? String(contentsOf: mcpJSON, encoding: .utf8) {
                result += MCPServersJSONReader.servers(inDocument: text, scope: path)
            }
        }
        return result.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }
    }

    // MARK: - Mutations (env blocks)

    func update(_ entry: EnvEntry, newValue: String) {
        perform {
            let fileURL = url(for: entry.source)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.replaceString(in: text, at: ["env", entry.key], with: newValue)
            try fileWriter.write(patched, to: fileURL)
        }
    }

    func add(key: String, value: String, to source: EnvEntry.Source) {
        perform {
            let fileURL = url(for: source)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            do {
                let patched = try JSONPatcher.insertPair(in: text, at: ["env"], key: key, value: value)
                try fileWriter.write(patched, to: fileURL)
            } catch JSONPatcher.PatchError.pathNotFound {
                throw ClaudeCodeError.noEnvBlock
            }
        }
    }

    func delete(_ entry: EnvEntry) {
        perform {
            let fileURL = url(for: entry.source)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.removePair(in: text, at: ["env", entry.key])
            try fileWriter.write(patched, to: fileURL)
        }
    }

    /// The displayed value must still be on disk — Claude Code rewrites its
    /// settings itself, and patching a stale document would be a blind write.
    private func revalidate(_ entry: EnvEntry, in text: String) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let env = root["env"] as? [String: Any],
              env[entry.key] as? String == entry.value
        else { throw ClaudeCodeError.fileChangedExternally }
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
        var urls: [URL] = []
        for source in EnvEntry.Source.allCases where FileManager.default.fileExists(atPath: url(for: source).path) {
            urls.append(url(for: source))
        }
        if FileManager.default.fileExists(atPath: claudeJSONURL.path) {
            urls.append(claudeJSONURL)
        }
        if urls.count < 3 {
            urls.append(directoryExists ? claudeDirectory : homeDirectory)
        }
        monitor.watch(urls)
    }
}
