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

    nonisolated struct Workspace: Identifiable, Equatable, Hashable {
        var id: String
        var name: String
    }

    nonisolated struct LLMConnection: Identifiable, Equatable, Hashable {
        var slug: String
        var name: String
        var providerType: String
        var id: String { slug }
    }

    nonisolated struct SecretFile: Identifiable, Equatable, Hashable {
        var url: URL
        var status: TokenStatus
        var id: String { url.path }
        var fileName: String { url.lastPathComponent }
    }

    nonisolated struct EncryptedStoreInfo: Equatable {
        var byteCount: Int
        var modified: Date?
    }

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

    var configURL: URL { craftDirectory.appendingPathComponent("config.json") }
    var secretsDirectory: URL { craftDirectory.appendingPathComponent("secrets", isDirectory: true) }
    var encryptedStoreURL: URL { craftDirectory.appendingPathComponent("credentials.enc") }

    // MARK: - Loading

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
