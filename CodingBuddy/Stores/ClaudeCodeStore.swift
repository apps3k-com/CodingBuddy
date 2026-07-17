//
//  ClaudeCodeStore.swift
//  CodingBuddy
//

import Darwin
import Foundation
import Observation

/// Source of truth for the Claude Code section: descriptor-bound mutations stay
/// on the main actor while bounded discovery publishes immutable snapshots from
/// a background loader.
@Observable
final class ClaudeCodeStore {

    /// Upper bound for one editable Claude Code settings document.
    nonisolated static let maximumConfigurationFileSize = 4 * 1_024 * 1_024

    /// Upper bound for one project-scoped read-only MCP document.
    nonisolated static let maximumProjectMCPFileSize = 1 * 1_024 * 1_024

    /// Maximum number of project records inspected during one reload.
    nonisolated static let maximumProjectCount = 512

    /// Aggregate byte budget for project-scoped MCP documents in one reload.
    nonisolated static let maximumProjectMCPBytes = 16 * 1_024 * 1_024

    /// Injectable ceilings used by production and boundary-focused tests.
    nonisolated struct ReadLimits: Equatable, Sendable {
        /// Maximum bytes accepted from settings and user-level Claude state.
        let configurationFileBytes: Int
        /// Maximum bytes accepted from one project `.mcp.json` document.
        let projectMCPFileBytes: Int
        /// Maximum project records inspected from user-level Claude state.
        let projectCount: Int
        /// Aggregate bytes accepted from all project `.mcp.json` documents.
        let projectMCPBytes: Int

        /// Production ceilings for one Claude configuration reload.
        static let production = ReadLimits(
            configurationFileBytes: ClaudeCodeStore.maximumConfigurationFileSize,
            projectMCPFileBytes: ClaudeCodeStore.maximumProjectMCPFileSize,
            projectCount: ClaudeCodeStore.maximumProjectCount,
            projectMCPBytes: ClaudeCodeStore.maximumProjectMCPBytes
        )

        /// Creates non-negative ceilings; zero deliberately disables the corresponding input.
        init(
            configurationFileBytes: Int,
            projectMCPFileBytes: Int,
            projectCount: Int,
            projectMCPBytes: Int
        ) {
            self.configurationFileBytes = max(0, configurationFileBytes)
            self.projectMCPFileBytes = max(0, projectMCPFileBytes)
            self.projectCount = max(0, projectCount)
            self.projectMCPBytes = max(0, projectMCPBytes)
        }
    }

    /// One editable Claude Code environment value and its source file.
    nonisolated struct EnvEntry: Identifiable, Equatable, Hashable, Sendable {
        /// Claude Code settings files whose `env` objects CodingBuddy may patch.
        enum Source: String, CaseIterable, Sendable {
            /// User-wide Claude Code settings.
            case settings
            /// Machine-local settings that should not be shared with a project.
            case settingsLocal

            /// File name corresponding to this settings scope.
            var fileName: String {
                switch self {
                case .settings: "settings.json"
                case .settingsLocal: "settings.local.json"
                }
            }
        }

        /// Settings file that owns this value.
        var source: Source
        /// Environment variable name stored in the `env` object.
        var key: String
        /// Exact decoded string value presented for editing.
        var value: String

        /// Stable identity combining file scope and variable name.
        var id: String { "\(source.rawValue):\(key)" }
    }

    /// Coarse lifecycle of the asynchronous Claude configuration snapshot.
    nonisolated enum LoadState: Equatable, Sendable {
        /// No filesystem work has been requested.
        case notLoaded
        /// A bounded scan is running outside the main actor.
        case loading
        /// A snapshot was published, including any partial source refusals.
        case loaded
        /// The Claude configuration root itself could not be traversed safely.
        case refused(SourceRefusalReason)
    }

