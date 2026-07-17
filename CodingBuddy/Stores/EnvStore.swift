//
//  EnvStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Safe, user-presentable reasons why an existing shell file was not loaded.
nonisolated enum EnvFileRefusalReason: Equatable, Sendable {
    /// The file exists, but its bytes could not be read safely.
    case unreadable
    /// The file path, type, ownership, or permissions fail the no-follow safety policy.
    case unsafePath
    /// The file exceeds the explicit shell-source byte ceiling.
    case tooLarge
    /// The file's bytes are not valid UTF-8 and therefore cannot be parsed safely.
    case invalidUTF8

    /// Localized recovery context that never includes an OS error or absolute path.
    var localizedDescription: String {
        switch self {
        case .unreadable:
            String(localized: "CodingBuddy did not load this file because it could not be read safely.")
        case .unsafePath:
            String(localized: "The path is unavailable or contains a symbolic link.")
        case .tooLarge:
            String(localized: "CodingBuddy cannot safely read this file because it is unexpectedly large.")
        case .invalidUTF8:
            String(localized: "CodingBuddy did not load this file because it is not valid UTF-8.")
        }
    }
}

/// Read state of one supported zsh startup file.
nonisolated enum EnvFileAccessState: Equatable, Sendable {
    /// No filesystem entry exists, so the writer may safely create the file later.
    case missing
    /// The existing file was read and parsed successfully.
    case loaded
    /// The existing file was deliberately excluded from the in-memory snapshot.
    case refused(EnvFileRefusalReason)
}

/// A refused file paired with its safe, categorized reason.
nonisolated struct EnvFileRefusal: Equatable, Identifiable, Sendable {
    /// Supported shell file that could not be loaded.
    let file: ShellConfigFile
    /// Categorized refusal reason without raw filesystem details.
    let reason: EnvFileRefusalReason

    /// Stable identity used by SwiftUI status rows.
    var id: ShellConfigFile { file }
}

/// Completeness of the shell-file snapshot represented by one sidebar scope.
nonisolated enum EnvScopeAccessState: Equatable, Sendable {
    /// Every source in the scope is either loaded or safely absent.
    case complete
    /// Some sources were loaded or safely absent, while others were refused.
    case partial([EnvFileRefusal])
    /// Every source in the scope was refused.
    case refused([EnvFileRefusal])

    /// Refused sources that make the current snapshot incomplete.
    var refusals: [EnvFileRefusal] {
        switch self {
        case .complete: []
        case .partial(let refusals), .refused(let refusals): refusals
        }
    }

    /// Whether counts and empty states represent the complete selected scope.
    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    /// Whether mutation, import, and export actions are safe for this scope.
    var allowsActions: Bool { isComplete }
}

/// Source of truth for the UI: loads the zsh config files, exposes the parsed
/// variables, performs edits through ShellConfigWriter and reloads when the
/// files change on disk.
@Observable
final class EnvStore {
    /// Maximum bytes accepted from one zsh startup file during a reload.
    nonisolated static let maximumShellFileSize = 4 * 1_024 * 1_024

    /// Home directory whose supported zsh startup files form the managed scope.
    let homeDirectory: URL

