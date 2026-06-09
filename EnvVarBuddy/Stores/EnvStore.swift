//
//  EnvStore.swift
//  EnvVarBuddy
//

import Foundation
import Observation

/// Source of truth for the UI: loads the zsh config files, exposes the parsed
/// variables, performs edits through ShellConfigWriter and reloads when the
/// files change on disk.
@Observable
final class EnvStore {
    let homeDirectory: URL

    private(set) var variables: [EnvVariable] = []
    private(set) var existingFiles: Set<ShellConfigFile> = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let writer: ShellConfigWriter
    @ObservationIgnored private var watchers: [FileWatcher] = []
    @ObservationIgnored private var pendingReload: DispatchWorkItem?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnvVarBuddy/Backups", isDirectory: true)
        self.writer = ShellConfigWriter(backupDirectory: backups)
        reload()
        startWatching()
    }

    // MARK: - Loading

    func reload() {
        var loaded: [EnvVariable] = []
        var existing: Set<ShellConfigFile> = []
        for file in ShellConfigFile.allCases {
            let url = file.url(in: homeDirectory)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            existing.insert(file)
            loaded += ShellConfigParser.variables(in: content, file: file)
        }
        variables = loaded
        existingFiles = existing
    }

    func variables(in file: ShellConfigFile?) -> [EnvVariable] {
        guard let file else { return variables }
        return variables.filter { $0.file == file }
    }

    // MARK: - Mutations

    func add(name: String, rawValue: String, to file: ShellConfigFile) {
        perform {
            try writer.addVariables([(name: name, rawValue: rawValue)], to: file.url(in: homeDirectory))
        }
    }

    func addAll(_ entries: [(name: String, rawValue: String)], to file: ShellConfigFile) {
        perform {
            try writer.addVariables(entries, to: file.url(in: homeDirectory))
        }
    }

    func update(_ variable: EnvVariable, name: String, rawValue: String, exported: Bool) {
        perform {
            try writer.updateVariable(
                variable, newName: name, newRawValue: rawValue,
                exported: exported, at: variable.file.url(in: homeDirectory)
            )
        }
    }

    func delete(_ variable: EnvVariable) {
        perform {
            try writer.deleteVariable(variable, at: variable.file.url(in: homeDirectory))
        }
    }

    private func perform(_ mutation: () throws -> Void) {
        do {
            try mutation()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        startWatching()
    }

    // MARK: - Precedence

    /// The assignment that actually takes effect in a new terminal session:
    /// zsh loads .zshenv → .zprofile → .zshrc, and within a file a later
    /// assignment overrides an earlier one — so the last one in load order wins.
    func effectiveVariable(named name: String) -> EnvVariable? {
        variables
            .filter { $0.name == name }
            .max { lhs, rhs in
                (lhs.file.loadOrder, lhs.lineIndex) < (rhs.file.loadOrder, rhs.lineIndex)
            }
    }

    /// True when another assignment of the same name takes effect instead.
    func isOverridden(_ variable: EnvVariable) -> Bool {
        guard variables.contains(where: { $0.name == variable.name && $0.id != variable.id }) else {
            return false
        }
        return effectiveVariable(named: variable.name)?.id != variable.id
    }

    // MARK: - File watching

    private func startWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []

        let onChange: @MainActor () -> Void = { [weak self] in self?.scheduleReload() }

        // The home directory watcher catches files being created or removed.
        if let watcher = FileWatcher(url: homeDirectory, onChange: onChange) {
            watchers.append(watcher)
        }
        for file in existingFiles {
            if let watcher = FileWatcher(url: file.url(in: homeDirectory), onChange: onChange) {
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
