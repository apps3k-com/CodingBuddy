//
//  EnvStore.swift
//  CodingBuddy
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

    /// Variables of one file (or all). With `hidingOverridden`, assignments
    /// shadowed by a later one (zsh load order, see `effectiveVariable`) are
    /// dropped — also inside a single-file scope, where an assignment can be
    /// overridden by a later file.
    func variables(in file: ShellConfigFile?, hidingOverridden: Bool = false) -> [EnvVariable] {
        var scoped = variables
        if let file { scoped = scoped.filter { $0.file == file } }
        if hidingOverridden { scoped = scoped.filter { !isOverridden($0) } }
        return scoped
    }

    // MARK: - Mutations

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
        // A debounced reload queued by an earlier watcher event would fire
        // after our own synchronous reload and do the same work again.
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
        effectiveVariable(named: variable.name)?.id != variable.id
    }

    // MARK: - File watching

    private func startWatching() {
        // The home directory watcher catches files being created or removed.
        monitor.watch([homeDirectory] + existingFiles.map { $0.url(in: homeDirectory) })
    }
}