    private(set) var variables: [EnvVariable] = []
    private(set) var existingFiles: Set<ShellConfigFile> = []
    /// Read result for every supported zsh startup file.
    private(set) var fileAccessStates: [ShellConfigFile: EnvFileAccessState] =
        Dictionary(uniqueKeysWithValues: ShellConfigFile.allCases.map { ($0, .missing) })
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let writer: ShellConfigWriter
    /// Descriptor-bound reader configured with the same isolated support directory as the writer.
    private let reader: SafeFileWriter
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    /// Creates a store with injectable home and backup locations for safe testing.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        self.writer = ShellConfigWriter(backupDirectory: backups)
        self.reader = SafeFileWriter(backupDirectory: backups)
        reload()
        startWatching()
    }

    // MARK: - Loading

    /// Rebuilds the assignment list and records why any source was excluded.
    func reload() {
        var loaded: [EnvVariable] = []
        var existing: Set<ShellConfigFile> = []
        var accessStates: [ShellConfigFile: EnvFileAccessState] = [:]

        for file in ShellConfigFile.allCases {
            let url = file.url(in: homeDirectory)
            do {
                let snapshot = try reader.snapshot(
                    at: url,
                    maximumByteCount: Self.maximumShellFileSize,
                    createMissingParentDirectories: false
                )
                guard let content = try snapshot.utf8Content() else {
                    accessStates[file] = .missing
                    continue
                }
                existing.insert(file)
                accessStates[file] = .loaded
                loaded += ShellConfigParser.variables(in: content, file: file)
            } catch SafeFileWriter.WriteError.targetTooLarge {
                existing.insert(file)
                accessStates[file] = .refused(.tooLarge)
            } catch SafeFileWriter.WriteError.unsafeTarget,
                    SafeFileWriter.WriteError.danglingSymlink {
                existing.insert(file)
                accessStates[file] = .refused(.unsafePath)
            } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
                existing.insert(file)
                accessStates[file] = .refused(.invalidUTF8)
            } catch {
                if Self.isSafelyMissing(url) {
                    accessStates[file] = .missing
                } else {
                    existing.insert(file)
                    accessStates[file] = .refused(.unreadable)
                }
            }
        }
        variables = loaded
        existingFiles = existing
        fileAccessStates = accessStates
    }

    /// Returns the read state for one supported file.
    func accessState(for file: ShellConfigFile) -> EnvFileAccessState {
        fileAccessStates[file] ?? .missing
    }

    /// Aggregates per-file refusals for one file scope or the all-files scope.
    func accessState(in file: ShellConfigFile?) -> EnvScopeAccessState {
        let scopedFiles = file.map { [$0] } ?? ShellConfigFile.allCases
        let refusals = scopedFiles.compactMap { candidate -> EnvFileRefusal? in
            guard case .refused(let reason) = accessState(for: candidate) else { return nil }
            return EnvFileRefusal(file: candidate, reason: reason)
        }

        guard !refusals.isEmpty else { return .complete }
        return refusals.count == scopedFiles.count ? .refused(refusals) : .partial(refusals)
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

    /// Appends validated assignments through the backup-first shell writer.
    @discardableResult
    func addAll(_ entries: [(name: String, rawValue: String)], to file: ShellConfigFile) -> Bool {
        guard accessState(in: file).allowsActions else { return refuseMutationAndReload() }
        return perform {
            try writer.addVariables(entries, to: file.url(in: homeDirectory))
        }
    }

    /// Revalidates the original source line before replacing an assignment.
    @discardableResult
    func update(_ variable: EnvVariable, name: String, rawValue: String, exported: Bool) -> Bool {
        guard accessState(in: variable.file).allowsActions else { return refuseMutationAndReload() }
        return perform {
            try writer.updateVariable(
                variable, newName: name, newRawValue: rawValue,
                exported: exported, at: variable.file.url(in: homeDirectory)
            )
        }
    }

    /// Revalidates the original source line before removing an assignment.
    @discardableResult
    func delete(_ variable: EnvVariable) -> Bool {
        guard accessState(in: variable.file).allowsActions else { return refuseMutationAndReload() }
        return perform {
            try writer.deleteVariable(variable, at: variable.file.url(in: homeDirectory))
        }
    }

    /// Rejects a stale UI mutation and refreshes the authoritative disk state.
    private func refuseMutationAndReload() -> Bool {
        lastError = String(localized: "This shell file is unavailable. Retry before making changes.")
        reload()
        startWatching()
        return false
    }

    private func perform(_ mutation: () throws -> Void) -> Bool {
        // A debounced reload queued by an earlier watcher event would fire
        // after our own synchronous reload and do the same work again.
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

    /// Confirms that no directory entry exists; dangling symlinks remain refused.
    private static func isSafelyMissing(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return false }
        return errno == ENOENT
    }
}
