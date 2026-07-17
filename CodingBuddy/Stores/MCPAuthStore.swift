//
//  MCPAuthStore.swift
//  CodingBuddy
//

import Darwin
import Foundation
import Observation

/// Source of truth for the MCP credential cache (`~/.mcp-auth`). Resets move
/// files to the Trash (reversible); edits validate JSON and the on-disk
/// original before writing through the shared safe-file machinery.
@Observable
final class MCPAuthStore {
    /// Cleartext plus the opaque descriptor-bound identity required for a later save.
    struct LoadedContents {
        /// Exact UTF-8 text loaded after authentication.
        let text: String
        /// Writer-owned descriptor and filesystem identity captured with the bytes.
        fileprivate let snapshot: SafeFileWriter.Snapshot
    }

    /// Root of the credential cache managed by `mcp-remote`.
    let rootDirectory: URL
    private let configHomeDirectory: URL
    private let fileWriter: SafeFileWriter
    private let resetStagingDirectory: URL
    private let recoveryRecordURL: URL
    /// Injectable for tests: production moves to the Trash.
    @ObservationIgnored private let trashItem: (URL) throws -> URL
    /// Injectable synchronization point for adversarial reset tests.
    @ObservationIgnored private let beforeResetStage: (Int, URL) throws -> Void
    /// Runs at the injected race boundary before final no-follow revalidation and rename.
    @ObservationIgnored private let beforeResetRename: (Int, URL) throws -> Void
    /// Runs after a leaf entered the private transaction but before its subtree is revalidated.
    @ObservationIgnored private let afterResetRename: (Int, URL) throws -> Void
    /// Runs at the recovery race boundary before final no-follow revalidation and exclusive rename.
    @ObservationIgnored private let beforeRecoveryRename: (Int, URL) throws -> Void
    /// Runs immediately before the transaction enters private app staging.
    @ObservationIgnored private let beforeTrashStage: (URL) throws -> Void

    /// Credential groups currently discovered below ``rootDirectory``.
    private(set) var entries: [MCPAuthEntry] = []
    /// Whether the credential cache root currently exists on disk.
    private(set) var rootExists = false
    /// Sanitized safety refusals from the latest bounded credential scan.
    private(set) var scanRefusals: Set<MCPAuthScanRefusal> = []
    /// Descriptor-bound reset inventory captured with the currently displayed entries.
    @ObservationIgnored private var resetInventory: CredentialInventory?
    /// Whether the latest scan omitted an artifact, making destructive reset coverage incomplete.
    var hasIncompleteCredentialInventory: Bool {
        scanRefusals.contains(where: \.preventsCredentialReset) || resetInventory == nil
    }
    /// Root whose bounded recovery discovery was refused because the path,
    /// permissions, identity, or entry count was unsafe.
    private(set) var recoveryDiscoveryRefusedAt: URL?
    /// Retained transaction directory when automatic recovery cannot finish.
    private(set) var lastRecoveryDirectory: URL?
    /// Last mutation or load error surfaced by the owning view.
    var lastError: String?
    /// Structured recovery state used to offer only relevant UI actions.
    private(set) var lastFailureKind: FailureKind?

    /// User-action category associated with ``lastError``.
    enum FailureKind: Equatable {
        /// The credential file changed after the editor loaded it.
        case fileChangedExternally
        /// Protected reset contents remain at the associated path.
        case recoveryRequired(URL)
        /// A credential write retained an artifact whose commit state is
        /// explained by the accompanying localized recovery error.
        case writeRecovery(URL)
        /// The operation failed without a specialized recovery action.
        case other
    }

    @ObservationIgnored private lazy var monitor = FileChangeMonitor { [weak self] in
        self?.reload()
        self?.startWatching()
    }

    /// Creates a credential store with injectable file locations and
    /// operations for isolated failure testing.
    init(
        rootDirectory: URL? = nil,
        configHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL? = nil,
        resetStagingDirectory: URL? = nil,
        recoveryRecordURL: URL? = nil,
        trashItem: @escaping (URL) throws -> URL = MCPAuthStore.moveToTrash,
        beforeResetStage: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeResetRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        afterResetRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeRecoveryRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeTrashStage: @escaping (URL) throws -> Void = { _ in }
    ) {
        /// Base for private CodingBuddy support files.
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodingBuddy", isDirectory: true)
        /// Final destination used by both directory hardening and writes.
        let resolvedBackupDirectory = backupDirectory
            ?? applicationSupport.appendingPathComponent("Backups/MCPAuth", isDirectory: true)
        self.rootDirectory = rootDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcp-auth", isDirectory: true)
        self.configHomeDirectory = configHomeDirectory
        self.fileWriter = SafeFileWriter(
            backupDirectory: resolvedBackupDirectory,
            createMode: 0o600
        )
        /// Stable staging root shared by reset transactions and durable recovery metadata.
        let resolvedResetStagingDirectory = resetStagingDirectory
            ?? applicationSupport.appendingPathComponent("MCPAuthResetStaging", isDirectory: true)
        self.resetStagingDirectory = resolvedResetStagingDirectory
        self.recoveryRecordURL = recoveryRecordURL
            ?? resolvedResetStagingDirectory.deletingLastPathComponent()
                .appendingPathComponent("MCPAuthRecovery.json")
        self.trashItem = trashItem
        self.beforeResetStage = beforeResetStage
        self.beforeResetRename = beforeResetRename
        self.afterResetRename = afterResetRename
        self.beforeRecoveryRename = beforeRecoveryRename
        self.beforeTrashStage = beforeTrashStage
        reload()
        startWatching()
    }

    /// Reloads credential metadata without retaining token values in models.
    func reload() {
        refreshRecoveryDirectory()
        rootExists = FileManager.default.fileExists(atPath: rootDirectory.path)
        let knownURLs = MCPAuthScanner.configuredServerURLs(homeDirectory: configHomeDirectory)
        let result = MCPAuthScanner.scanResult(root: rootDirectory, knownServerURLs: knownURLs)
        entries = result.entries
        scanRefusals = result.refusals
        guard !result.refusals.contains(where: \.preventsCredentialReset) else {
            resetInventory = nil
            return
        }
        do {
            resetInventory = try credentialInventory(for: result.entries)
        } catch {
            resetInventory = nil
            scanRefusals.insert(.credentialArtifact)
        }
    }

    // MARK: - Mutations

    /// Moves all files of one server entry to the Trash — the surgical
    /// alternative to `rm -rf ~/.mcp-auth`.
    @discardableResult
    func reset(_ entry: MCPAuthEntry) -> Bool {
        perform {
            try resetItems(expectedEntry: entry)
        }
    }

    /// Moves everything inside `~/.mcp-auth` to the Trash. Every connected
    /// server re-runs its OAuth flow on next use.
    func resetAll() {
        perform {
            try resetItems(expectedEntry: nil)
        }
    }

    /// Reads one credential file after the user has authenticated in the UI.
    func contents(of file: MCPAuthFile) throws -> String {
        try loadContents(of: file).text
    }

    /// Loads bounded UTF-8 bytes without following symlinks and retains the
    /// exact descriptor-bound snapshot required by the editor's next save.
    func loadContents(of file: MCPAuthFile) throws -> LoadedContents {
        guard file.isSafelyReadable else { throw MCPAuthError.unsafeCredentialArtifact }
        let snapshot = try fileWriter.noFollowSnapshot(
            at: file.url,
            maximumByteCount: MCPAuthScanner.maximumCredentialFileSize
        )
        guard let text = try snapshot.utf8Content() else {
            throw MCPAuthError.unsafeCredentialArtifact
        }
        return LoadedContents(text: text, snapshot: snapshot)
    }

    /// Writes edited content only when the file still matches the content
    /// loaded by the editor. JSON files must parse before a backup-first,
    /// atomic, symlink-preserving and permission-preserving replacement.
    @discardableResult
    func save(_ text: String, to file: MCPAuthFile, expectedOriginalContent: String) -> Bool {
        perform {
            try validateEditableText(text, for: file)
            let snapshot = try fileWriter.noFollowSnapshot(
                at: file.url,
                maximumByteCount: MCPAuthScanner.maximumCredentialFileSize
            )
            guard try snapshot.utf8Content() == expectedOriginalContent else {
                throw SafeFileWriter.WriteError.staleOriginal
            }
            try fileWriter.write(text, using: snapshot)
        }
    }

    /// Saves against the exact descriptor-bound snapshot captured when the
    /// authenticated editor loaded the file.
    @discardableResult
    func save(_ text: String, to file: MCPAuthFile, loaded: LoadedContents) -> Bool {
        perform {
            try validateEditableText(text, for: file)
            try fileWriter.write(text, using: loaded.snapshot)
        }
    }

