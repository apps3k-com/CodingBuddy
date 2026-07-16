//
//  CursorStore.swift
//  CodingBuddy
//

import CryptoKit
import Darwin
import Foundation
import Observation

/// Source of truth for the Cursor section: `~/.cursor/mcp.json` — the server
/// list is read-only, the per-server `env` values are editable (patched
/// value-precise, never rewritten as a whole).
@Observable
final class CursorStore {

    /// Upper bound for Cursor's editable MCP configuration document.
    static let maximumConfigurationFileSize = 4 * 1_024 * 1_024

    /// One editable environment value nested under a Cursor MCP server.
    nonisolated struct EnvEntry: Identifiable, Equatable, Hashable {
        /// MCP server name that owns the environment pair.
        var server: String
        /// Environment variable name.
        var key: String
        /// Exact decoded value used for stale-write revalidation.
        var value: String

        /// Stable identity combining server and variable name.
        var id: String { "\(server):\(key)" }
    }

    /// Redacted server metadata plus a digest of its complete semantic JSON object.
    nonisolated struct ServerSnapshot: Identifiable, Equatable, Hashable, Sendable {
        /// Fields safe to display in the read-only server inventory.
        let configuration: MCPServerConfig
        /// SHA-256 of the canonical complete server object, including hidden values.
        let semanticFingerprint: Data

        /// Stable display identity; equality additionally requires the fingerprint.
        var id: String { configuration.id }
    }

    /// Typed reasons why Cursor configuration contents were deliberately withheld.
    nonisolated enum RefusalReason: Equatable {
        /// The configured path is unsafe or traverses a user-controlled symbolic link.
        case unsafePath
        /// The target is a regular file but cannot be read safely.
        case unreadable
        /// The target is not a supported regular file.
        case unsupportedFileType
        /// The target exceeds the bounded-read ceiling.
        case tooLarge
        /// The target bytes are not valid UTF-8.
        case invalidUTF8
        /// The target text is not valid JSON.
        case malformedJSON
        /// The JSON does not contain the supported Cursor MCP object structure.
        case unsupportedStructure

        /// Localized, non-sensitive explanation for the refusal view.
        var localizedDescription: String {
            switch self {
            case .unsafePath:
                String(localized: "The path is unavailable or contains a symbolic link.")
            case .unreadable:
                String(localized: "The source could not be read safely.")
            case .unsupportedFileType:
                String(localized: "The source is not a supported regular file or directory.")
            case .tooLarge:
                String(localized: "The source exceeds CodingBuddy’s safety size limit.")
            case .invalidUTF8:
                String(localized: "The source is not valid UTF-8.")
            case .malformedJSON:
                String(localized: "The source does not contain valid JSON.")
            case .unsupportedStructure:
                String(localized: "The source has an unsupported JSON structure.")
            }
        }
    }

    /// Authoritative outcome of the most recent Cursor configuration load.
    nonisolated enum LoadState: Equatable {
        /// No Cursor MCP document exists at the safely inspected location.
        case missing
        /// The complete document was loaded and validated.
        case loaded
        /// The document exists or its path is unsafe, so no contents are exposed.
        case refused(RefusalReason)
    }

    /// Safety failures that prevent a value-precise Cursor configuration patch.
    enum CursorError: LocalizedError {
        /// The displayed value no longer matches Cursor's current file.
        case fileChangedExternally
        /// The selected server has no editable `env` object.
        case noEnvBlock

