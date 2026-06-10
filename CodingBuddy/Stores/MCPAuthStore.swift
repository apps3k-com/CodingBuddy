//
//  MCPAuthStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Source of truth for the MCP credential cache (`~/.mcp-auth`). Resets move
/// files to the Trash (reversible); edits validate JSON before writing.
@Observable
final class MCPAuthStore {
    let rootDirectory: URL
    private let configHomeDirectory: URL
    /// Injectable for tests: production moves to the Trash.
    @ObservationIgnored private let trashItem: (URL) throws -> Void

    private(set) var entries: [MCPAuthEntry] = []
    private(set) var rootExists = false
    var lastError: String?

    @ObservationIgnored private var watchers: [FileWatcher] = []
    @ObservationIgnored private var pendingReload: DispatchWorkItem?

    init(
        rootDirectory: URL? = nil,
        configHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcp-auth", isDirectory: true)
        self.configHomeDirectory = configHomeDirectory
        self.trashItem = trashItem
        reload()
        startWatching()
    }

    func reload() {
        rootExists = FileManager.default.fileExists(atPath: rootDirectory.path)
        let knownURLs = MCPAuthScanner.configuredServerURLs(homeDirectory: configHomeDirectory)
        entries = MCPAuthScanner.scan(root: rootDirectory, knownServerURLs: knownURLs)
    }

    // MARK: - Mutations

    /// Moves all files of one server entry to the Trash — the surgical
    /// alternative to `rm -rf ~/.mcp-auth`.
    func reset(_ entry: MCPAuthEntry) {
        perform {
            for file in entry.files {
                try trashItem(file.url)
            }
        }
    }

    /// Moves everything inside `~/.mcp-auth` to the Trash. Every connected
    /// server re-runs its OAuth flow on next use.
    func resetAll() {
        perform {
            let children = try FileManager.default.contentsOfDirectory(
                at: rootDirectory, includingPropertiesForKeys: nil
            )
            for child in children {
                try trashItem(child)
            }
        }
    }

    func contents(of file: MCPAuthFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    /// Writes edited content back. JSON files must parse — a broken
    /// credential file would wedge mcp-remote worse than an expired token.
    func save(_ text: String, to file: MCPAuthFile) {
        perform {
            if file.isJSON {
                guard let data = text.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw MCPAuthError.invalidJSON
                }
            }
            try text.write(to: file.url, atomically: true, encoding: .utf8)
        }
    }

    enum MCPAuthError: LocalizedError {
        case invalidJSON

        var errorDescription: String? {
            String(localized: "Not valid JSON — the file was not saved.")
        }
    }

    private func perform(_ mutation: () throws -> Void) {
        pendingReload?.cancel()
        pendingReload = nil
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
        watchers.forEach { $0.cancel() }
        watchers = []

        let onChange: @MainActor () -> Void = { [weak self] in self?.scheduleReload() }
        var watchedURLs = [rootDirectory]
        watchedURLs += Set(entries.map(\.versionDirectory)).map {
            rootDirectory.appendingPathComponent($0, isDirectory: true)
        }
        for url in watchedURLs {
            if let watcher = FileWatcher(url: url, onChange: onChange) {
                watchers.append(watcher)
            }
        }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.startWatching()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