    /// Applies format validation shared by snapshot- and compatibility-based saves.
    private func validateEditableText(_ text: String, for file: MCPAuthFile) throws {
        guard file.isSafelyReadable else { throw MCPAuthError.unsafeCredentialArtifact }
        if file.isJSON {
            guard let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw MCPAuthError.invalidJSON
            }
        }
    }

    /// Clears a surfaced operation error after its alert is dismissed.
    func clearError() {
        lastError = nil
        lastFailureKind = nil
    }

    /// Errors that prevent a credential edit or require manual reset recovery.
    enum MCPAuthError: LocalizedError {
        /// Edited JSON could not be parsed.
        case invalidJSON
        /// The scanner classified this artifact as reset-only or action-time validation failed.
        case unsafeCredentialArtifact
        /// Recovery discovery or reset-all enumeration could not be completed within the safety bound.
        case unsafeCredentialCache
        /// The file no longer matches the content loaded by the editor.
        case fileChangedExternally
        /// Automatic rollback or cleanup failed, leaving protected copies at
        /// the associated recovery directory.
        case recoveryRequired(directory: URL, primary: Error, recovery: Error)
        /// Rollback cannot continue because a destination changed after
        /// staging. Originals remain in the transaction directory.
        case recoveryConflict(directory: URL, destinations: [URL], primary: Error)
        /// A previous protected transaction must be resolved before another
        /// reset can begin.
        case recoveryPending(directory: URL)

        /// Localized message shown by the shared MCP credential alert.
        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                String(localized: "Not valid JSON — the file was not saved.")
            case .unsafeCredentialArtifact:
                String(localized: "CodingBuddy did not open this credential artifact because it could not be read safely. You can still reveal it in Finder or reset it.")
            case .unsafeCredentialCache:
                String(localized: "CodingBuddy did not reset credentials because the cache or recovery area could not be enumerated safely. Review it in Finder and try again.")
            case .fileChangedExternally:
                String(localized: "The file was changed externally. Please try again.")
            case .recoveryRequired:
                String(localized: "CodingBuddy could not finish the credential reset. Protected recovery files remain available for manual recovery.")
            case .recoveryConflict:
                String(localized: "CodingBuddy stopped credential recovery because one or more original paths changed. Protected recovery files remain available for manual recovery.")
            case .recoveryPending:
                String(localized: "Resolve the existing credential recovery files before starting another reset.")
            }
        }
    }

    @discardableResult
    private func perform(_ mutation: () throws -> Void) -> Bool {
        monitor.cancelPending()
        do {
            try mutation()
            clearError()
            reload()
            startWatching()
            return true
        } catch {
            lastFailureKind = failureKind(for: error)
            lastError = userFacingMessage(for: error)
            reload()
            startWatching()
            return false
        }
    }

    /// Maps internal errors to a stable UI recovery category.
    func failureKind(for error: Error) -> FailureKind {
        if let recoveryError = error as? SafeFileWriter.RecoveryError,
           let path = recoveryError.artifacts.first?.lastKnownPath {
            return .writeRecovery(URL(fileURLWithPath: path))
        }
        if let writeError = error as? SafeFileWriter.WriteError,
           writeError == .staleOriginal {
            return .fileChangedExternally
        }
        if let authError = error as? MCPAuthError {
            switch authError {
            case .fileChangedExternally:
                return .fileChangedExternally
            case let .recoveryRequired(directory, _, _),
                 let .recoveryConflict(directory, _, _),
                 let .recoveryPending(directory):
                return .recoveryRequired(directory)
            case .invalidJSON:
                return .other
            case .unsafeCredentialArtifact, .unsafeCredentialCache:
                return .other
            }
        }
        return .other
    }

    /// Returns localized guidance without exposing raw filesystem diagnostics.
    func userFacingMessage(for error: Error) -> String {
        if let localized = error as? MCPAuthError {
            return localized.localizedDescription
        }
        if let localized = error as? SafeFileWriter.RecoveryError {
            return localized.localizedDescription
        }
        if let localized = error as? SafeFileWriter.WriteError {
            return localized.localizedDescription
        }
        if let localized = error as? SafeFileWriter.CleanupDurabilityError {
            return localized.localizedDescription
        }
        return String(localized: "CodingBuddy could not complete the credential operation. No unconfirmed changes were written.")
    }

    // MARK: - Reset recovery

    /// Prefix reserved for private reset transactions inside the cache root.
    private static let resetTransactionPrefix = ".codingbuddy-reset-"
    /// Top-level reset and recovery discovery shares the scanner's explicit
    /// version-directory ceiling so no earlier path can bypass that bound.
    private static let maximumResetRootEntries = MCPAuthScanner.maximumVersionDirectoryCount
    /// Recursive reset inventory ceiling shared across all cache subtrees.
    private static let maximumResetDescendantEntries = MCPAuthScanner.maximumCredentialArtifactCount

    /// Owned descriptor used to keep reset operations anchored to the exact
    /// directories validated before mutation.
    private final class ResetFileDescriptor {
        /// Darwin file descriptor closed when this owner is released.
        let rawValue: Int32

        /// Takes ownership of an already-open descriptor.
        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            Darwin.close(rawValue)
        }
    }

    /// Stable identity used to detect path replacement between validation and
    /// descriptor-relative mutation.
    private struct ResetFileIdentity: Equatable {
        /// Device containing the filesystem object.
        let device: dev_t
        /// Inode identifying the filesystem object on its device.
        let inode: ino_t
        /// Object type and permission bits captured during validation.
        let mode: mode_t
        /// User that owns the filesystem object.
        let owner: uid_t

        /// Whether the identity describes a directory.
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        /// Whether the identity describes a regular file.
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    }

    /// Complete reset-relevant namespace bound to one successful scanner generation.
    private struct CredentialInventory: Equatable {
        /// Every top-level cache child because reset-all moves the complete root inventory.
        let rootItems: [RootItem]
        /// Credential artifacts grouped by their helper version and server hash.
        let entries: [Entry]

        /// One no-follow top-level cache child.
        struct RootItem: Equatable {
            /// Descriptor-relative child name.
            let name: String
            /// Exact filesystem identity accepted during inventory capture.
            let identity: ResetFileIdentity
            /// Every recursively nested artifact moved with this root item by reset-all.
            let descendants: [Descendant]
        }

        /// One no-follow descendant below a top-level cache child.
        struct Descendant: Equatable {
            /// Slash-separated path relative to the owning top-level item.
            let relativePath: String
            /// Exact filesystem identity accepted during inventory capture.
            let identity: ResetFileIdentity
        }

        /// One scanner-visible version/hash group.
        struct Entry: Equatable {
            /// Version directory containing the credential artifacts.
            let versionDirectory: String
            /// Opaque MCP server hash used by `mcp-remote`.
            let hash: String
            /// Exact no-follow artifact identities in deterministic path order.
            let files: [File]
        }

        /// One resettable credential artifact.
        struct File: Equatable {
            /// Path below the credential root, retained without an absolute user path.
            let relativePath: String
            /// Exact filesystem identity accepted during inventory capture.
            let identity: ResetFileIdentity
            /// Every descendant moved when a reset-only artifact is itself a directory.
            let descendants: [Descendant]
        }
    }

    /// Durable identity binding for a recovery transaction moved outside the
    /// app's two enumerable reset roots.
    private struct RecoveryRecord: Codable, Equatable {
        /// Record format version reserved for fail-closed schema changes.
        let version: Int
        /// Exact absolute path returned for the moved transaction.
        let path: String
        /// Filesystem device containing the transaction.
        let device: UInt64
        /// Inode assigned to the transaction directory.
        let inode: UInt64
        /// POSIX object type captured separately from permission bits.
        let fileType: UInt32
        /// Effective user that owned the transaction at failure time.
        let owner: UInt32
        /// Exact POSIX permission and special-mode bits.
        let mode: UInt32

        /// Captures the durable fields required to reject path reuse.
        init(url: URL, identity: ResetFileIdentity) {
            self.version = 1
            self.path = url.standardizedFileURL.path
            self.device = UInt64(truncatingIfNeeded: identity.device)
            self.inode = UInt64(truncatingIfNeeded: identity.inode)
            self.fileType = UInt32(identity.mode & S_IFMT)
            self.owner = UInt32(identity.owner)
            self.mode = UInt32(identity.mode & mode_t(0o7777))
        }

        /// Requires every persisted identity field to match current no-follow
        /// metadata exactly.
        func matches(_ identity: ResetFileIdentity) -> Bool {
            version == 1
                && device == UInt64(truncatingIfNeeded: identity.device)
                && inode == UInt64(truncatingIfNeeded: identity.inode)
                && fileType == UInt32(identity.mode & S_IFMT)
                && owner == UInt32(identity.owner)
                && mode == UInt32(identity.mode & mode_t(0o7777))
        }
    }

    /// Result of loading the exact recovery record path without scanning any
    /// external directory such as the Trash.
    private enum RecoveryRecordLoad {
        /// No persistence record exists.
        case missing
        /// The record and the exact transaction path retain their identities.
        case valid(
            URL,
            recordIdentity: ResetFileIdentity,
            transactionIdentity: ResetFileIdentity
        )
        /// A present record is malformed, unsafe, stale, or identity-mismatched.
        case invalid(reportedURL: URL?)
    }

    /// One validated item requested by a reset operation.
    private struct ResetRequest {
        /// Original URL retained for diagnostics and recovery guidance.
        let originalURL: URL
        /// Path components relative to the opened credential root.
        let components: [String]
        /// Exact no-follow identity approved by the confirmation snapshot.
        let expectedIdentity: ResetFileIdentity
        /// Complete bounded subtree approved with a directory artifact.
        let expectedDescendants: [CredentialInventory.Descendant]
    }

    /// One item already moved into the private transaction directory.
    private struct ResetMove {
        /// Original URL retained for conflict reporting.
        let originalURL: URL
        /// Relative parent components used to revalidate rollback reachability.
        let parentComponents: [String]
        /// Exact parent descriptor used for staging and rollback.
        let destinationParent: ResetFileDescriptor
        /// Original leaf name below ``destinationParent``.
        let destinationName: String
        /// Unique leaf name inside the transaction directory.
        let stagedName: String
        /// Identity accepted immediately before the namespace mutation.
        let validatedIdentity: ResetFileIdentity
        /// Exact identity expected inside the transaction after the rename.
        let stagedIdentity: ResetFileIdentity
        /// Complete bounded subtree approved by the confirmation snapshot.
        let expectedDescendants: [CredentialInventory.Descendant]
    }

    /// Internal transaction failures that must never be treated as permission
    /// to follow a changed path.
    private enum ResetTransactionError: Error {
        /// The configured credential root is not an owned, stable directory.
        case unsafeRoot(URL)
        /// A requested item escaped the root or changed type/identity.
        case unsafeComponent(URL)
        /// A private transaction path was unexpectedly retained.
        case transactionStillPresent(URL)
        /// The Trash API did not report the exact transaction it moved.
        case unexpectedTrashResult(URL)
        /// Durable recovery state is missing required safety properties.
        case unsafeRecoveryRecord(URL)
        /// A reset or recovery root exceeded the explicit bounded enumeration.
        case tooManyEntries(URL)
    }

    /// Stages every requested item with descriptor-relative no-follow renames,
    /// then sends the single transaction container to the Trash.
    ///
    /// A `nil` selection means reset-all and uses only the complete inventory
    /// captured for the confirmation UI, then revalidates it at each rename boundary.
    private func resetItems(expectedEntry: MCPAuthEntry?) throws {
        refreshRecoveryDirectory()
        if recoveryDiscoveryRefusedAt != nil {
            throw MCPAuthError.unsafeCredentialCache
        }
        if let lastRecoveryDirectory {
            throw MCPAuthError.recoveryPending(directory: lastRecoveryDirectory)
        }

        guard !scanRefusals.contains(where: \.preventsCredentialReset),
              let expectedInventory = resetInventory else {
            throw MCPAuthError.unsafeCredentialCache
        }
        if let expectedEntry {
            guard entries.first(where: { $0.id == expectedEntry.id }) == expectedEntry else {
                throw MCPAuthError.fileChangedExternally
            }
        }

        let knownURLs = MCPAuthScanner.configuredServerURLs(homeDirectory: configHomeDirectory)
        let freshScan = MCPAuthScanner.scanResult(
            root: rootDirectory,
            knownServerURLs: knownURLs
        )
        guard !freshScan.refusals.contains(where: \.preventsCredentialReset) else {
            throw MCPAuthError.unsafeCredentialCache
        }

        let root = try openResetRoot()
        let rootIdentity = try identity(of: root.rawValue)
        let freshInventory = try credentialInventory(
            for: freshScan.entries,
            root: root,
            rootIdentity: rootIdentity
        )
        guard freshInventory == expectedInventory else {
            throw MCPAuthError.fileChangedExternally
        }

        if let expectedEntry {
            guard let freshEntry = freshScan.entries.first(where: { $0.id == expectedEntry.id }),
                  freshEntry == expectedEntry else {
                throw MCPAuthError.fileChangedExternally
            }
        }
        let requests = try resetRequests(
            expectedEntry: expectedEntry,
            inventory: expectedInventory
        )
        guard !requests.isEmpty else { return }

        let transactionName = Self.resetTransactionPrefix + UUID().uuidString
        try createTransaction(named: transactionName, root: root)
        let transactionURL = rootDirectory.appendingPathComponent(transactionName, isDirectory: true)
        let transaction = try openDirectory(named: transactionName, relativeTo: root)
        let transactionIdentity = try identity(of: transaction.rawValue)
        var transactionContainer = root
        var recoveryURL = transactionURL

        var moves: [ResetMove] = []
        do {
            for (index, request) in requests.enumerated() {
                let expectedRootNames: Set<String>? = if expectedEntry == nil {
                    Set(requests[index...].compactMap { $0.components.first })
                        .union([transactionName])
                } else {
                    nil
                }
                let move = try stage(
                    request,
                    index: index,
                    root: root,
                    rootIdentity: rootIdentity,
                    transaction: transaction,
                    expectedRootNames: expectedRootNames
                )
                moves.append(move)
                try afterResetRename(index, request.originalURL)
                guard move.stagedIdentity == move.validatedIdentity,
                      try identity(named: move.stagedName, relativeTo: transaction)
                        == move.stagedIdentity else {
                    throw ResetTransactionError.unsafeComponent(move.originalURL)
                }
                try validateStagedMove(move, transaction: transaction)
            }
            try validateRoot(root, expected: rootIdentity)
            try validateTransaction(
                transactionName,
                parent: root,
                expected: transactionIdentity,
                url: transactionURL
            )
        } catch {
            try recover(
                moves,
                after: error,
                root: root,
                rootIdentity: rootIdentity,
                transaction: transaction,
                transactionIdentity: transactionIdentity,
                transactionContainer: transactionContainer,
                transactionName: transactionName,
                transactionURL: recoveryURL
            )
            throw error
        }

        do {
            let stagingRoot = try openResetStagingRoot()
            let stagingIdentity = try identity(of: stagingRoot.rawValue)
            let stagedURL = resetStagingDirectory.appendingPathComponent(
                transactionName,
                isDirectory: true
            )

            try beforeTrashStage(stagedURL)
            try validateRoot(root, expected: rootIdentity)
            try validateResetStagingRoot(stagingRoot, expected: stagingIdentity)
            try validateTransaction(
                transactionName,
                parent: root,
                expected: transactionIdentity,
                url: transactionURL
            )

            let stageResult = renameatx_np(
                root.rawValue,
                transactionName,
                stagingRoot.rawValue,
                transactionName,
                UInt32(RENAME_EXCL)
            )
            guard stageResult == 0 else { throw currentPOSIXError() }
            transactionContainer = stagingRoot
            recoveryURL = stagedURL

            try validateResetStagingRoot(stagingRoot, expected: stagingIdentity)
            try validateTransaction(
                transactionName,
                parent: stagingRoot,
                expected: transactionIdentity,
                url: stagedURL
            )
            guard try identity(of: transaction.rawValue) == transactionIdentity else {
                throw ResetTransactionError.unsafeComponent(stagedURL)
            }
            for move in moves {
                try validateStagedMove(move, transaction: transaction)
            }

            let trashedURL = try trashItem(stagedURL)
            try validateTrashResult(
                trashedURL,
                expected: transactionIdentity,
                stagingRoot: stagingRoot,
                transactionName: transactionName,
                stagedURL: stagedURL
            )
            if try itemExists(transactionName, relativeTo: stagingRoot) {
                throw ResetTransactionError.transactionStillPresent(stagedURL)
            }
        } catch {
            try recover(
                moves,
                after: error,
                root: root,
                rootIdentity: rootIdentity,
                transaction: transaction,
                transactionIdentity: transactionIdentity,
                transactionContainer: transactionContainer,
                transactionName: transactionName,
                transactionURL: recoveryURL
            )
            throw error
        }
    }

    /// Opens and validates the credential root without following any path
    /// component or accepting a root owned by another user.
    private func openResetRoot() throws -> ResetFileDescriptor {
        let descriptor: Int32
        do {
            descriptor = try SecureAbsolutePath.openDirectory(at: rootDirectory)
        } catch {
            throw ResetTransactionError.unsafeRoot(rootDirectory)
        }
        let root = ResetFileDescriptor(descriptor)
        let rootIdentity = try identity(of: descriptor)
        guard rootIdentity.isDirectory,
              rootIdentity.owner == geteuid(),
              rootIdentity.mode & 0o022 == 0 else {
            throw ResetTransactionError.unsafeRoot(rootDirectory)
        }
        try validateRoot(root, expected: rootIdentity)
        return root
    }

    /// Opens the app-owned staging root used to remove the transaction from
    /// the credential cache's mutable namespace before invoking path-based
    /// Trash APIs.
    private func openResetStagingRoot() throws -> ResetFileDescriptor {
        let descriptor: Int32
        do {
            descriptor = try SecureAbsolutePath.openOrCreateDirectory(
                at: resetStagingDirectory,
                mode: 0o700
            )
        } catch {
            throw ResetTransactionError.unsafeRoot(resetStagingDirectory)
        }
        let stagingRoot = ResetFileDescriptor(descriptor)
        var stagingIdentity = try identity(of: descriptor)
        guard stagingIdentity.isDirectory, stagingIdentity.owner == geteuid() else {
            throw ResetTransactionError.unsafeRoot(resetStagingDirectory)
        }
        guard fchmod(descriptor, 0o700) == 0 else { throw currentPOSIXError() }
        stagingIdentity = try identity(of: descriptor)
        guard stagingIdentity.mode & 0o077 == 0 else {
            throw ResetTransactionError.unsafeRoot(resetStagingDirectory)
        }
        try validateResetStagingRoot(stagingRoot, expected: stagingIdentity)
        return stagingRoot
    }

    /// Derives mutation requests only from the namespace the user confirmed.
    private func resetRequests(
        expectedEntry: MCPAuthEntry?,
        inventory: CredentialInventory
    ) throws -> [ResetRequest] {
        if let expectedEntry {
            guard let entry = inventory.entries.first(where: {
                $0.versionDirectory == expectedEntry.versionDirectory
                    && $0.hash == expectedEntry.hash
            }) else {
                throw MCPAuthError.fileChangedExternally
            }
            return try entry.files.map { file in
                let components = file.relativePath.split(separator: "/").map(String.init)
                guard !components.isEmpty,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw MCPAuthError.fileChangedExternally
                }
                return ResetRequest(
                    originalURL: rootDirectory.appendingPathComponent(file.relativePath),
                    components: components,
                    expectedIdentity: file.identity,
                    expectedDescendants: file.descendants
                )
            }
        }

        return inventory.rootItems
            .filter { !$0.name.hasPrefix(Self.resetTransactionPrefix) }
            .map { item in
                ResetRequest(
                    originalURL: rootDirectory.appendingPathComponent(item.name),
                    components: [item.name],
                    expectedIdentity: item.identity,
                    expectedDescendants: item.descendants
                )
            }
    }

    /// Captures a complete no-follow inventory with a newly opened reset root.
    private func credentialInventory(for entries: [MCPAuthEntry]) throws -> CredentialInventory {
        let root = try openResetRoot()
        let rootIdentity = try identity(of: root.rawValue)
        return try credentialInventory(
            for: entries,
            root: root,
            rootIdentity: rootIdentity
        )
    }

    /// Binds scanner output to exact root children and descriptor-relative leaf identities.
    private func credentialInventory(
        for entries: [MCPAuthEntry],
        root: ResetFileDescriptor,
        rootIdentity: ResetFileIdentity
    ) throws -> CredentialInventory {
        try validateRoot(root, expected: rootIdentity)
        let rootNames = try boundedEntryNames(
            in: root,
            expected: rootIdentity,
            at: rootDirectory,
            maximumCount: Self.maximumResetRootEntries
        )
        var remainingDescendantCount = Self.maximumResetDescendantEntries
        var rootItems: [CredentialInventory.RootItem] = []
        for name in rootNames.sorted() {
            let itemURL = rootDirectory.appendingPathComponent(name, isDirectory: true)
            let itemIdentity = try identity(named: name, relativeTo: root)
            let descendants: [CredentialInventory.Descendant]
            if itemIdentity.isDirectory {
                let directory = try openDirectory(named: name, relativeTo: root)
                guard try identity(of: directory.rawValue) == itemIdentity else {
                    throw ResetTransactionError.unsafeComponent(itemURL)
                }
                descendants = try credentialDescendants(
                    in: directory,
                    expected: itemIdentity,
                    at: itemURL,
                    prefix: "",
                    remainingCount: &remainingDescendantCount
                )
            } else {
                descendants = []
            }
            rootItems.append(CredentialInventory.RootItem(
                name: name,
                identity: itemIdentity,
                descendants: descendants
            ))
        }

        let inventoryEntries = try entries.map { entry in
            let files = try entry.files.map { file -> CredentialInventory.File in
                let components = try relativeComponents(for: file.url)
                guard components.count >= 2,
                      let rootItem = rootItems.first(where: { $0.name == components[0] }) else {
                    throw ResetTransactionError.unsafeComponent(file.url)
                }
                let pathBelowRootItem = components.dropFirst().joined(separator: "/")
                guard let fileItem = rootItem.descendants.first(where: {
                    $0.relativePath == pathBelowRootItem
                }) else {
                    throw ResetTransactionError.unsafeComponent(file.url)
                }
                let descendantPrefix = pathBelowRootItem + "/"
                let fileDescendants = rootItem.descendants.compactMap { descendant -> CredentialInventory.Descendant? in
                    guard descendant.relativePath.hasPrefix(descendantPrefix) else { return nil }
                    return CredentialInventory.Descendant(
                        relativePath: String(descendant.relativePath.dropFirst(descendantPrefix.count)),
                        identity: descendant.identity
                    )
                }
                return CredentialInventory.File(
                    relativePath: components.joined(separator: "/"),
                    identity: fileItem.identity,
                    descendants: fileDescendants
                )
            }.sorted { $0.relativePath < $1.relativePath }
            return CredentialInventory.Entry(
                versionDirectory: entry.versionDirectory,
                hash: entry.hash,
                files: files
            )
        }.sorted {
            ($0.versionDirectory, $0.hash) < ($1.versionDirectory, $1.hash)
        }

        try validateRoot(root, expected: rootIdentity)
        return CredentialInventory(rootItems: rootItems, entries: inventoryEntries)
    }

    /// Validates one scanner URL as a safe path below the configured cache root.
    private func relativeComponents(for url: URL) throws -> [String] {
        let rootComponents = rootDirectory.standardizedFileURL.pathComponents
        let pathComponents = url.standardizedFileURL.pathComponents
        guard pathComponents.count > rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ResetTransactionError.unsafeComponent(url)
        }
        let relative = Array(pathComponents.dropFirst(rootComponents.count))
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ResetTransactionError.unsafeComponent(url)
        }
        return relative
    }

    /// Recursively captures one no-follow subtree under a shared aggregate entry budget.
    private func credentialDescendants(
        in directory: ResetFileDescriptor,
        expected directoryIdentity: ResetFileIdentity,
        at directoryURL: URL,
        prefix: String,
        remainingCount: inout Int,
        validatePathIdentity: Bool = true
    ) throws -> [CredentialInventory.Descendant] {
        let names = try boundedEntryNames(
            in: directory,
            expected: directoryIdentity,
            at: directoryURL,
            maximumCount: remainingCount,
            validatePathIdentity: validatePathIdentity
        ).sorted()
        remainingCount -= names.count

        var descendants: [CredentialInventory.Descendant] = []
        for name in names {
            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let childURL = directoryURL.appendingPathComponent(name)
            let childIdentity = try identity(named: name, relativeTo: directory)
            descendants.append(CredentialInventory.Descendant(
                relativePath: relativePath,
                identity: childIdentity
            ))
            if childIdentity.isDirectory {
                let child = try openDirectory(named: name, relativeTo: directory)
                guard try identity(of: child.rawValue) == childIdentity else {
                    throw ResetTransactionError.unsafeComponent(childURL)
                }
                descendants += try credentialDescendants(
                    in: child,
                    expected: childIdentity,
                    at: childURL,
                    prefix: relativePath,
                    remainingCount: &remainingCount,
                    validatePathIdentity: validatePathIdentity
                )
            }
        }
        guard try identity(of: directory.rawValue) == directoryIdentity else {
            throw ResetTransactionError.unsafeComponent(directoryURL)
        }
        return descendants
    }

    /// Creates an owner-only transaction directory relative to the validated
    /// root descriptor.
    private func createTransaction(named name: String, root: ResetFileDescriptor) throws {
        guard mkdirat(root.rawValue, name, 0o700) == 0 else {
            throw currentPOSIXError()
        }
    }

    /// Moves one exact directory entry into the transaction after a second
    /// no-follow identity validation at the injected race boundary.
    ///
    /// The leaf is intentionally never opened. This permits reset-only
    /// symlinks, FIFOs and other special entries to be removed without reading,
    /// blocking on, or following their contents.
    private func stage(
        _ request: ResetRequest,
        index: Int,
        root: ResetFileDescriptor,
        rootIdentity: ResetFileIdentity,
        transaction: ResetFileDescriptor,
        expectedRootNames: Set<String>?
    ) throws -> ResetMove {
        let parentComponents = Array(request.components.dropLast())
        let destinationName = try requireLeaf(request.components, url: request.originalURL)
        let initialParent = try openDirectory(components: parentComponents, root: root)
        let initialParentIdentity = try identity(of: initialParent.rawValue)
        let itemIdentity = try identity(named: destinationName, relativeTo: initialParent)
        guard itemIdentity == request.expectedIdentity else {
            throw MCPAuthError.fileChangedExternally
        }

        try beforeResetStage(index, request.originalURL)
        try validateRoot(root, expected: rootIdentity)

        let verifiedParent = try openDirectory(components: parentComponents, root: root)
        guard try identity(of: verifiedParent.rawValue) == initialParentIdentity else {
            throw ResetTransactionError.unsafeComponent(request.originalURL)
        }
        guard try identity(named: destinationName, relativeTo: verifiedParent) == itemIdentity else {
            throw ResetTransactionError.unsafeComponent(request.originalURL)
        }

        try beforeResetRename(index, request.originalURL)
        try validateRoot(root, expected: rootIdentity)
        let actionParent = try openDirectory(components: parentComponents, root: root)
        guard try identity(of: verifiedParent.rawValue) == initialParentIdentity,
              try identity(of: actionParent.rawValue) == initialParentIdentity,
              try identity(named: destinationName, relativeTo: actionParent)
                == request.expectedIdentity else {
            throw MCPAuthError.fileChangedExternally
        }
        try validateConfirmedSubtree(
            request,
            destinationName: destinationName,
            parent: actionParent
        )
        if let expectedRootNames {
            let actualNames = try boundedEntryNames(
                in: root,
                expected: rootIdentity,
                at: rootDirectory,
                maximumCount: Self.maximumResetRootEntries + 1
            )
            guard Set(actualNames) == expectedRootNames,
                  actualNames.count == expectedRootNames.count else {
                throw MCPAuthError.fileChangedExternally
            }
        }

        let stagedName = String(format: "%04d-%@", index, destinationName)
        guard renameatx_np(
            actionParent.rawValue,
            destinationName,
            transaction.rawValue,
            stagedName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw currentPOSIXError()
        }

        let move = ResetMove(
            originalURL: request.originalURL,
            parentComponents: parentComponents,
            destinationParent: actionParent,
            destinationName: destinationName,
            stagedName: stagedName,
            validatedIdentity: itemIdentity,
            stagedIdentity: itemIdentity,
            expectedDescendants: request.expectedDescendants
        )
        return move
    }

    /// Re-captures a confirmed directory artifact immediately before its namespace move.
    private func validateConfirmedSubtree(
        _ request: ResetRequest,
        destinationName: String,
        parent: ResetFileDescriptor
    ) throws {
        try validateConfirmedSubtree(
            expectedIdentity: request.expectedIdentity,
            expectedDescendants: request.expectedDescendants,
            destinationName: destinationName,
            parent: parent,
            originalURL: request.originalURL
        )
    }

    /// Revalidates one moved item while it is still contained by the private transaction.
    private func validateStagedMove(
        _ move: ResetMove,
        transaction: ResetFileDescriptor
    ) throws {
        try validateConfirmedSubtree(
            expectedIdentity: move.stagedIdentity,
            expectedDescendants: move.expectedDescendants,
            destinationName: move.stagedName,
            parent: transaction,
            originalURL: move.originalURL,
            validatePathIdentity: false
        )
    }

    /// Compares one exact descriptor-relative subtree with the confirmation inventory.
    private func validateConfirmedSubtree(
        expectedIdentity: ResetFileIdentity,
        expectedDescendants: [CredentialInventory.Descendant],
        destinationName: String,
        parent: ResetFileDescriptor,
        originalURL: URL,
        validatePathIdentity: Bool = true
    ) throws {
        guard try identity(named: destinationName, relativeTo: parent) == expectedIdentity else {
            throw MCPAuthError.fileChangedExternally
        }
        guard expectedIdentity.isDirectory else {
            guard expectedDescendants.isEmpty else {
                throw MCPAuthError.fileChangedExternally
            }
            return
        }

        let directory = try openDirectory(named: destinationName, relativeTo: parent)
        guard try identity(of: directory.rawValue) == expectedIdentity else {
            throw MCPAuthError.fileChangedExternally
        }
        var remainingCount = Self.maximumResetDescendantEntries
        let descendants = try credentialDescendants(
            in: directory,
            expected: expectedIdentity,
            at: originalURL,
            prefix: "",
            remainingCount: &remainingCount,
            validatePathIdentity: validatePathIdentity
        )
        guard descendants == expectedDescendants else {
            throw MCPAuthError.fileChangedExternally
        }
    }

    /// Restores every staged item only after preflighting all destinations.
    /// Occupied or replaced destinations retain the transaction intact.
    private func recover(
        _ moves: [ResetMove],
        after primaryError: Error,
        root: ResetFileDescriptor,
        rootIdentity: ResetFileIdentity,
        transaction: ResetFileDescriptor,
        transactionIdentity: ResetFileIdentity,
        transactionContainer: ResetFileDescriptor,
        transactionName: String,
        transactionURL: URL
    ) throws {
        let resolvedRecoveryURL = currentRecoveryURL(
            for: transaction,
            expected: transactionIdentity
        )
        let recoveryURL = (resolvedRecoveryURL ?? transactionURL).standardizedFileURL
        let requiresPersistentRecord: Bool
        if let resolvedRecoveryURL {
            requiresPersistentRecord = !isEnumeratedRecoveryDirectory(resolvedRecoveryURL)
        } else {
            requiresPersistentRecord = (try? identity(at: transactionURL)) != transactionIdentity
        }
        guard !moves.isEmpty else {
            try? removeEmptyTransaction(named: transactionName, parent: transactionContainer)
            return
        }

        do {
            try validateRoot(root, expected: rootIdentity)
            let sourceConflicts = moves.compactMap { move -> URL? in
                let currentIdentity = try? identity(
                    named: move.stagedName,
                    relativeTo: transaction
                )
                return currentIdentity == move.stagedIdentity ? nil : move.originalURL
            }
            guard sourceConflicts.isEmpty else {
                try throwRecoveryConflict(
                    at: recoveryURL,
                    destinations: sourceConflicts,
                    primaryError: primaryError,
                    transactionIdentity: transactionIdentity,
                    requiresPersistentRecord: requiresPersistentRecord
                )
            }

            var conflicts: [URL] = []
            for move in moves {
                let currentParent = try openDirectory(components: move.parentComponents, root: root)
                if try identity(of: currentParent.rawValue) != identity(of: move.destinationParent.rawValue)
                    || (try itemExists(move.destinationName, relativeTo: currentParent)) {
                    conflicts.append(move.originalURL)
                }
            }
            guard conflicts.isEmpty else {
                try throwRecoveryConflict(
                    at: recoveryURL,
                    destinations: conflicts,
                    primaryError: primaryError,
                    transactionIdentity: transactionIdentity,
                    requiresPersistentRecord: requiresPersistentRecord
                )
            }

            for (index, move) in moves.reversed().enumerated() {
                try validateRoot(root, expected: rootIdentity)
                let expectedParentIdentity = try identity(of: move.destinationParent.rawValue)
                let currentParent = try openDirectory(components: move.parentComponents, root: root)
                guard try identity(of: currentParent.rawValue) == expectedParentIdentity,
                      try !itemExists(move.destinationName, relativeTo: currentParent) else {
                    try throwRecoveryConflict(
                        at: recoveryURL,
                        destinations: [move.originalURL],
                        primaryError: primaryError,
                        transactionIdentity: transactionIdentity,
                        requiresPersistentRecord: requiresPersistentRecord
                    )
                }

                try beforeRecoveryRename(index, move.originalURL)
                try validateRoot(root, expected: rootIdentity)

                let recoveryParent = try openDirectory(components: move.parentComponents, root: root)
                guard try identity(of: recoveryParent.rawValue) == expectedParentIdentity,
                      try !itemExists(move.destinationName, relativeTo: recoveryParent),
                      (try? identity(
                          named: move.stagedName,
                          relativeTo: transaction
                      )) == move.stagedIdentity else {
                    try throwRecoveryConflict(
                        at: recoveryURL,
                        destinations: [move.originalURL],
                        primaryError: primaryError,
                        transactionIdentity: transactionIdentity,
                        requiresPersistentRecord: requiresPersistentRecord
                    )
                }

                let renameResult = renameatx_np(
                    transaction.rawValue,
                    move.stagedName,
                    recoveryParent.rawValue,
                    move.destinationName,
                    UInt32(RENAME_EXCL)
                )
                if renameResult != 0, errno == EEXIST {
                    try throwRecoveryConflict(
                        at: recoveryURL,
                        destinations: [move.originalURL],
                        primaryError: primaryError,
                        transactionIdentity: transactionIdentity,
                        requiresPersistentRecord: requiresPersistentRecord
                    )
                }
                guard renameResult == 0 else {
                    throw currentPOSIXError()
                }

                do {
                    try validateRoot(root, expected: rootIdentity)
                    let pathParent = try openDirectory(components: move.parentComponents, root: root)
                    guard try identity(of: recoveryParent.rawValue) == expectedParentIdentity,
                          try identity(of: pathParent.rawValue) == expectedParentIdentity,
                          try identity(named: move.destinationName, relativeTo: pathParent)
                            == move.stagedIdentity else {
                        throw ResetTransactionError.unsafeComponent(move.originalURL)
                    }
                } catch {
                    do {
                        try returnRecoveredItemToTransaction(
                            move,
                            from: recoveryParent,
                            transaction: transaction
                        )
                    } catch {
                        do {
                            try retainRecoveryDirectory(
                                recoveryURL,
                                identity: transactionIdentity,
                                persist: requiresPersistentRecord
                            )
                        } catch let persistenceError {
                            throw MCPAuthError.recoveryRequired(
                                directory: recoveryURL,
                                primary: primaryError,
                                recovery: persistenceError
                            )
                        }
                        throw MCPAuthError.recoveryRequired(
                            directory: recoveryURL,
                            primary: primaryError,
                            recovery: error
                        )
                    }
                    try throwRecoveryConflict(
                        at: recoveryURL,
                        destinations: [move.originalURL],
                        primaryError: primaryError,
                        transactionIdentity: transactionIdentity,
                        requiresPersistentRecord: requiresPersistentRecord
                    )
                }
            }
            try removeEmptyTransaction(named: transactionName, parent: transactionContainer)
        } catch let conflict as MCPAuthError {
            throw conflict
        } catch {
            do {
                try retainRecoveryDirectory(
                    recoveryURL,
                    identity: transactionIdentity,
                    persist: requiresPersistentRecord
                )
            } catch let persistenceError {
                throw MCPAuthError.recoveryRequired(
                    directory: recoveryURL,
                    primary: primaryError,
                    recovery: persistenceError
                )
            }
            throw MCPAuthError.recoveryRequired(
                directory: recoveryURL,
                primary: primaryError,
                recovery: error
            )
        }
    }

    /// Returns one just-restored exact item to its transaction slot without
    /// overwriting either a destination replacement or staged contents.
    private func returnRecoveredItemToTransaction(
        _ move: ResetMove,
        from parent: ResetFileDescriptor,
        transaction: ResetFileDescriptor
    ) throws {
        guard try identity(named: move.destinationName, relativeTo: parent) == move.stagedIdentity,
              try !itemExists(move.stagedName, relativeTo: transaction) else {
            throw ResetTransactionError.unsafeComponent(move.originalURL)
        }
        guard renameatx_np(
            parent.rawValue,
            move.destinationName,
            transaction.rawValue,
            move.stagedName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw currentPOSIXError()
        }
        guard try identity(named: move.stagedName, relativeTo: transaction) == move.stagedIdentity,
              try !itemExists(move.destinationName, relativeTo: parent) else {
            throw ResetTransactionError.unsafeComponent(move.originalURL)
        }
    }

    /// Publishes a conflict only after preserving any external recovery path
    /// in the durable record required across app launches.
    private func throwRecoveryConflict(
        at recoveryURL: URL,
        destinations: [URL],
        primaryError: Error,
        transactionIdentity: ResetFileIdentity,
        requiresPersistentRecord: Bool
    ) throws -> Never {
        do {
            try retainRecoveryDirectory(
                recoveryURL,
                identity: transactionIdentity,
                persist: requiresPersistentRecord
            )
        } catch {
            throw MCPAuthError.recoveryRequired(
                directory: recoveryURL,
                primary: primaryError,
                recovery: error
            )
        }
        throw MCPAuthError.recoveryConflict(
            directory: recoveryURL,
            destinations: destinations,
            primary: primaryError
        )
    }

    /// Opens all intermediate directories relative to the root and refuses
    /// symlinks at every component.
    private func openDirectory(
        components: [String],
        root: ResetFileDescriptor
    ) throws -> ResetFileDescriptor {
        let duplicated = Darwin.dup(root.rawValue)
        guard duplicated >= 0 else { throw currentPOSIXError() }
        var current = ResetFileDescriptor(duplicated)
        for component in components {
            current = try openDirectory(named: component, relativeTo: current)
        }
        return current
    }

    /// Opens one no-follow directory below an already-open parent.
    private func openDirectory(
        named name: String,
        relativeTo parent: ResetFileDescriptor
    ) throws -> ResetFileDescriptor {
        let descriptor = Darwin.openat(
            parent.rawValue,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return ResetFileDescriptor(descriptor)
    }

    /// Ensures the root path still names the exact opened root descriptor.
    private func validateRoot(
        _ root: ResetFileDescriptor,
        expected: ResetFileIdentity
    ) throws {
        let pathIdentity = try identity(at: rootDirectory)
        guard pathIdentity == expected,
              try identity(of: root.rawValue) == expected else {
            throw ResetTransactionError.unsafeRoot(rootDirectory)
        }
    }

    /// Ensures the private app staging path still names the opened owner-only
    /// directory before a path-based system API receives a child URL.
    private func validateResetStagingRoot(
        _ root: ResetFileDescriptor,
        expected: ResetFileIdentity
    ) throws {
        let pathIdentity = try identity(at: resetStagingDirectory)
        guard pathIdentity == expected,
              pathIdentity.isDirectory,
              pathIdentity.owner == geteuid(),
              pathIdentity.mode & 0o077 == 0,
              try identity(of: root.rawValue) == expected else {
            throw ResetTransactionError.unsafeRoot(resetStagingDirectory)
        }
    }

    /// Ensures the transaction URL still names the exact private directory.
    private func validateTransaction(
        _ name: String,
        parent: ResetFileDescriptor,
        expected: ResetFileIdentity,
        url: URL
    ) throws {
        guard try identity(named: name, relativeTo: parent) == expected else {
            throw ResetTransactionError.unsafeComponent(url)
        }
    }

    /// Returns identity metadata for an open descriptor.
    private func identity(of descriptor: Int32) throws -> ResetFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw currentPOSIXError() }
        return ResetFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            owner: info.st_uid
        )
    }

    /// Resolves the transaction's current path from its still-open descriptor.
    /// The path is accepted only when it still names the captured owner-only
    /// directory identity, including after a path-based Trash move.
    private func currentRecoveryURL(
        for transaction: ResetFileDescriptor,
        expected: ResetFileIdentity
    ) -> URL? {
        guard expected.isDirectory,
              expected.owner == geteuid(),
              expected.mode & 0o077 == 0,
              (try? identity(of: transaction.rawValue)) == expected else {
            return nil
        }

        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBufferPointer { buffer in
            fcntl(transaction.rawValue, F_GETPATH, buffer.baseAddress!)
        }
        guard result == 0 else { return nil }

        let url = path.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: true,
                relativeTo: nil
            )
        }
        guard (try? identity(at: url)) == expected else { return nil }
        return url
    }

    /// Returns no-follow identity metadata for a descriptor-relative leaf.
    private func identity(
        named name: String,
        relativeTo parent: ResetFileDescriptor
    ) throws -> ResetFileIdentity {
        var info = stat()
        guard fstatat(parent.rawValue, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw currentPOSIXError()
        }
        return ResetFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            owner: info.st_uid
        )
    }

    /// Returns no-follow identity metadata after securing every intermediate path component.
    private func identity(at url: URL) throws -> ResetFileIdentity {
        let info: stat
        do {
            info = try SecureAbsolutePath.status(at: url)
        } catch {
            throw ResetTransactionError.unsafeComponent(url)
        }
        return ResetFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            owner: info.st_uid
        )
    }

    /// Accepts Trash success only when the returned path names the exact
    /// transaction inode and the private staging source no longer exists.
    private func validateTrashResult(
        _ trashedURL: URL,
        expected transactionIdentity: ResetFileIdentity,
        stagingRoot: ResetFileDescriptor,
        transactionName: String,
        stagedURL: URL
    ) throws {
        guard try identity(at: trashedURL) == transactionIdentity,
              try !itemExists(transactionName, relativeTo: stagingRoot) else {
            throw ResetTransactionError.unexpectedTrashResult(stagedURL)
        }
    }

    /// Reports whether a no-follow descriptor-relative path is occupied.
    private func itemExists(
        _ name: String,
        relativeTo parent: ResetFileDescriptor
    ) throws -> Bool {
        var info = stat()
        if fstatat(parent.rawValue, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        guard errno == ENOENT else { throw currentPOSIXError() }
        return false
    }

    /// Removes an empty transaction only through the opened root descriptor.
    private func removeEmptyTransaction(
        named name: String,
        parent: ResetFileDescriptor
    ) throws {
        if unlinkat(parent.rawValue, name, AT_REMOVEDIR) != 0, errno != ENOENT {
            throw currentPOSIXError()
        }
    }

    /// Extracts a non-empty leaf component from a validated relative path.
    private func requireLeaf(_ components: [String], url: URL) throws -> String {
        guard let leaf = components.last, !leaf.isEmpty else {
            throw ResetTransactionError.unsafeComponent(url)
        }
        return leaf
    }

    /// Captures the current Darwin error before another system call can change
    /// `errno`.
    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Production Trash boundary that returns the resulting URL so callers
    /// can verify the identity moved by the path-based API.
    nonisolated private static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else {
            throw ResetTransactionError.unexpectedTrashResult(url)
        }
        return result as URL
    }

    /// Retains a recovery URL and persists external locations that cannot be
    /// rediscovered by enumerating the app's known transaction roots.
    private func retainRecoveryDirectory(
        _ url: URL,
        identity transactionIdentity: ResetFileIdentity,
        persist: Bool
    ) throws {
        lastRecoveryDirectory = url
        guard persist else { return }

        switch loadRecoveryRecord() {
        case .missing:
            try persistRecoveryRecord(for: url, identity: transactionIdentity)
        case let .valid(existingURL, _, existingIdentity):
            guard existingURL.standardizedFileURL == url.standardizedFileURL,
                  existingIdentity == transactionIdentity else {
                throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
            }
        case .invalid:
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
    }

    /// Atomically creates a `0600` app-support record without replacing any
    /// pre-existing state.
    private func persistRecoveryRecord(
        for url: URL,
        identity transactionIdentity: ResetFileIdentity
    ) throws {
        let parentURL = recoveryRecordURL.deletingLastPathComponent().standardizedFileURL
        let recordName = recoveryRecordURL.lastPathComponent
        guard recoveryRecordURL.isFileURL,
              !recordName.isEmpty,
              recordName != ".",
              recordName != ".." else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }

        let openedParent: (descriptor: Int32, leaf: String)
        do {
            openedParent = try SecureAbsolutePath.openOrCreateParent(
                of: recoveryRecordURL,
                mode: 0o700
            )
        } catch {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
        guard openedParent.leaf == recordName else {
            Darwin.close(openedParent.descriptor)
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
        let parentDescriptor = openedParent.descriptor
        let parent = ResetFileDescriptor(parentDescriptor)
        var parentIdentity = try identity(of: parentDescriptor)
        guard parentIdentity.isDirectory,
              parentIdentity.owner == geteuid(),
              fchmod(parentDescriptor, 0o700) == 0 else {
            throw ResetTransactionError.unsafeRecoveryRecord(parentURL)
        }
        parentIdentity = try identity(of: parentDescriptor)
        guard parentIdentity.mode & 0o077 == 0,
              try identity(at: parentURL) == parentIdentity,
              try !itemExists(recordName, relativeTo: parent) else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RecoveryRecord(url: url, identity: transactionIdentity))
        let temporaryName = ".\(recordName).\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard temporaryDescriptor >= 0 else { throw currentPOSIXError() }
        defer {
            Darwin.close(temporaryDescriptor)
            _ = unlinkat(parentDescriptor, temporaryName, 0)
        }

        try writeAll(data, to: temporaryDescriptor)
        guard fchmod(temporaryDescriptor, 0o600) == 0,
              fsync(temporaryDescriptor) == 0 else {
            throw currentPOSIXError()
        }
        let temporaryIdentity = try identity(of: temporaryDescriptor)
        guard temporaryIdentity.isRegularFile,
              temporaryIdentity.owner == geteuid(),
              temporaryIdentity.mode & mode_t(0o7777) == 0o600,
              try identity(of: parentDescriptor) == parentIdentity,
              try identity(at: parentURL) == parentIdentity else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }

        guard renameatx_np(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            recordName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw currentPOSIXError()
        }
        guard try identity(named: recordName, relativeTo: parent) == temporaryIdentity,
              try identity(at: recoveryRecordURL) == temporaryIdentity,
              try identity(of: parentDescriptor) == parentIdentity,
              try identity(at: parentURL) == parentIdentity,
              fsync(parentDescriptor) == 0 else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
    }

    /// Loads and validates only the owner-only record and its exact no-follow
    /// target path. Any present but untrusted state remains blocking.
    private func loadRecoveryRecord() -> RecoveryRecordLoad {
        let openedParent: (descriptor: Int32, leaf: String)
        do {
            openedParent = try SecureAbsolutePath.openParent(of: recoveryRecordURL)
        } catch let error as SecureAbsolutePathError where error == .missing {
            return .missing
        } catch {
            return .invalid(reportedURL: nil)
        }
        let recordParent = ResetFileDescriptor(openedParent.descriptor)

        var recordInfo = stat()
        let recordStatResult = openedParent.leaf.withCString {
            fstatat(openedParent.descriptor, $0, &recordInfo, AT_SYMLINK_NOFOLLOW)
        }
        if recordStatResult != 0 {
            return errno == ENOENT ? .missing : .invalid(reportedURL: nil)
        }
        let recordPathIdentity = ResetFileIdentity(
            device: recordInfo.st_dev,
            inode: recordInfo.st_ino,
            mode: recordInfo.st_mode,
            owner: recordInfo.st_uid
        )
        guard recordPathIdentity.isRegularFile,
              recordPathIdentity.owner == geteuid(),
              recordPathIdentity.mode & mode_t(0o7777) == 0o600 else {
            return .invalid(reportedURL: nil)
        }

        let recordDescriptor = openedParent.leaf.withCString {
            openat(openedParent.descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard recordDescriptor >= 0 else { return .invalid(reportedURL: nil) }
        defer { Darwin.close(recordDescriptor) }
        guard (try? identity(of: recordDescriptor)) == recordPathIdentity,
              (try? identity(named: openedParent.leaf, relativeTo: recordParent)) == recordPathIdentity,
              (try? identity(at: recoveryRecordURL)) == recordPathIdentity,
              let data = try? readRecoveryRecordData(from: recordDescriptor),
              let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data) else {
            return .invalid(reportedURL: nil)
        }

        let candidate = URL(fileURLWithPath: record.path, isDirectory: true)
        let reportedURL = record.path.hasPrefix("/") ? candidate : nil
        guard record.path.hasPrefix("/"),
              candidate.standardizedFileURL.path == record.path,
              candidate.lastPathComponent.hasPrefix(Self.resetTransactionPrefix) else {
            return .invalid(reportedURL: reportedURL)
        }

        let transactionDescriptor: Int32
        do {
            transactionDescriptor = try SecureAbsolutePath.openDirectory(at: candidate)
        } catch {
            return .invalid(reportedURL: candidate)
        }
        defer { Darwin.close(transactionDescriptor) }
        guard let transactionIdentity = try? identity(of: transactionDescriptor),
              (try? identity(at: candidate)) == transactionIdentity,
              record.matches(transactionIdentity),
              transactionIdentity.isDirectory,
              transactionIdentity.owner == geteuid(),
              transactionIdentity.mode & 0o077 == 0 else {
            return .invalid(reportedURL: candidate)
        }
        return .valid(
            candidate,
            recordIdentity: recordPathIdentity,
            transactionIdentity: transactionIdentity
        )
    }

    /// Discovers retained owner-only transactions on reload. A durable record
    /// takes precedence and remains fail-closed when stale or tampered.
    private func refreshRecoveryDirectory() {
        recoveryDiscoveryRefusedAt = nil
        switch loadRecoveryRecord() {
        case .missing:
            break
        case let .valid(url, recordIdentity, transactionIdentity):
            if recoveryDirectoryIsEmpty(url, expected: transactionIdentity) {
                do {
                    try clearResolvedRecoveryRecord(
                        recoveryURL: url,
                        transactionIdentity: transactionIdentity,
                        recordIdentity: recordIdentity
                    )
                    lastRecoveryDirectory = nil
                } catch {
                    lastRecoveryDirectory = url
                }
            } else {
                lastRecoveryDirectory = url
            }
            return
        case let .invalid(reportedURL):
            lastRecoveryDirectory = reportedURL ?? recoveryRecordURL
            return
        }

        if let lastRecoveryDirectory,
           isOwnedRecoveryDirectory(lastRecoveryDirectory) {
            return
        }

        var candidates: [URL] = []
        for directory in [resetStagingDirectory, rootDirectory] {
            switch recoveryDirectories(in: directory) {
            case let .directories(discovered):
                candidates += discovered
            case .refused:
                recoveryDiscoveryRefusedAt = directory
                lastRecoveryDirectory = nil
                return
            }
        }
        lastRecoveryDirectory = candidates.sorted { $0.path < $1.path }.first
    }

    /// Clears the exact persistence record only after the exact transaction
    /// directory has been observed empty twice without following links.
    private func clearResolvedRecoveryRecord(
        recoveryURL: URL,
        transactionIdentity: ResetFileIdentity,
        recordIdentity: ResetFileIdentity
    ) throws {
        guard recoveryDirectoryIsEmpty(recoveryURL, expected: transactionIdentity) else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
        let parentURL = recoveryRecordURL.deletingLastPathComponent().standardizedFileURL
        let openedParent: (descriptor: Int32, leaf: String)
        do {
            openedParent = try SecureAbsolutePath.openParent(of: recoveryRecordURL)
        } catch {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
        let parentDescriptor = openedParent.descriptor
        let parent = ResetFileDescriptor(parentDescriptor)
        let parentIdentity = try identity(of: parentDescriptor)
        guard parentIdentity.isDirectory,
              parentIdentity.owner == geteuid(),
              parentIdentity.mode & 0o077 == 0,
              try identity(at: parentURL) == parentIdentity,
              try identity(named: openedParent.leaf, relativeTo: parent) == recordIdentity,
              recoveryDirectoryIsEmpty(recoveryURL, expected: transactionIdentity),
              unlinkat(parentDescriptor, openedParent.leaf, 0) == 0,
              fsync(parentDescriptor) == 0 else {
            throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
        }
    }

    /// Checks an exact no-follow directory descriptor for any retained child.
    private func recoveryDirectoryIsEmpty(
        _ url: URL,
        expected: ResetFileIdentity
    ) -> Bool {
        guard let descriptor = try? SecureAbsolutePath.openDirectory(at: url) else {
            return false
        }
        defer { Darwin.close(descriptor) }
        guard (try? identity(of: descriptor)) == expected,
              (try? identity(at: url)) == expected else { return false }

        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return false }
        guard let directory = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            return false
        }
        defer { closedir(directory) }

        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return false }
            errno = 0
        }
        guard errno == 0,
              (try? identity(of: descriptor)) == expected,
              (try? identity(at: url)) == expected else { return false }
        return true
    }

    /// Returns whether a recovery URL is already rediscoverable below one of
    /// the two narrowly enumerated transaction roots.
    private func isEnumeratedRecoveryDirectory(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix(Self.resetTransactionPrefix) else { return false }
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        return parentPath == rootDirectory.standardizedFileURL.path
            || parentPath == resetStagingDirectory.standardizedFileURL.path
    }

    /// Writes every byte to a descriptor, retrying interrupted system calls.
    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    /// Reads a bounded recovery record so malformed files cannot cause an
    /// unbounded allocation during app launch.
    private func readRecoveryRecordData(from descriptor: Int32) throws -> Data {
        let maximumSize = 64 * 1024
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard result.count + count <= maximumSize else {
                throw ResetTransactionError.unsafeRecoveryRecord(recoveryRecordURL)
            }
            result.append(buffer, count: count)
        }
    }

    /// Result of bounded discovery below one known reset root.
    private enum RecoveryDirectoryDiscovery {
        /// Safe owner-only recovery directories found within the entry bound.
        case directories([URL])
        /// The root could not be verified or exceeded the entry bound.
        case refused
    }

    /// Lists valid transaction directories immediately below one known root
    /// without materializing more than the shared top-level safety ceiling.
    private func recoveryDirectories(in directory: URL) -> RecoveryDirectoryDiscovery {
        let descriptor: Int32
        do {
            descriptor = try SecureAbsolutePath.openDirectory(at: directory)
        } catch let error as SecureAbsolutePathError where error == .missing {
            return .directories([])
        } catch {
            return .refused
        }
        let root = ResetFileDescriptor(descriptor)

        do {
            let expected = try identity(of: descriptor)
            guard expected.isDirectory,
                  expected.owner == geteuid(),
                  expected.mode & 0o022 == 0,
                  try identity(at: directory) == expected else {
                return .refused
            }
            let names = try boundedEntryNames(
                in: root,
                expected: expected,
                at: directory,
                maximumCount: Self.maximumResetRootEntries
            )
            let candidates = try names.compactMap { name -> URL? in
                guard name.hasPrefix(Self.resetTransactionPrefix) else { return nil }
                let candidate = try identity(named: name, relativeTo: root)
                guard candidate.isDirectory,
                      candidate.owner == geteuid(),
                      candidate.mode & 0o077 == 0 else { return nil }
                return directory.appendingPathComponent(name, isDirectory: true)
            }
            return .directories(candidates)
        } catch {
            return .refused
        }
    }

    /// Enumerates one already-open directory through an independently opened descriptor,
    /// stopping before an attacker-controlled number of names is materialized.
    private func boundedEntryNames(
        in directory: ResetFileDescriptor,
        expected: ResetFileIdentity,
        at url: URL,
        maximumCount: Int,
        validatePathIdentity: Bool = true
    ) throws -> [String] {
        let initialPathMatches: Bool
        if validatePathIdentity {
            initialPathMatches = try identity(at: url) == expected
        } else {
            initialPathMatches = true
        }
        guard maximumCount >= 0,
              try identity(of: directory.rawValue) == expected,
              initialPathMatches else {
            throw ResetTransactionError.unsafeRoot(url)
        }

        let enumerationDescriptor = Darwin.openat(
            directory.rawValue,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw currentPOSIXError() }
        guard let stream = fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw currentPOSIXError()
        }
        defer { closedir(stream) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
                guard names.count <= maximumCount else {
                    throw ResetTransactionError.tooManyEntries(url)
                }
            }
            errno = 0
        }
        let finalPathMatches: Bool
        if validatePathIdentity {
            finalPathMatches = try identity(at: url) == expected
        } else {
            finalPathMatches = true
        }
        guard errno == 0,
              try identity(of: directory.rawValue) == expected,
              finalPathMatches else {
            throw ResetTransactionError.unsafeRoot(url)
        }
        return names.sorted()
    }

    /// Recognizes only owner-only directories with CodingBuddy's reserved
    /// transaction prefix; symlinks and permissive lookalikes are ignored.
    private func isOwnedRecoveryDirectory(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix(Self.resetTransactionPrefix),
              let itemIdentity = try? identity(at: url) else { return false }
        return itemIdentity.isDirectory
            && itemIdentity.owner == geteuid()
            && itemIdentity.mode & 0o077 == 0
    }

    // MARK: - File watching

    private func startWatching() {
        var watchedURLs = [rootDirectory]
        watchedURLs += Set(entries.map(\.versionDirectory)).map {
            rootDirectory.appendingPathComponent($0, isDirectory: true)
        }
        // The cache may not exist yet — watch the parent so the first OAuth
        // flow creating ~/.mcp-auth triggers a reload.
        if !rootExists {
            watchedURLs.append(rootDirectory.deletingLastPathComponent())
        }
        if FileManager.default.fileExists(atPath: resetStagingDirectory.path) {
            watchedURLs.append(resetStagingDirectory)
        } else {
            watchedURLs.append(resetStagingDirectory.deletingLastPathComponent())
        }
        monitor.watch(watchedURLs)
    }
}