    /// Safe, non-diagnostic categories for input that CodingBuddy deliberately ignores.
    nonisolated enum SourceRefusalReason: Equatable, Hashable, Sendable {
        /// A path contains a symbolic link or cannot be bound safely.
        case unsafePath
        /// Permissions or an I/O failure prevented a bounded read.
        case unreadable
        /// The directory entry is not a regular file or directory.
        case unsupportedFileType
        /// The file exceeds its explicit byte ceiling.
        case tooLarge
        /// Captured bytes are not valid UTF-8.
        case invalidUTF8
        /// The text is not valid JSON.
        case malformedJSON
        /// JSON is valid but not a supported Claude configuration shape.
        case unsupportedStructure
        /// More project records exist than one bounded scan may inspect.
        case projectCountLimit
        /// Project MCP files exceeded the aggregate byte budget.
        case projectByteLimit

        /// Localized, path-free explanation suitable for a refusal state.
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
            case .projectCountLimit:
                String(localized: "The project inventory exceeds CodingBuddy’s safety limit.")
            case .projectByteLimit:
                String(localized: "The project MCP files exceed CodingBuddy’s aggregate safety limit.")
            }
        }
    }

    /// Availability of one independently classified Claude input source.
    nonisolated enum SourceAvailability: Equatable, Hashable, Sendable {
        /// The path was safely proven absent.
        case missing
        /// The path was safely inspected and accepted.
        case available
        /// The path exists or is ambiguous but cannot be read safely.
        case refused(SourceRefusalReason)
    }

    /// Stable source categories used without exposing untrusted paths or raw errors.
    nonisolated enum SourceKind: Equatable, Hashable, Sendable {
        /// The `~/.claude` directory.
        case claudeDirectory
        /// One editable settings document.
        case settings(EnvEntry.Source)
        /// The read-only `~/.claude.json` state document.
        case claudeState
        /// One project-scoped `.mcp.json` document.
        case projectMCP
        /// The bounded project enumeration itself.
        case projectInventory
    }

    /// One safe source classification produced by the background loader.
    nonisolated struct SourceStatus: Identifiable, Equatable, Hashable, Sendable {
        /// Stable opaque identity; project paths are not displayed from this value.
        let id: String
        /// Source category used by mutation and presentation policy.
        let kind: SourceKind
        /// Missing, available, or safely refused.
        let availability: SourceAvailability
        /// Safe reveal target, omitted for untrusted project-root paths.
        let revealURL: URL?

        /// Path-free display name for refusal details.
        var displayName: String {
            switch kind {
            case .claudeDirectory: "~/.claude"
            case .settings(let source): source.fileName
            case .claudeState: "~/.claude.json"
            case .projectMCP: ".mcp.json"
            case .projectInventory: String(localized: "Project inventory")
            }
        }
    }

    /// Sidebar semantics avoid showing a false missing state or zero before discovery completes.
    nonisolated enum SidebarState: Equatable, Sendable {
        /// No truthful presence or count is known yet.
        case neutral
        /// Claude configuration is safely absent.
        case missing
        /// Claude configuration is available with an exact environment-entry count.
        case available(count: Int)
        /// The root was refused and must not be presented as missing.
        case refused
    }

    /// Immutable normalized server payload that is safe to cross actor boundaries.
    nonisolated struct ServerSnapshot: Equatable, Hashable, Sendable {
        /// JSON object key identifying the server.
        let name: String
        /// Optional transport hint.
        let type: String?
        /// Remote endpoint for URL transports.
        let url: String?
        /// Executable for stdio transports.
        let command: String?
        /// Process arguments in source order.
        let args: [String]
        /// Environment key names; values never leave the source file.
        let envKeys: [String]
        /// Header key names; values never leave the source file.
        let headerKeys: [String]
        /// User or project scope accepted by the safe scanner.
        let scope: String

        /// Converts the sendable transport form into the app's presentation model.
        var configuration: MCPServerConfig {
            MCPServerConfig(
                name: name,
                type: type,
                url: url,
                command: command,
                args: args,
                envKeys: envKeys,
                headerKeys: headerKeys,
                scope: scope
            )
        }

        /// Normalizes an existing parsed server without carrying JSON objects across actors.
        init(_ server: MCPServerConfig) {
            name = server.name
            type = server.type
            url = server.url
            command = server.command
            args = server.args
            envKeys = server.envKeys
            headerKeys = server.headerKeys
            scope = server.scope
        }
    }

    /// Complete result of one bounded disk scan.
    nonisolated struct Snapshot: Equatable, Sendable {
        /// Classifications for the root, settings, state, and bounded project inputs.
        let sourceStatuses: [SourceStatus]
        /// Editable environment entries accepted from settings files.
        let envEntries: [EnvEntry]
        /// Read-only MCP definitions accepted from Claude state.
        let servers: [ServerSnapshot]
        /// Already-validated paths for lightweight file-event monitoring.
        let watchURLs: [URL]

        /// Root refusal, if the scan could not safely enter `~/.claude`.
        var rootRefusal: SourceRefusalReason? {
            sourceStatuses.first { $0.kind == .claudeDirectory }.flatMap { status in
                guard case .refused(let reason) = status.availability else { return nil }
                return reason
            }
        }
    }

    /// Thread-safe cancellation signal shared with detached filesystem work.
    nonisolated final class ScanCancellation: @unchecked Sendable {
        /// Serializes access to the cancellation bit across actor and detached-task boundaries.
        private let lock = NSLock()
        /// One-way cancellation bit protected by `lock`.
        private var cancelled = false

        /// Marks the scan as cancelled; repeated calls are harmless.
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        /// Whether the owning reload generation has been superseded or dismissed.
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Value-only request passed to an injected background snapshot loader.
    nonisolated struct LoadRequest: Sendable {
        /// Explicit home directory; the loader never consults process HOME.
        let homeDirectory: URL
        /// Bounded-read policy for this scan.
        let readLimits: ReadLimits
        /// Shared signal that lets synchronous detached work stop promptly.
        let cancellation: ScanCancellation
    }

    /// Injectable actor-safe loading boundary used for deterministic cancellation tests.
    typealias SnapshotLoader = @Sendable (LoadRequest) async -> Snapshot

    /// Safety failures that prevent a value-precise Claude Code settings patch.
    enum ClaudeCodeError: LocalizedError {
        /// The displayed value no longer matches the current file contents.
        case fileChangedExternally
        /// Claude Code has not created an editable `env` object in the target file.
        case noEnvBlock
        /// The latest source snapshot refuses mutation of this target.
        case sourceUnavailable

        /// Localized explanation surfaced by the owning view.
        var errorDescription: String? {
            switch self {
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .noEnvBlock:
                String(localized: "The file has no “env” section — add one in Claude Code first.")
            case .sourceUnavailable:
                String(localized: "This Claude Code source is unavailable. Retry before making changes.")
            }
        }
    }

    /// Home directory containing Claude Code's user configuration.
    let homeDirectory: URL

    /// Current asynchronous loading lifecycle.
    private(set) var loadState: LoadState = .notLoaded
    /// Latest safe source classifications; empty before the first published snapshot.
    private(set) var sourceStatuses: [SourceStatus] = []
    /// Latest accepted editable values.
    private(set) var envEntries: [EnvEntry] = []
    /// Latest accepted read-only MCP definitions.
    private(set) var servers: [MCPServerConfig] = []
    /// Last mutation error, surfaced as an alert by the UI.
    var lastError: String?

    private let fileWriter: SafeFileWriter
    private let readLimits: ReadLimits
    @ObservationIgnored private let loadSnapshot: SnapshotLoader
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadRequestID: UUID?
    /// Signal owned by the current generation so replacement and navigation can stop disk work.
    @ObservationIgnored private var reloadCancellation: ScanCancellation?
    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
    }

    /// Creates an inert store. No filesystem path is inspected until `reload()` is requested.
    init(
        homeDirectory: URL,
        backupDirectory: URL? = nil,
        transactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil,
        readLimits: ReadLimits = .production,
        loadSnapshot: @escaping SnapshotLoader = { request in
            let worker = Task.detached(priority: .userInitiated) {
                DiskSnapshotLoader(request: request).load()
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                request.cancellation.cancel()
                worker.cancel()
            }
        }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.readLimits = readLimits
        self.loadSnapshot = loadSnapshot
        let backups = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy/Backups", isDirectory: true)
        fileWriter = SafeFileWriter(
            backupDirectory: backups,
            transactionHook: transactionHook
        )
    }

    deinit {
        reloadCancellation?.cancel()
        reloadTask?.cancel()
    }

    /// Directory containing Claude Code settings files.
    var claudeDirectory: URL { homeDirectory.appendingPathComponent(".claude", isDirectory: true) }
    /// User-level Claude Code state file inspected without mutation.
    var claudeJSONURL: URL { homeDirectory.appendingPathComponent(".claude.json") }

    /// Whether the latest snapshot safely accepted the Claude configuration directory.
    var directoryExists: Bool {
        sourceStatuses.contains {
            $0.kind == .claudeDirectory && $0.availability == .available
        }
    }

    /// Truthful sidebar state that stays neutral until a scan publishes evidence.
    var sidebarState: SidebarState {
        switch loadState {
        case .notLoaded, .loading:
            .neutral
        case .refused:
            .refused
        case .loaded:
            directoryExists ? .available(count: envEntries.count) : .missing
        }
    }

    /// Sources that the background loader deliberately refused.
    var refusedSources: [SourceStatus] {
        sourceStatuses.filter {
            if case .refused = $0.availability { return true }
            return false
        }
    }

    /// Deduplicated safe locations that Finder may reveal for refused sources.
    var refusedSourceRevealURLs: [URL] {
        var seen = Set<String>()
        return refusedSources.compactMap(\.revealURL).filter { seen.insert($0.path).inserted }
    }

    /// First settings source whose current document is accepted for mutation.
    var firstMutableSource: EnvEntry.Source? {
        EnvEntry.Source.allCases.first(where: canMutate)
    }

    /// Whether the current snapshot authorizes mutation of one settings document.
    func canMutate(_ source: EnvEntry.Source) -> Bool {
        guard loadState == .loaded else { return false }
        return sourceStatuses.contains {
            $0.kind == .settings(source) && $0.availability == .available
        }
    }

    /// Resolves the settings file for an editable environment scope.
    func url(for source: EnvEntry.Source) -> URL {
        claudeDirectory.appendingPathComponent(source.fileName)
    }

    // MARK: - Loading

    /// Starts the first load without repeating work for a loaded or active store.
    func loadIfNeeded() {
        guard loadState == .notLoaded else { return }
        reload()
    }

    /// Cancels older work, clears stale rows, and starts one generation-bound scan.
    func reload() {
        reloadCancellation?.cancel()
        reloadTask?.cancel()
        let requestID = UUID()
        let cancellation = ScanCancellation()
        reloadRequestID = requestID
        reloadCancellation = cancellation
        loadState = .loading
        sourceStatuses = []
        envEntries = []
        servers = []
        monitor.cancelPending()
        let request = LoadRequest(
            homeDirectory: homeDirectory,
            readLimits: readLimits,
            cancellation: cancellation
        )
        let loader = loadSnapshot

        reloadTask = Task { [weak self, loader] in
            let snapshot = await withTaskCancellationHandler {
                await loader(request)
            } onCancel: {
                cancellation.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  reloadRequestID == requestID
            else { return }
            reloadCancellation = nil
            publish(snapshot)
        }
    }

    /// Cancels an in-flight navigation-triggered load and returns to a neutral state.
    func cancelLoading() {
        guard loadState == .loading else { return }
        reloadCancellation?.cancel()
        reloadCancellation = nil
        reloadTask?.cancel()
        reloadRequestID = nil
        sourceStatuses = []
        envEntries = []
        servers = []
        loadState = .notLoaded
    }

    /// Atomically publishes one immutable snapshot and starts lightweight watchers afterward.
    private func publish(_ snapshot: Snapshot) {
        sourceStatuses = snapshot.sourceStatuses
        envEntries = snapshot.envEntries
        servers = snapshot.servers.map(\.configuration)
        loadState = snapshot.rootRefusal.map(LoadState.refused) ?? .loaded
        monitor.watch(snapshot.watchURLs)
    }

    // MARK: - Mutations (env blocks)

    /// Revalidates and replaces one existing environment value in place.
    @discardableResult
    func update(_ entry: EnvEntry, newValue: String) -> Bool {
        perform(on: entry.source) {
            let fileURL = url(for: entry.source)
            let (snapshot, text) = try mutationDocument(at: fileURL)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.replaceString(in: text, at: ["env", entry.key], with: newValue)
            try fileWriter.write(patched, using: snapshot)
        }
    }

    /// Adds a value to an existing `env` object without rewriting unrelated JSON.
    @discardableResult
    func add(key: String, value: String, to source: EnvEntry.Source) -> Bool {
        perform(on: source) {
            let fileURL = url(for: source)
            let (snapshot, text) = try mutationDocument(at: fileURL)
            do {
                let patched = try JSONPatcher.insertPair(in: text, at: ["env"], key: key, value: value)
                try fileWriter.write(patched, using: snapshot)
            } catch JSONPatcher.PatchError.pathNotFound {
                throw ClaudeCodeError.noEnvBlock
            }
        }
    }

    /// Revalidates and removes one environment pair from its source file.
    @discardableResult
    func delete(_ entry: EnvEntry) -> Bool {
        perform(on: entry.source) {
            let fileURL = url(for: entry.source)
            let (snapshot, text) = try mutationDocument(at: fileURL)
            try revalidate(entry, in: text)
            let patched = try JSONPatcher.removePair(in: text, at: ["env", entry.key])
            try fileWriter.write(patched, using: snapshot)
        }
    }

    /// Reads an editable settings file through the descriptor token that authorizes its write.
    private func mutationDocument(at fileURL: URL) throws -> (SafeFileWriter.Snapshot, String) {
        let snapshot = try fileWriter.noFollowSnapshot(
            at: fileURL,
            maximumByteCount: readLimits.configurationFileBytes
        )
        guard let text = try snapshot.utf8Content() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        return (snapshot, text)
    }

    /// The displayed value must still exist unchanged before a value-precise patch.
    private func revalidate(_ entry: EnvEntry, in text: String) throws {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let root = parsed as? [String: Any],
              let env = root["env"] as? [String: Any],
              env[entry.key] as? String == entry.value
        else { throw ClaudeCodeError.fileChangedExternally }
    }

    /// Applies one guarded mutation and always refreshes the source classifications afterward.
    private func perform(on source: EnvEntry.Source, _ mutation: () throws -> Void) -> Bool {
        guard canMutate(source) else {
            lastError = ClaudeCodeError.sourceUnavailable.localizedDescription
            return false
        }
        monitor.cancelPending()
        do {
            try mutation()
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            reload()
            return false
        }
    }
}