        /// Localized explanation surfaced by the owning view.
        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .noEnvBlock:
                String(localized: "This server has no “env” object — add one in Cursor first.")
            }
        }
    }

    /// Root directory containing Cursor's user-level MCP configuration.
    let cursorDirectory: URL

    private(set) var directoryExists = false
    private(set) var loadState: LoadState = .missing
    private(set) var servers: [MCPServerConfig] = []
    private(set) var serverSnapshots: [ServerSnapshot] = []
    private(set) var envEntries: [EnvEntry] = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let fileWriter: SafeFileWriter
    @ObservationIgnored private var safelySnapshottedTarget = false
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    /// Creates a store with injectable configuration and backup locations.
    init(
        cursorDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true),
        backupDirectory: URL? = nil,
        transactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil
    ) {
        self.cursorDirectory = cursorDirectory
        /// Backup destination used before each value-precise JSON patch.
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        self.fileWriter = SafeFileWriter(
            backupDirectory: backups,
            transactionHook: transactionHook
        )
        reload()
        startWatching()
    }

    /// Cursor MCP document patched without rewriting unrelated JSON.
    var mcpJSONURL: URL { cursorDirectory.appendingPathComponent("mcp.json") }

    // MARK: - Loading

    /// Reloads read-only server metadata and editable environment pairs.
    func reload() {
        servers = []
        serverSnapshots = []
        envEntries = []
        safelySnapshottedTarget = false
        directoryExists = FileManager.default.fileExists(atPath: cursorDirectory.path)

        let snapshot: SafeFileWriter.Snapshot
        do {
            snapshot = try fileWriter.noFollowSnapshot(
                at: mcpJSONURL,
                maximumByteCount: Self.maximumConfigurationFileSize
            )
            safelySnapshottedTarget = true
        } catch {
            if isSafelyMissing(error) {
                loadState = .missing
            } else {
                loadState = .refused(refusalReason(for: error))
            }
            return
        }

        let text: String
        do {
            guard let decoded = try snapshot.utf8Content() else {
                loadState = .missing
                return
            }
            text = decoded
        } catch {
            loadState = .refused(.invalidUTF8)
            return
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        } catch {
            loadState = .refused(.malformedJSON)
            return
        }

        guard let root = parsed as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any],
              hasSupportedStructure(mcpServers)
        else {
            loadState = .refused(.unsupportedStructure)
            return
        }

        do {
            serverSnapshots = try makeServerSnapshots(from: mcpServers, scope: "user")
        } catch {
            loadState = .refused(.unsupportedStructure)
            return
        }
        servers = serverSnapshots.map(\.configuration)
        envEntries = mcpServers.flatMap { name, value -> [EnvEntry] in
            guard let server = value as? [String: Any],
                  let env = server["env"] as? [String: Any] else { return [] }
            return env.compactMap { key, value in
                (value as? String).map { EnvEntry(server: name, key: key, value: $0) }
            }
        }
        .sorted { ($0.server, $0.key) < ($1.server, $1.key) }
        loadState = .loaded
    }

    // MARK: - Mutations

    /// Revalidates the owning server and replaces one nested environment value in place.
    @discardableResult
    func update(
        _ entry: EnvEntry,
        expectedServer: ServerSnapshot,
        newValue: String
    ) -> Bool {
        perform {
            let (snapshot, text) = try mutationDocument()
            try revalidate(expectedServer, in: text)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.replaceString(
                in: text, at: ["mcpServers", entry.server, "env", entry.key], with: newValue)
            try fileWriter.write(patched, using: snapshot)
        }
    }

    /// Adds a pair only when the complete displayed server definition still matches disk.
    @discardableResult
    func add(key: String, value: String, toServer expectedServer: ServerSnapshot) -> Bool {
        perform {
            let (snapshot, text) = try mutationDocument()
            try revalidate(expectedServer, in: text)
            do {
                let patched = try JSONPatcher.insertPair(
                    in: text,
                    at: ["mcpServers", expectedServer.configuration.name, "env"],
                    key: key,
                    value: value
                )
                try fileWriter.write(patched, using: snapshot)
            } catch JSONPatcher.PatchError.pathNotFound {
                throw CursorError.noEnvBlock
            }
        }
    }

    /// Revalidates the owning server and removes one nested environment pair.
    @discardableResult
    func delete(_ entry: EnvEntry, expectedServer: ServerSnapshot) -> Bool {
        perform {
            let (snapshot, text) = try mutationDocument()
            try revalidate(expectedServer, in: text)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.removePair(
                in: text, at: ["mcpServers", entry.server, "env", entry.key])
            try fileWriter.write(patched, using: snapshot)
        }
    }

    /// Reads the MCP document through the descriptor-bound token used by the write.
    private func mutationDocument() throws -> (SafeFileWriter.Snapshot, String) {
        let snapshot = try fileWriter.noFollowSnapshot(
            at: mcpJSONURL,
            maximumByteCount: Self.maximumConfigurationFileSize
        )
        guard let text = try snapshot.utf8Content() else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: mcpJSONURL.path]
            )
        }
        return (snapshot, text)
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

    /// Rejects every semantic server-object change before patching its `env` object.
    private func revalidate(_ expectedServer: ServerSnapshot, in text: String) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let mcpServers = root["mcpServers"] as? [String: Any],
              let currentServer = try? makeServerSnapshots(
                  from: mcpServers,
                  scope: expectedServer.configuration.scope
              ).first(where: { $0.configuration.name == expectedServer.configuration.name })
        else { throw CursorError.fileChangedExternally }
        guard currentServer == expectedServer else {
            throw CursorError.fileChangedExternally
        }
    }

    /// Builds redacted metadata and irreversible canonical fingerprints for all servers.
    private func makeServerSnapshots(
        from mcpServers: [String: Any],
        scope: String
    ) throws -> [ServerSnapshot] {
        let configurations = MCPServersJSONReader.servers(
            fromDictionary: mcpServers,
            scope: scope
        )
        let configurationsByName = Dictionary(
            uniqueKeysWithValues: configurations.map { ($0.name, $0) }
        )
        return try mcpServers.map { name, value in
            guard let serverObject = value as? [String: Any],
                  let configuration = configurationsByName[name]
            else { throw CursorError.fileChangedExternally }
            let canonicalJSON = try JSONSerialization.data(
                withJSONObject: serverObject,
                options: [.sortedKeys]
            )
            return ServerSnapshot(
                configuration: configuration,
                semanticFingerprint: Data(SHA256.hash(data: canonicalJSON))
            )
        }
        .sorted { $0.configuration.name < $1.configuration.name }
    }

    private func perform(_ mutation: () throws -> Void) -> Bool {
        guard loadState == .loaded else {
            lastError = String(localized: "CodingBuddy did not load this file because it could not be read safely.")
            return false
        }
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
        if loadState == .loaded || (safelySnapshottedTarget && loadState != .missing) {
            monitor.watch([mcpJSONURL])
        } else if safelySnapshottedTarget && directoryExists {
            monitor.watch([cursorDirectory])
        } else {
            monitor.watch([cursorDirectory.deletingLastPathComponent()])
        }
    }

    /// Validates every editable container instead of silently dropping unsupported values.
    private func hasSupportedStructure(_ mcpServers: [String: Any]) -> Bool {
        mcpServers.values.allSatisfy { value in
            guard let server = value as? [String: Any] else { return false }
            guard let rawEnv = server["env"] else { return true }
            guard let env = rawEnv as? [String: Any] else { return false }
            return env.values.allSatisfy { $0 is String }
        }
    }

    /// Absence is trustworthy only when the Cursor directory itself is absent.
    private func isSafelyMissing(_ error: Error) -> Bool {
        guard !directoryExists else { return false }
        if let error = error as? POSIXError {
            return error.code == .ENOENT
        }
        if let error = error as? CocoaError {
            return error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        }
        return false
    }

    /// Maps descriptor-reader failures without exposing filesystem details.
    private func refusalReason(for error: Error) -> RefusalReason {
        if let error = error as? SafeFileWriter.WriteError {
            switch error {
            case .targetTooLarge:
                return .tooLarge
            case .unsafeTarget:
                return finalTargetIsUnsupportedType()
                    ? .unsupportedFileType
                    : .unsafePath
            case .danglingSymlink, .staleOriginal, .unsafeBackupDirectory,
                 .backupDirectoryTooLarge:
                return .unsafePath
            }
        }
        return .unreadable
    }

    /// Distinguishes special-file refusals from unsafe path and ownership checks.
    private func finalTargetIsUnsupportedType() -> Bool {
        var info = Darwin.stat()
        guard lstat(mcpJSONURL.path, &info) == 0 else { return false }
        let type = info.st_mode & mode_t(S_IFMT)
        return type != mode_t(S_IFREG) && type != mode_t(S_IFLNK)
    }
}
