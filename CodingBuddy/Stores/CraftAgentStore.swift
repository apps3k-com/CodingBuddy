//
//  CraftAgentStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Source of truth for the Craft Agents section. Strictly read-only
/// discovery of `~/.craft-agent/` — `credentials.enc` is AES-encrypted by the
/// app and is never read or written, only described and trashed on request.
@Observable
final class CraftAgentStore {

    /// Workspace metadata decoded from Craft Agents configuration.
    nonisolated struct Workspace: Identifiable, Equatable, Hashable {
        /// Craft's persistent workspace identifier.
        var id: String
        /// Human-readable workspace name.
        var name: String
    }

    /// Non-secret metadata describing a configured model-provider connection.
    nonisolated struct LLMConnection: Identifiable, Equatable, Hashable {
        /// Stable provider slug used by Craft as the connection key.
        var slug: String
        /// Human-readable connection name.
        var name: String
        /// Provider family reported by Craft configuration.
        var providerType: String
        /// Stable identity derived from Craft's provider slug.
        var id: String { slug }
    }

    /// Metadata for one JSON token file without retaining its secret values.
    nonisolated struct SecretFile: Identifiable, Equatable, Hashable {
        /// On-disk token-file location.
        var url: URL
        /// Expiry assessment derived from non-secret timestamp fields.
        var status: TokenStatus
        /// Stable file identity used by tables and reset actions.
        var id: String { url.path }
        /// Display name derived from the token-file path.
        var fileName: String { url.lastPathComponent }
    }

    /// Safe-to-display metadata for Craft's opaque encrypted credential store.
    nonisolated struct EncryptedStoreInfo: Equatable {
        /// Encrypted file size without exposing its contents.
        var byteCount: Int
        /// Last modification timestamp when available from the file system.
        var modified: Date?
    }

    /// Root directory inspected for Craft Agents configuration and credentials.
    let craftDirectory: URL
    /// Injectable for tests: production moves to the Trash.
    @ObservationIgnored private let trashItem: (URL) throws -> Void

    private(set) var directoryExists = false
    private(set) var workspaces: [Workspace] = []
    private(set) var connections: [LLMConnection] = []
    private(set) var secretFiles: [SecretFile] = []
    private(set) var encryptedStore: EncryptedStoreInfo?
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    /// Creates a read-mostly store with an injectable reversible Trash operation.
    init(
        craftDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".craft-agent", isDirectory: true),
        trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.craftDirectory = craftDirectory
        self.trashItem = trashItem
        reload()
        startWatching()
    }

    /// Non-secret Craft configuration used for workspace and provider discovery.
    var configURL: URL { craftDirectory.appendingPathComponent("config.json") }
    /// Directory containing per-connection token files.
    var secretsDirectory: URL { craftDirectory.appendingPathComponent("secrets", isDirectory: true) }
    /// Opaque encrypted credential store that CodingBuddy never reads.
    var encryptedStoreURL: URL { craftDirectory.appendingPathComponent("credentials.enc") }

    // MARK: - Loading

    /// Reloads safe metadata while keeping encrypted credential contents opaque.
    func reload() {
        directoryExists = FileManager.default.fileExists(atPath: craftDirectory.path)
        loadConfig()
        loadSecrets()
        loadEncryptedInfo()
    }

    private func loadConfig() {
        workspaces = []
        connections = []
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any]
        else { return }

        workspaces = ((root["workspaces"] as? [[String: Any]]) ?? []).compactMap { workspace in
            guard let id = workspace["id"] as? String,
                  let name = workspace["name"] as? String else { return nil }
            return Workspace(id: id, name: name)
        }
        connections = ((root["llmConnections"] as? [[String: Any]]) ?? []).compactMap { connection in
            guard let slug = connection["slug"] as? String,
                  let name = connection["name"] as? String else { return nil }
            return LLMConnection(
                slug: slug, name: name,
                providerType: connection["providerType"] as? String ?? ""
            )
        }
    }

    private func loadSecrets() {
        secretFiles = []
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: secretsDirectory, includingPropertiesForKeys: nil
        ) else { return }
        secretFiles = entries
            .filter { $0.pathExtension == "json" }
            .map { SecretFile(url: $0, status: secretStatus(of: $0)) }
            .sorted { $0.fileName < $1.fileName }
    }

    private func secretStatus(of url: URL) -> TokenStatus {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any]
        else { return .incomplete }
        return TokenStatus.from(
            obtainedAt: (root["obtained_at"] as? NSNumber)?.doubleValue,
            expiresIn: (root["expires_in"] as? NSNumber)?.doubleValue
        )
    }

    private func loadEncryptedInfo() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: encryptedStoreURL.path) else {
            encryptedStore = nil
            return
        }
        encryptedStore = EncryptedStoreInfo(
            byteCount: (attributes[.size] as? Int) ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }

    // MARK: - Resets (Trash — reversible)

    /// Craft re-runs every connector's OAuth flow after this.
    func resetEncryptedStore() {
        perform { try trashItem(encryptedStoreURL) }
    }

    /// Moves one connection's token file to the Trash so Craft can reauthenticate it.
    func reset(_ secret: SecretFile) {
        perform { try trashItem(secret.url) }
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
        var urls = [directoryExists ? craftDirectory : craftDirectory.deletingLastPathComponent()]
        if FileManager.default.fileExists(atPath: secretsDirectory.path) {
            urls.append(secretsDirectory)
        }
        monitor.watch(urls)
    }
}