// MARK: - Background snapshot loader

/// Synchronous descriptor-bound scanner instantiated only inside a detached task.
nonisolated private struct DiskSnapshotLoader {
    /// Accepted file text or a classified missing/refused state.
    private enum TextResult {
        /// The directory entry was safely proven absent.
        case missing
        /// A bounded regular file was decoded as UTF-8.
        case available(String, byteCount: Int)
        /// The input was deliberately rejected with a path-free reason.
        case refused(ClaudeCodeStore.SourceRefusalReason, chargedBytes: Int)
    }

    /// Directory traversal result used for roots and project records.
    private enum DirectoryResult {
        /// The final directory component was safely proven absent.
        case missing
        /// Every component was opened descriptor-relatively without following links.
        case available
        /// Traversal stopped because the path could not be accepted safely.
        case refused(ClaudeCodeStore.SourceRefusalReason)
    }

    /// Value-only request supplied by the main-actor store.
    let request: ClaudeCodeStore.LoadRequest

    private var homeDirectory: URL { request.homeDirectory }
    private var claudeDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }
    private var claudeJSONURL: URL { homeDirectory.appendingPathComponent(".claude.json") }
    private var reader: SafeFileWriter {
        SafeFileWriter(backupDirectory: homeDirectory.appendingPathComponent(".codingbuddy-read-only"))
    }
    /// Whether either the detached task or its owning reload generation was cancelled.
    private var isCancelled: Bool {
        request.cancellation.isCancelled || Task.isCancelled
    }

    /// Empty result returned only to unwind superseded work; cancelled generations are never published.
    private var cancelledSnapshot: ClaudeCodeStore.Snapshot {
        ClaudeCodeStore.Snapshot(
            sourceStatuses: [],
            envEntries: [],
            servers: [],
            watchURLs: []
        )
    }

    /// Produces one immutable snapshot without accessing observable state.
    func load() -> ClaudeCodeStore.Snapshot {
        guard !isCancelled else { return cancelledSnapshot }
        var statuses: [ClaudeCodeStore.SourceStatus] = []
        var entries: [ClaudeCodeStore.EnvEntry] = []
        var servers: [ClaudeCodeStore.ServerSnapshot] = []
        var watchURLs: [URL] = []

        let directoryResult = classifyDirectory(claudeDirectory)
        guard !isCancelled else { return cancelledSnapshot }
        statuses.append(sourceStatus(
            id: "claude-directory",
            kind: .claudeDirectory,
            result: directoryResult,
            revealURL: homeDirectory
        ))

        switch directoryResult {
        case .available:
            for source in ClaudeCodeStore.EnvEntry.Source.allCases {
                guard !isCancelled else { return cancelledSnapshot }
                let fileURL = claudeDirectory.appendingPathComponent(source.fileName)
                let result = loadSettings(source, at: fileURL)
                guard !isCancelled else { return cancelledSnapshot }
                statuses.append(result.status)
                entries += result.entries
                if result.status.availability == .available { watchURLs.append(fileURL) }
            }
        case .missing:
            for source in ClaudeCodeStore.EnvEntry.Source.allCases {
                statuses.append(ClaudeCodeStore.SourceStatus(
                    id: "settings-\(source.rawValue)",
                    kind: .settings(source),
                    availability: .missing,
                    revealURL: nil
                ))
            }
        case .refused:
            return ClaudeCodeStore.Snapshot(
                sourceStatuses: statuses,
                envEntries: [],
                servers: [],
                watchURLs: []
            )
        }

        let stateResult = loadClaudeState(at: claudeJSONURL)
        guard !isCancelled else { return cancelledSnapshot }
        statuses.append(stateResult.status)
        statuses += stateResult.projectStatuses
        servers += stateResult.servers
        if stateResult.status.availability == .available { watchURLs.append(claudeJSONURL) }

        if watchURLs.count < 3 {
            switch directoryResult {
            case .available:
                watchURLs.append(claudeDirectory)
            case .missing:
                if case .available = classifyDirectory(homeDirectory) { watchURLs.append(homeDirectory) }
            case .refused:
                break
            }
        }

        return ClaudeCodeStore.Snapshot(
            sourceStatuses: statuses,
            envEntries: entries.sorted { ($0.source.rawValue, $0.key) < ($1.source.rawValue, $1.key) },
            servers: servers.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) },
            watchURLs: deduplicated(watchURLs)
        )
    }

    /// Parses one editable settings source while distinguishing absence from refusal.
    private func loadSettings(
        _ source: ClaudeCodeStore.EnvEntry.Source,
        at fileURL: URL
    ) -> (status: ClaudeCodeStore.SourceStatus, entries: [ClaudeCodeStore.EnvEntry]) {
        let id = "settings-\(source.rawValue)"
        switch boundedText(at: fileURL, maximumByteCount: request.readLimits.configurationFileBytes) {
        case .missing:
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .settings(source), availability: .missing, revealURL: nil
            ), [])
        case .refused(let reason, _):
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .settings(source), availability: .refused(reason), revealURL: fileURL
            ), [])
        case .available(let text, _):
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                return refusedSettings(id: id, source: source, url: fileURL, reason: .malformedJSON)
            }
            guard let root = parsed as? [String: Any] else {
                return refusedSettings(id: id, source: source, url: fileURL, reason: .unsupportedStructure)
            }
            guard let rawEnv = root["env"] else {
                return (ClaudeCodeStore.SourceStatus(
                    id: id, kind: .settings(source), availability: .available, revealURL: fileURL
                ), [])
            }
            guard let env = rawEnv as? [String: Any],
                  env.values.allSatisfy({ $0 is String }) else {
                return refusedSettings(id: id, source: source, url: fileURL, reason: .unsupportedStructure)
            }
            let entries = env.map { key, value in
                ClaudeCodeStore.EnvEntry(source: source, key: key, value: value as! String)
            }.sorted { $0.key < $1.key }
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .settings(source), availability: .available, revealURL: fileURL
            ), entries)
        }
    }

    /// Builds a refused settings result without retaining parser diagnostics or contents.
    private func refusedSettings(
        id: String,
        source: ClaudeCodeStore.EnvEntry.Source,
        url: URL,
        reason: ClaudeCodeStore.SourceRefusalReason
    ) -> (status: ClaudeCodeStore.SourceStatus, entries: [ClaudeCodeStore.EnvEntry]) {
        (ClaudeCodeStore.SourceStatus(
            id: id,
            kind: .settings(source),
            availability: .refused(reason),
            revealURL: url
        ), [])
    }

    /// Loads user and project MCP definitions without exposing raw rejected input.
    private func loadClaudeState(at fileURL: URL) -> (
        status: ClaudeCodeStore.SourceStatus,
        projectStatuses: [ClaudeCodeStore.SourceStatus],
        servers: [ClaudeCodeStore.ServerSnapshot]
    ) {
        let id = "claude-state"
        switch boundedText(at: fileURL, maximumByteCount: request.readLimits.configurationFileBytes) {
        case .missing:
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .claudeState, availability: .missing, revealURL: nil
            ), [], [])
        case .refused(let reason, _):
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .claudeState, availability: .refused(reason), revealURL: fileURL
            ), [], [])
        case .available(let text, _):
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                return refusedClaudeState(url: fileURL, reason: .malformedJSON)
            }
            guard let root = parsed as? [String: Any],
                  root["mcpServers"].map({ $0 is [String: Any] }) ?? true,
                  root["projects"].map({ $0 is [String: Any] }) ?? true else {
                return refusedClaudeState(url: fileURL, reason: .unsupportedStructure)
            }

            var servers: [ClaudeCodeStore.ServerSnapshot] = []
            if let user = root["mcpServers"] as? [String: Any] {
                servers += MCPServersJSONReader.servers(fromDictionary: user, scope: "user")
                    .map(ClaudeCodeStore.ServerSnapshot.init)
            }
            let projects = (root["projects"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            var statuses: [ClaudeCodeStore.SourceStatus] = []
            if projects.count > request.readLimits.projectCount {
                statuses.append(ClaudeCodeStore.SourceStatus(
                    id: "project-inventory-limit",
                    kind: .projectInventory,
                    availability: .refused(.projectCountLimit),
                    revealURL: fileURL
                ))
            }

            var aggregateBytes = 0
            for (index, project) in projects.prefix(request.readLimits.projectCount).enumerated() {
                guard !isCancelled else { break }
                let result = loadProject(project, index: index, aggregateBytes: aggregateBytes)
                guard !isCancelled else { break }
                statuses.append(result.status)
                servers += result.servers
                aggregateBytes = result.aggregateBytes
            }
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .claudeState, availability: .available, revealURL: fileURL
            ), statuses, servers)
        }
    }

    /// Builds a refused user-state result without retaining parser diagnostics or contents.
    private func refusedClaudeState(
        url: URL,
        reason: ClaudeCodeStore.SourceRefusalReason
    ) -> (
        status: ClaudeCodeStore.SourceStatus,
        projectStatuses: [ClaudeCodeStore.SourceStatus],
        servers: [ClaudeCodeStore.ServerSnapshot]
    ) {
        (ClaudeCodeStore.SourceStatus(
            id: "claude-state",
            kind: .claudeState,
            availability: .refused(reason),
            revealURL: url
        ), [], [])
    }

    /// Loads one safely rooted project record and its optional `.mcp.json` file.
    private func loadProject(
        _ project: (key: String, value: Any),
        index: Int,
        aggregateBytes: Int
    ) -> (
        status: ClaudeCodeStore.SourceStatus,
        servers: [ClaudeCodeStore.ServerSnapshot],
        aggregateBytes: Int
    ) {
        let id = "project-mcp-\(index)"
        guard !isCancelled else {
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .refused(.unreadable), revealURL: nil
            ), [], aggregateBytes)
        }
        guard project.key.hasPrefix("/") else {
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .refused(.unsafePath), revealURL: nil
            ), [], aggregateBytes)
        }
        let projectURL = URL(fileURLWithPath: project.key, isDirectory: true).standardizedFileURL
        switch classifyDirectory(projectURL) {
        case .missing:
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .missing, revealURL: nil
            ), [], aggregateBytes)
        case .refused(let reason):
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .refused(reason), revealURL: nil
            ), [], aggregateBytes)
        case .available:
            break
        }

        guard let projectRoot = project.value as? [String: Any],
              projectRoot["mcpServers"].map({ $0 is [String: Any] }) ?? true else {
            return (ClaudeCodeStore.SourceStatus(
                id: id,
                kind: .projectMCP,
                availability: .refused(.unsupportedStructure),
                revealURL: projectURL
            ), [], aggregateBytes)
        }

        var projectServers = ((projectRoot["mcpServers"] as? [String: Any]).map {
            MCPServersJSONReader.servers(fromDictionary: $0, scope: project.key)
        } ?? []).map(ClaudeCodeStore.ServerSnapshot.init)
        let localNames = Set(projectServers.map(\.name))
        let mcpURL = projectURL.appendingPathComponent(".mcp.json")
        let remainingBytes = max(0, request.readLimits.projectMCPBytes - aggregateBytes)
        let readCeiling = min(request.readLimits.projectMCPFileBytes, remainingBytes)

        switch boundedText(at: mcpURL, maximumByteCount: readCeiling) {
        case .missing:
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .missing, revealURL: nil
            ), projectServers, aggregateBytes)
        case .refused(let reason, let chargedBytes):
            let consumedBytes = min(
                request.readLimits.projectMCPBytes,
                aggregateBytes + chargedBytes
            )
            let aggregateLimitPreventedRead = remainingBytes == 0
                || readCeiling < request.readLimits.projectMCPFileBytes
            let refusalReason = reason == .tooLarge && aggregateLimitPreventedRead
                ? ClaudeCodeStore.SourceRefusalReason.projectByteLimit
                : reason
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .refused(refusalReason), revealURL: mcpURL
            ), projectServers, consumedBytes)
        case .available(let text, let byteCount):
            let consumedBytes = aggregateBytes + byteCount
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                return (ClaudeCodeStore.SourceStatus(
                    id: id, kind: .projectMCP, availability: .refused(.malformedJSON), revealURL: mcpURL
                ), projectServers, consumedBytes)
            }
            guard let root = parsed as? [String: Any],
                  let dictionary = root["mcpServers"] as? [String: Any] else {
                return (ClaudeCodeStore.SourceStatus(
                    id: id,
                    kind: .projectMCP,
                    availability: .refused(.unsupportedStructure),
                    revealURL: mcpURL
                ), projectServers, consumedBytes)
            }
            projectServers += MCPServersJSONReader.servers(fromDictionary: dictionary, scope: project.key)
                .filter { !localNames.contains($0.name) }
                .map(ClaudeCodeStore.ServerSnapshot.init)
            return (ClaudeCodeStore.SourceStatus(
                id: id, kind: .projectMCP, availability: .available, revealURL: mcpURL
            ), projectServers, consumedBytes)
        }
    }

    /// Captures one bounded regular file without following user-controlled symbolic links.
    private func boundedText(at url: URL, maximumByteCount: Int) -> TextResult {
        guard !isCancelled else { return .refused(.unreadable, chargedBytes: 0) }
        do {
            let snapshot = try reader.noFollowSnapshot(at: url, maximumByteCount: maximumByteCount)
            guard !isCancelled else {
                return .refused(.unreadable, chargedBytes: maximumByteCount)
            }
            guard let text = try snapshot.utf8Content() else { return .missing }
            return .available(text, byteCount: text.utf8.count)
        } catch SafeFileWriter.WriteError.targetTooLarge {
            return .refused(.tooLarge, chargedBytes: maximumByteCount)
        } catch SafeFileWriter.WriteError.unsafeTarget,
                SafeFileWriter.WriteError.danglingSymlink {
            return .refused(.unsafePath, chargedBytes: 0)
        } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
            return .refused(.invalidUTF8, chargedBytes: maximumByteCount)
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            return .refused(.unreadable, chargedBytes: 0)
        } catch {
            return .refused(.unsupportedFileType, chargedBytes: maximumByteCount)
        }
    }

    /// Opens every directory component descriptor-relatively and rejects symlinks at any level.
    private func classifyDirectory(_ url: URL) -> DirectoryResult {
        guard !isCancelled else { return .refused(.unreadable) }
        guard url.isFileURL, url.path.hasPrefix("/") else { return .refused(.unsafePath) }
        let path = normalizedSystemAliasPath(url.standardizedFileURL.path)
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return .refused(.unsafePath)
        }

        var descriptor = Darwin.open(
            "/", O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return .refused(.unreadable) }
        defer { Darwin.close(descriptor) }

        for (index, component) in components.enumerated() {
            guard !isCancelled else { return .refused(.unreadable) }
            let next = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                let failure = errno
                if failure == ENOENT && index == components.index(before: components.endIndex) {
                    return .missing
                }
                if failure == EACCES || failure == EPERM { return .refused(.unreadable) }
                if failure == ELOOP { return .refused(.unsafePath) }

                var info = Darwin.stat()
                let status = component.withCString {
                    fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
                if status == 0 {
                    let type = info.st_mode & mode_t(S_IFMT)
                    return type == mode_t(S_IFLNK)
                        ? .refused(.unsafePath)
                        : .refused(.unsupportedFileType)
                }
                return .refused(.unsafePath)
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return .available
    }

    /// Resolves only immutable root aliases shipped by macOS.
    private func normalizedSystemAliasPath(_ path: String) -> String {
        for alias in ["var", "tmp", "etc"] {
            let prefix = "/\(alias)"
            if path == prefix || path.hasPrefix("\(prefix)/") { return "/private\(path)" }
        }
        return path
    }

    /// Converts a directory result into the common source status shape.
    private func sourceStatus(
        id: String,
        kind: ClaudeCodeStore.SourceKind,
        result: DirectoryResult,
        revealURL: URL?
    ) -> ClaudeCodeStore.SourceStatus {
        let availability: ClaudeCodeStore.SourceAvailability = switch result {
        case .missing: .missing
        case .available: .available
        case .refused(let reason): .refused(reason)
        }
        return ClaudeCodeStore.SourceStatus(
            id: id,
            kind: kind,
            availability: availability,
            revealURL: availability == .missing ? nil : revealURL
        )
    }

    /// Preserves order while preventing duplicate watcher paths.
    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
