//
//  SafeFileWriter.swift
//  CodingBuddy
//

import Darwin
import Foundation

/// The write-safety machinery shared by every store that mutates user files.
///
/// A write is anchored to open directory descriptors. Existing content,
/// identity and permissions are captured once, backed up through descriptors,
/// and revalidated immediately before the atomic rename. Symlinks are followed
/// deliberately and revalidated without replacing the link itself.
nonisolated struct SafeFileWriter {
    /// Fail-closed errors that callers can distinguish from ordinary I/O failures.
    enum WriteError: LocalizedError, Equatable {
        /// The target's content or identity changed after the caller read it.
        case staleOriginal
        /// The target path is a directory, special file, or otherwise unsafe.
        case unsafeTarget
        /// The requested path ends in a symbolic link whose destination is missing.
        case danglingSymlink
        /// The backup destination is a symlink or is not a private owned directory.
        case unsafeBackupDirectory
        /// The target exceeds a caller-supplied bounded-read ceiling.
        case targetTooLarge
        /// Backup discovery exceeded its explicit directory-entry safety boundary.
        case backupDirectoryTooLarge(maximum: Int)

        /// Localized description suitable for existing mutation alerts.
        var errorDescription: String? {
            switch self {
            case .staleOriginal:
                String(localized: "The file was changed externally. Please try again.")
            case .unsafeTarget, .danglingSymlink:
                String(localized: "CodingBuddy cannot safely write to the selected target file.")
            case .unsafeBackupDirectory:
                String(localized: "CodingBuddy cannot safely write to the selected target file.")
            case .targetTooLarge:
                String(localized: "CodingBuddy cannot safely read this file because it is unexpectedly large.")
            case .backupDirectoryTooLarge:
                String(localized: "CodingBuddy cannot safely write to the selected target file.")
            }
        }
    }

    /// Fail-closed recovery details for a write that could not finish cleanly.
    struct RecoveryError: LocalizedError, Equatable {
        /// Best-known state of the requested target mutation.
        enum CommitState: Equatable {
            /// The requested content was not left committed at the target.
            case notCommitted
            /// The requested content was committed before residual cleanup failed.
            case committed
            /// Racing changes prevented the transaction from proving the final target state.
            case unknown
        }

        /// Best-known state of the requested target mutation.
        let commitState: CommitState
        /// Filesystem entries deliberately retained for recovery or inspection.
        let artifacts: [RecoveryArtifact]

        /// Localized description suitable for existing mutation alerts.
        var errorDescription: String? {
            let path = artifacts.first?.lastKnownPath ?? ""
            switch commitState {
            case .notCommitted:
                return String(
                    format: String(localized: "CodingBuddy did not save the requested change. Review the retained recovery file at %@ before retrying."),
                    path
                )
            case .committed:
                return String(
                    format: String(localized: "CodingBuddy saved the requested change, but cleanup stopped. Review the retained recovery file at %@ before editing again."),
                    path
                )
            case .unknown:
                return String(
                    format: String(localized: "CodingBuddy cannot confirm the final save state. Review the retained recovery file at %@ before editing again."),
                    path
                )
            }
        }
    }

    /// Reports a committed write whose final cleanup metadata could not be synced.
    ///
    /// The displaced inode has already been removed from the live namespace, so
    /// there is no recovery artifact to reveal. The error keeps callers from
    /// claiming that the whole write failed while still asking the user to
    /// verify the committed target before another edit.
    struct CleanupDurabilityError: LocalizedError, Equatable {
        /// Localized description that does not invent a retained recovery path.
        var errorDescription: String? {
            String(localized: "CodingBuddy saved the requested change, but macOS could not confirm that cleanup was durable. Verify the current file before editing again.")
        }
    }

    /// A filesystem entry deliberately retained for manual recovery or inspection.
    ///
    /// `lastKnownPath` may become stale if another actor renames its containing
    /// directory. The context describes why CodingBuddy retained the entry; it
    /// does not claim that a racing actor left the expected inode at that path.
    struct RecoveryArtifact: Equatable {
        /// Transaction phase that caused the entry to be retained.
        enum Context: Equatable {
            /// A staged replacement could not be safely removed after a failed write.
            case stagedWrite
            /// The original inode displaced by a successful replacement was retained.
            case displacedOriginal
            /// An incomplete backup was retained after backup creation failed.
            case failedBackup
            /// Cleanup retained a backup outside the active retention window.
            case prunedBackup
            /// The target path was retained because its post-swap contents are uncertain.
            case uncertainTarget
            /// The displaced path was retained because its post-swap contents are uncertain.
            case uncertainDisplaced
        }

        /// Best-known absolute path at the time the artifact was retained.
        let lastKnownPath: String
        /// Transaction phase that produced the recovery artifact.
        let context: Context
    }

    /// Deterministic transaction boundaries used by adversarial tests.
    enum TransactionPoint {
        /// A caller-supplied snapshot is about to be revalidated for writing.
        case beforeSnapshotValidation
        /// The temporary file and backup exist; final revalidation has not run yet.
        case beforeCommit
        /// Final revalidation passed; the atomic compare-and-swap has not run yet.
        case afterFinalValidation
        /// A new file was renamed into place; post-commit path checks have not run yet.
        case afterNewFileCommit
        /// A failed replacement was inspected; rollback has not run yet.
        case beforeRollback
        /// A cleanup candidate was validated; it has not been atomically quarantined yet.
        case afterCleanupValidation
        /// Backup bytes were written; permission and durability checks have not run yet.
        case beforeBackupSync
        /// A quarantined candidate matched before the final pre-unlink revalidation.
        case afterQuarantineValidation
        /// The committed directory entry is about to be made durable.
        case beforeParentDirectorySync
    }

    /// Opaque read state that binds bytes to the descriptors and identities used for a later write.
    ///
    /// Callers can inspect the captured bytes but cannot construct or retarget a
    /// snapshot. Keeping this value alive also keeps its directory and file
    /// descriptors alive until the corresponding write completes.
    struct Snapshot {
        fileprivate let target: ResolvedTarget
        fileprivate let original: TargetSnapshot?
        fileprivate let requestedPath: String
        fileprivate let requestedName: String

        /// Decodes the captured bytes as UTF-8, or returns `nil` when the target
        /// did not exist. Filesystem identities remain private to the token.
        func utf8Content() throws -> String? {
            guard let original else { return nil }
            guard let content = String(data: original.data, encoding: .utf8) else {
                throw CocoaError(
                    .fileReadInapplicableStringEncoding,
                    userInfo: [NSFilePathErrorKey: requestedPath]
                )
            }
            return content
        }
    }

    /// Directory that receives timestamped copies before existing files are replaced.
    var backupDirectory: URL
    /// Maximum number of backups retained per source-file basename.
    var backupRetention = 20
    /// Maximum number of entries inspected while creating and pruning backups.
    var maximumBackupDirectoryEntryCount: Int
    /// POSIX mode applied when the write creates a brand-new file.
    var createMode: Int?
    /// Internal hook for deterministic race tests; production callers leave it nil.
    var transactionHook: ((TransactionPoint) throws -> Void)?
    /// Injectable directory durability boundary used by deterministic tests.
    private let syncDirectory: (Int32) throws -> Void

    /// Creates a writer with its backup destination, retention count, and optional mode for new files.
    init(
        backupDirectory: URL,
        backupRetention: Int = 20,
        maximumBackupDirectoryEntryCount: Int = 4_096,
        createMode: Int? = nil,
        transactionHook: ((TransactionPoint) throws -> Void)? = nil,
        syncDirectory: @escaping (Int32) throws -> Void = { descriptor in
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    ) {
        self.backupDirectory = backupDirectory
        self.backupRetention = max(1, backupRetention)
        self.maximumBackupDirectoryEntryCount = max(1, maximumBackupDirectoryEntryCount)
        self.createMode = createMode
        self.transactionHook = transactionHook
        self.syncDirectory = syncDirectory
    }

    /// Captures target bytes and filesystem identity for a later descriptor-bound write.
    func snapshot(at fileURL: URL) throws -> Snapshot {
        let target = try resolveTarget(fileURL)
        return Snapshot(
            target: target,
            original: try snapshotTarget(target),
            requestedPath: fileURL.path,
            requestedName: fileURL.lastPathComponent
        )
    }

    /// Captures a bounded target while optionally creating missing parent directories
    /// through the same descriptor-relative walk retained by the later write.
    ///
    /// Final symbolic links remain supported for existing regular-file targets. A
    /// dangling final link is never populated implicitly, and every followed parent
    /// link and created directory is revalidated before commit.
    func snapshot(
        at fileURL: URL,
        maximumByteCount: Int,
        createMissingParentDirectories: Bool
    ) throws -> Snapshot {
        guard maximumByteCount >= 0 else { throw WriteError.unsafeTarget }
        let target = try resolveTarget(
            fileURL,
            createMissingParentDirectories: createMissingParentDirectories
        )
        return Snapshot(
            target: target,
            original: try snapshotTarget(target, maximumByteCount: maximumByteCount),
            requestedPath: fileURL.path,
            requestedName: fileURL.lastPathComponent
        )
    }

    /// Captures one regular file without following its final path component and
    /// rejects bytes beyond the caller's explicit security boundary. Only
    /// immutable macOS root aliases such as `/var` may appear earlier in the path.
    func noFollowSnapshot(at fileURL: URL, maximumByteCount: Int) throws -> Snapshot {
        guard maximumByteCount >= 0 else { throw WriteError.unsafeTarget }
        let target = try resolveTarget(fileURL)
        guard !target.followedFinalSymlink,
              target.symlinks.allSatisfy(isPermittedSystemAlias) else {
            throw WriteError.unsafeTarget
        }
        return Snapshot(
            target: target,
            original: try snapshotTarget(target, maximumByteCount: maximumByteCount),
            requestedPath: fileURL.path,
            requestedName: fileURL.lastPathComponent
        )
    }

    /// Writes content through a descriptor-anchored transaction.
    ///
    /// When `expectedOriginal` is supplied, the transaction fails unless the
    /// exact UTF-8 bytes are still present. Existing identity, content and mode
    /// are checked again immediately before commit. Unchanged writes are no-ops.
    func write(
        _ content: String,
        to fileURL: URL,
        expectedOriginal: String? = nil
    ) throws {
        let snapshot = try snapshot(at: fileURL)

        if let expectedOriginal {
            guard snapshot.original?.data == Data(expectedOriginal.utf8) else {
                throw WriteError.staleOriginal
            }
        }

        try write(content, using: snapshot)
    }

    /// Writes against the exact descriptors, symlinks and file identity captured by `snapshot(at:)`.
    func write(_ content: String, using snapshot: Snapshot) throws {
        let target = snapshot.target
        let original = snapshot.original
        let newData = Data(content.utf8)

        try transactionHook?(.beforeSnapshotValidation)
        try revalidateSymlinks(target.symlinks)
        try verifyDirectoryBinding(target.parent)
        if let original {
            try revalidate(target, against: original)
        } else {
            try verifyStillMissing(target)
        }
        if original?.data == newData { return }

        if let original {
            try createBackup(of: original, requestedName: snapshot.requestedName)
        }

        let mode = original?.mode ?? mode_t(createMode ?? 0o666)
        let temporaryName = ".\(target.name).codingbuddy-recovery-\(UUID().uuidString)"
        let temporaryFD: Int32
        do {
            temporaryFD = try openFile(
                in: target.parent.raw,
                name: temporaryName,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode: mode
            )
        } catch { throw error }
        defer { Darwin.close(temporaryFD) }
        let stagedIdentity: Identity
        do {
            stagedIdentity = try identity(of: temporaryFD)
        } catch {
            throw RecoveryError(
                commitState: .notCommitted,
                artifacts: [
                    recoveryArtifact(in: target.parent, name: temporaryName, context: .stagedWrite)
                ]
            )
        }

        do {
            try writeAll(newData, to: temporaryFD)
            if original != nil || createMode != nil {
                guard fchmod(temporaryFD, mode) == 0 else { throw currentPOSIXError() }
            }
            guard fsync(temporaryFD) == 0 else {
                throw currentPOSIXError()
            }

            try transactionHook?(.beforeCommit)
            try revalidateSymlinks(target.symlinks)
            try verifyDirectoryBinding(target.parent)
            if let original {
                try revalidate(target, against: original)
            } else {
                try verifyStillMissing(target)
            }
            try transactionHook?(.afterFinalValidation)

            if let original {
                try commitReplacing(
                    target: target,
                    temporaryName: temporaryName,
                    expected: original,
                    stagedIdentity: stagedIdentity
                )
            } else {
                try commitNewFile(
                    target: target,
                    temporaryName: temporaryName,
                    stagedIdentity: stagedIdentity
                )
            }
            do {
                try transactionHook?(.beforeParentDirectorySync)
                try syncDirectory(target.parent.raw)
            } catch {
                let syncError = error
                try rollbackAfterFailedDirectorySync(
                    target: target,
                    temporaryName: temporaryName,
                    original: original,
                    stagedIdentity: stagedIdentity
                )
                throw syncError
            }
            if let original {
                try cleanupCommittedReplacement(
                    target: target,
                    temporaryName: temporaryName,
                    expected: original
                )
            }
            return
        } catch let recoveryError as RecoveryError {
            throw recoveryError
        } catch {
            let originalError = error
            if case let .retained(artifact) = removeIdentifiedArtifact(
                in: target.parent,
                name: temporaryName,
                identity: stagedIdentity,
                context: .stagedWrite
            ) {
                throw RecoveryError(commitState: .notCommitted, artifacts: [artifact])
            }
            throw originalError
        }
    }

    // MARK: - Target resolution

    /// Reference-counted descriptor ownership for transaction lifetime.
    fileprivate final class Descriptor: @unchecked Sendable {
        /// Open Darwin file descriptor owned by this object.
        let raw: Int32
        /// Canonical absolute path used to verify the descriptor remains reachable.
        let path: String
        /// Device and inode captured when the directory was opened.
        let identity: Identity

        /// Takes ownership of an opened descriptor and its verified path identity.
        init(raw: Int32, path: String, identity: Identity) {
            self.raw = raw
            self.path = path
            self.identity = identity
        }

        deinit { Darwin.close(raw) }
    }

    /// Stable filesystem identity used to detect atomic replacement.
    fileprivate struct Identity: Equatable {
        /// Device containing the filesystem object.
        let device: dev_t
        /// Inode identifying the object on its device.
        let inode: ino_t
    }

    /// One followed symlink and the descriptor from which it was resolved.
    fileprivate struct SymlinkCheckpoint {
        /// Descriptor for the directory containing the link.
        let parent: Descriptor
        /// Link name relative to ``parent``.
        let name: String
        /// Device and inode of the link itself, without following it.
        let identity: Identity
        /// Exact destination bytes decoded as a filesystem path.
        let destination: String
    }

    /// Fully resolved final target with every followed link retained for revalidation.
    fileprivate struct ResolvedTarget {
        /// Descriptor for the directory containing the resolved target.
        let parent: Descriptor
        /// Final target name relative to ``parent``.
        let name: String
        /// Every symbolic link followed while resolving the requested path.
        let symlinks: [SymlinkCheckpoint]
        /// Whether the requested final path component was a symbolic link.
        let followedFinalSymlink: Bool
    }

    /// Existing target state captured from an open file descriptor.
    fileprivate struct TargetSnapshot: Equatable {
        /// Device and inode of the opened regular file.
        let identity: Identity
        /// Exact original bytes used for comparison and backup.
        let data: Data
        /// Original POSIX permission and special-mode bits.
        let mode: mode_t
        /// Open descriptor anchoring the exact file captured by this snapshot.
        let descriptor: Descriptor

        /// Compares the write-relevant identity, bytes, and permission mode.
        static func == (lhs: TargetSnapshot, rhs: TargetSnapshot) -> Bool {
            lhs.identity == rhs.identity && lhs.data == rhs.data && lhs.mode == rhs.mode
        }
    }

    /// Opened directory plus symlinks encountered while walking its path.
    private struct OpenedDirectory {
        /// Descriptor anchored to the final resolved directory.
        let descriptor: Descriptor
        /// Symbolic links followed while opening the directory.
        let symlinks: [SymlinkCheckpoint]
    }

    private func resolveTarget(
        _ url: URL,
        createMissingParentDirectories: Bool = false,
        inheritedSymlinks: [SymlinkCheckpoint] = [],
        followedFinalSymlink: Bool = false,
        depth: Int = 0
    ) throws -> ResolvedTarget {
        guard depth < 40, url.isFileURL, url.path.hasPrefix("/") else {
            throw WriteError.unsafeTarget
        }
        let openedParent = try openDirectory(
            url.deletingLastPathComponent(),
            createMissing: createMissingParentDirectories,
            rejectFinalSymlink: false
        )
        let parent = openedParent.descriptor
        let name = url.lastPathComponent
        guard isSinglePathComponent(name) else {
            throw WriteError.unsafeTarget
        }

        var info = Darwin.stat()
        let result = name.withCString { fstatat(parent.raw, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            let destination = try readLink(parentFD: parent.raw, name: name)
            let checkpoint = SymlinkCheckpoint(
                parent: parent,
                name: name,
                identity: Identity(device: info.st_dev, inode: info.st_ino),
                destination: destination
            )
            let nextURL = try resolvedLinkURL(destination, parentPath: parent.path)
            do {
                return try resolveTarget(
                    nextURL,
                    createMissingParentDirectories: false,
                    inheritedSymlinks: inheritedSymlinks + openedParent.symlinks + [checkpoint],
                    followedFinalSymlink: true,
                    depth: depth + 1
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw WriteError.danglingSymlink
            } catch let error as POSIXError where error.code == .ENOENT {
                throw WriteError.danglingSymlink
            }
        }
        if result != 0, errno != ENOENT { throw currentPOSIXError() }
        if result != 0, followedFinalSymlink { throw WriteError.danglingSymlink }
        if result == 0, (info.st_mode & S_IFMT) != S_IFREG {
            throw WriteError.unsafeTarget
        }

        return ResolvedTarget(
            parent: parent,
            name: name,
            symlinks: inheritedSymlinks + openedParent.symlinks,
            followedFinalSymlink: followedFinalSymlink
        )
    }

    private func snapshotTarget(
        _ target: ResolvedTarget,
        maximumByteCount: Int? = nil
    ) throws -> TargetSnapshot? {
        var pathInfo = Darwin.stat()
        let status = target.name.withCString {
            fstatat(target.parent.raw, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT, !target.followedFinalSymlink else {
                if errno == ENOENT { throw WriteError.danglingSymlink }
                throw currentPOSIXError()
            }
            return nil
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFREG else {
            throw WriteError.unsafeTarget
        }

        let fd = try openFile(
            in: target.parent.raw,
            name: target.name,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        var descriptorInfo = Darwin.stat()
        guard fstat(fd, &descriptorInfo) == 0 else {
            Darwin.close(fd)
            throw currentPOSIXError()
        }
        if let maximumByteCount {
            guard descriptorInfo.st_size >= 0,
                  descriptorInfo.st_size <= off_t(maximumByteCount) else {
                Darwin.close(fd)
                throw WriteError.targetTooLarge
            }
            let mode = descriptorInfo.st_mode & mode_t(0o7777)
            guard descriptorInfo.st_uid == geteuid(),
                  mode & mode_t(0o022) == 0,
                  mode & mode_t(0o6000) == 0 else {
                Darwin.close(fd)
                throw WriteError.unsafeTarget
            }
        }
        let pathIdentity = Identity(device: pathInfo.st_dev, inode: pathInfo.st_ino)
        let descriptorIdentity = Identity(device: descriptorInfo.st_dev, inode: descriptorInfo.st_ino)
        guard pathIdentity == descriptorIdentity else {
            Darwin.close(fd)
            throw WriteError.staleOriginal
        }

        let data: Data
        do {
            data = try readAll(from: fd, maximumByteCount: maximumByteCount)
        } catch {
            Darwin.close(fd)
            throw error
        }

        return TargetSnapshot(
            identity: descriptorIdentity,
            data: data,
            mode: descriptorInfo.st_mode & mode_t(0o7777),
            descriptor: Descriptor(
                raw: fd,
                path: target.parent.path == "/" ? "/\(target.name)" : "\(target.parent.path)/\(target.name)",
                identity: descriptorIdentity
            )
        )
    }

    // MARK: - Revalidation

    private func revalidate(_ target: ResolvedTarget, against snapshot: TargetSnapshot) throws {
        var currentInfo = Darwin.stat()
        let status = target.name.withCString {
            fstatat(target.parent.raw, $0, &currentInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              (currentInfo.st_mode & S_IFMT) == S_IFREG,
              Identity(device: currentInfo.st_dev, inode: currentInfo.st_ino) == snapshot.identity,
              currentInfo.st_mode & mode_t(0o7777) == snapshot.mode
        else { throw WriteError.staleOriginal }

        let fd = try openFile(
            in: target.parent.raw,
            name: target.name,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { Darwin.close(fd) }
        var descriptorInfo = Darwin.stat()
        guard fstat(fd, &descriptorInfo) == 0,
              Identity(device: descriptorInfo.st_dev, inode: descriptorInfo.st_ino) == snapshot.identity
        else { throw WriteError.staleOriginal }
        let currentData: Data
        do {
            currentData = try readAll(from: fd, maximumByteCount: snapshot.data.count)
        } catch WriteError.targetTooLarge {
            throw WriteError.staleOriginal
        }
        guard currentData == snapshot.data else { throw WriteError.staleOriginal }
    }

    /// Allows only immutable compatibility aliases rooted in `/`; arbitrary
    /// user-controlled intermediate symlinks remain forbidden for no-follow reads.
    private func isPermittedSystemAlias(_ checkpoint: SymlinkCheckpoint) -> Bool {
        guard checkpoint.parent.path == "/" else { return false }
        switch (checkpoint.name, checkpoint.destination) {
        case ("var", "private/var"), ("tmp", "private/tmp"), ("etc", "private/etc"):
            return true
        default:
            return false
        }
    }

    private func verifyStillMissing(_ target: ResolvedTarget) throws {
        var info = Darwin.stat()
        let status = target.name.withCString {
            fstatat(target.parent.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status != 0, errno == ENOENT else { throw WriteError.staleOriginal }
    }

    private func revalidateSymlinks(_ checkpoints: [SymlinkCheckpoint]) throws {
        for checkpoint in checkpoints {
            try verifyDirectoryBinding(checkpoint.parent)
            var info = Darwin.stat()
            let status = checkpoint.name.withCString {
                fstatat(checkpoint.parent.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  (info.st_mode & S_IFMT) == S_IFLNK,
                  Identity(device: info.st_dev, inode: info.st_ino) == checkpoint.identity,
                  try readLink(parentFD: checkpoint.parent.raw, name: checkpoint.name) == checkpoint.destination
            else { throw WriteError.staleOriginal }
        }
    }

    private func verifyDirectoryBinding(_ descriptor: Descriptor) throws {
        var current = Darwin.stat()
        let status = descriptor.path.withCString { fstatat(AT_FDCWD, $0, &current, 0) }
        guard status == 0,
              Identity(device: current.st_dev, inode: current.st_ino) == descriptor.identity
        else { throw WriteError.staleOriginal }
    }

    /// Commits a previously missing target and then verifies that every path
    /// checkpoint still reaches the exact staged inode. On failure, only that
    /// identified inode is eligible for cleanup.
    private func commitNewFile(
        target: ResolvedTarget,
        temporaryName: String,
        stagedIdentity: Identity
    ) throws {
        let renameResult = temporaryName.withCString { source in
            target.name.withCString { destination in
                renameatx_np(
                    target.parent.raw,
                    source,
                    target.parent.raw,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult != 0, errno == EEXIST { throw WriteError.staleOriginal }
        guard renameResult == 0 else { throw currentPOSIXError() }

        do {
            try transactionHook?(.afterNewFileCommit)
            try revalidateSymlinks(target.symlinks)
            try verifyDirectoryBinding(target.parent)
            guard try identity(in: target.parent.raw, name: target.name) == stagedIdentity else {
                throw WriteError.staleOriginal
            }
        } catch {
            let cleanup = removeIdentifiedArtifact(
                in: target.parent,
                name: target.name,
                identity: stagedIdentity,
                context: .stagedWrite
            )
            if case let .retained(artifact) = cleanup {
                throw RecoveryError(commitState: .unknown, artifacts: [artifact])
            }
            throw error
        }
    }

    /// Atomically swaps the temporary file with the current target, verifies
    /// the displaced inode, and swaps back if another writer won the race.
    private func commitReplacing(
        target: ResolvedTarget,
        temporaryName: String,
        expected: TargetSnapshot,
        stagedIdentity: Identity
    ) throws {
        let swapResult = temporaryName.withCString { source in
            target.name.withCString { destination in
                renameatx_np(target.parent.raw, source, target.parent.raw, destination, UInt32(RENAME_SWAP))
            }
        }
        guard swapResult == 0 else { throw currentPOSIXError() }

        let displaced = ResolvedTarget(
            parent: target.parent,
            name: temporaryName,
            symlinks: [],
            followedFinalSymlink: false
        )
        var displacedSnapshot: TargetSnapshot?
        do {
            guard try identity(in: target.parent.raw, name: target.name) == stagedIdentity,
                  let capturedDisplaced = try snapshotTarget(displaced)
            else { throw WriteError.staleOriginal }
            displacedSnapshot = capturedDisplaced
            guard capturedDisplaced == expected else { throw WriteError.staleOriginal }
            try revalidateSymlinks(target.symlinks)
            try verifyDirectoryBinding(target.parent)
        } catch {
            let originalError = error
            do {
                try transactionHook?(.beforeRollback)
                guard let displacedSnapshot,
                      try identityIfPresent(in: target.parent.raw, name: target.name) == stagedIdentity,
                      try snapshotTarget(displaced) == displacedSnapshot
                else {
                    throw unknownCommitRecovery(
                        target: target,
                        temporaryName: temporaryName
                    )
                }

                let rollback = temporaryName.withCString { displacedName in
                    target.name.withCString { destination in
                        renameatx_np(
                            target.parent.raw,
                            displacedName,
                            target.parent.raw,
                            destination,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard rollback == 0,
                      try snapshotTarget(target) == displacedSnapshot
                else {
                    throw unknownCommitRecovery(
                        target: target,
                        temporaryName: temporaryName
                    )
                }
                if case let .retained(artifact) = removeIdentifiedArtifact(
                    in: target.parent,
                    name: temporaryName,
                    identity: stagedIdentity,
                    context: .stagedWrite
                ) {
                    throw RecoveryError(commitState: .notCommitted, artifacts: [artifact])
                }
            } catch let recoveryError as RecoveryError {
                throw recoveryError
            } catch {
                throw unknownCommitRecovery(
                    target: target,
                    temporaryName: temporaryName
                )
            }
            throw originalError
        }

    }

    /// Removes the displaced original only after the replacement rename is durable.
    private func cleanupCommittedReplacement(
        target: ResolvedTarget,
        temporaryName: String,
        expected: TargetSnapshot
    ) throws {
        switch removeIdentifiedArtifact(
            in: target.parent,
            name: temporaryName,
            identity: expected.identity,
            context: .displacedOriginal
        ) {
        case .absent:
            do {
                try syncDirectory(target.parent.raw)
            } catch {
                throw CleanupDurabilityError()
            }
        case let .retained(artifact):
            throw RecoveryError(commitState: .committed, artifacts: [artifact])
        }
    }

    /// Restores the pre-write state when the first parent-directory sync fails.
    private func rollbackAfterFailedDirectorySync(
        target: ResolvedTarget,
        temporaryName: String,
        original: TargetSnapshot?,
        stagedIdentity: Identity
    ) throws {
        if let original {
            do {
                try rollbackReplacement(
                    target: target,
                    temporaryName: temporaryName,
                    displacedSnapshot: original,
                    stagedIdentity: stagedIdentity
                )
                try syncDirectory(target.parent.raw)
                return
            } catch let recoveryError as RecoveryError {
                throw recoveryError
            } catch {
                throw unknownCommitRecovery(target: target, temporaryName: temporaryName)
            }
        }

        switch removeIdentifiedArtifact(
            in: target.parent,
            name: target.name,
            identity: stagedIdentity,
            context: .uncertainTarget
        ) {
        case .absent:
            do {
                try syncDirectory(target.parent.raw)
            } catch {
                throw RecoveryError(
                    commitState: .unknown,
                    artifacts: [
                        recoveryArtifact(
                            in: target.parent,
                            name: target.name,
                            context: .uncertainTarget
                        )
                    ]
                )
            }
        case let .retained(artifact):
            throw RecoveryError(commitState: .unknown, artifacts: [artifact])
        }
    }

    /// Swaps a verified displaced original back and removes only the identified staged inode.
    private func rollbackReplacement(
        target: ResolvedTarget,
        temporaryName: String,
        displacedSnapshot: TargetSnapshot,
        stagedIdentity: Identity
    ) throws {
        try transactionHook?(.beforeRollback)
        let displaced = ResolvedTarget(
            parent: target.parent,
            name: temporaryName,
            symlinks: [],
            followedFinalSymlink: false
        )
        guard try identityIfPresent(in: target.parent.raw, name: target.name) == stagedIdentity,
              try snapshotTarget(displaced) == displacedSnapshot else {
            throw unknownCommitRecovery(target: target, temporaryName: temporaryName)
        }
        let rollback = temporaryName.withCString { displacedName in
            target.name.withCString { destination in
                renameatx_np(
                    target.parent.raw,
                    displacedName,
                    target.parent.raw,
                    destination,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard rollback == 0,
              try snapshotTarget(target) == displacedSnapshot else {
            throw unknownCommitRecovery(target: target, temporaryName: temporaryName)
        }
        if case let .retained(artifact) = removeIdentifiedArtifact(
            in: target.parent,
            name: temporaryName,
            identity: stagedIdentity,
            context: .stagedWrite
        ) {
            throw RecoveryError(commitState: .notCommitted, artifacts: [artifact])
        }
    }

    private func unknownCommitRecovery(
        target: ResolvedTarget,
        temporaryName: String
    ) -> RecoveryError {
        RecoveryError(
            commitState: .unknown,
            artifacts: unique([
                recoveryArtifact(in: target.parent, name: target.name, context: .uncertainTarget),
                recoveryArtifact(
                    in: target.parent,
                    name: temporaryName,
                    context: .uncertainDisplaced
                )
            ])
        )
    }

    // MARK: - Backups

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter
    }()

    private func createBackup(
        of snapshot: TargetSnapshot,
        requestedName: String
    ) throws {
        let opened = try openDirectory(
            backupDirectory,
            createMissing: true,
            rejectFinalSymlink: true
        )
        let directory = opened.descriptor
        try verifyDirectoryBinding(directory)

        var info = Darwin.stat()
        guard fstat(directory.raw, &info) == 0,
              info.st_uid == getuid(),
              fchmod(directory.raw, 0o700) == 0
        else { throw WriteError.unsafeBackupDirectory }

        let trimmed = requestedName.drop(while: { $0 == "." })
        let baseName = trimmed.isEmpty ? "file" : String(trimmed)
        _ = try boundedBackupCandidates(
            in: directory,
            baseName: nil,
            maximumEntryCount: maximumBackupDirectoryEntryCount - 1
        )
        let stamp = Self.timestampFormatter.string(from: Date())
        var counter = 0
        var backupName: String
        var backupFD: Int32
        repeat {
            backupName = "\(baseName)-\(stamp)" + (counter == 0 ? "" : "-\(counter)")
            backupFD = backupName.withCString {
                openat(directory.raw, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, snapshot.mode)
            }
            counter += 1
        } while backupFD < 0 && errno == EEXIST
        guard backupFD >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(backupFD) }
        let backupIdentity: Identity
        do {
            backupIdentity = try identity(of: backupFD)
        } catch {
            throw RecoveryError(
                commitState: .notCommitted,
                artifacts: [recoveryArtifact(in: directory, name: backupName, context: .failedBackup)]
            )
        }

        do {
            try writeAll(snapshot.data, to: backupFD)
            try transactionHook?(.beforeBackupSync)
            guard fchmod(backupFD, snapshot.mode) == 0, fsync(backupFD) == 0 else {
                throw currentPOSIXError()
            }
        } catch {
            let originalError = error
            if case let .retained(artifact) = removeIdentifiedArtifact(
                in: directory,
                name: backupName,
                identity: backupIdentity,
                context: .failedBackup
            ) {
                throw RecoveryError(commitState: .notCommitted, artifacts: [artifact])
            }
            throw originalError
        }
        let recoveryArtifacts: [RecoveryArtifact]
        do {
            recoveryArtifacts = try pruneBackups(in: directory, baseName: baseName)
        } catch {
            let pruningError = error
            guard fsync(directory.raw) == 0 else { throw currentPOSIXError() }
            throw pruningError
        }
        guard fsync(directory.raw) == 0 else {
            if !recoveryArtifacts.isEmpty {
                throw RecoveryError(
                    commitState: .notCommitted,
                    artifacts: unique(recoveryArtifacts)
                )
            }
            throw currentPOSIXError()
        }
        if !recoveryArtifacts.isEmpty {
            throw RecoveryError(commitState: .notCommitted, artifacts: unique(recoveryArtifacts))
        }
    }

    private func pruneBackups(
        in directoryDescriptor: Descriptor,
        baseName: String
    ) throws -> [RecoveryArtifact] {
        let candidates = try boundedBackupCandidates(
            in: directoryDescriptor,
            baseName: baseName,
            maximumEntryCount: maximumBackupDirectoryEntryCount
        )
        let staleCandidates = candidates
            .sorted {
                guard let lhs = Self.backupOrderIfValid(for: $0.name, baseName: baseName),
                      let rhs = Self.backupOrderIfValid(for: $1.name, baseName: baseName) else {
                    return $0.name < $1.name
                }
                guard lhs.stamp == rhs.stamp else { return lhs.stamp < rhs.stamp }
                return lhs.counter < rhs.counter
            }
            .dropLast(backupRetention)
        var recoveryArtifacts: [RecoveryArtifact] = []
        for stale in staleCandidates {
            if case let .retained(artifact) = removeIdentifiedArtifact(
                in: directoryDescriptor,
                name: stale.name,
                identity: stale.identity,
                context: .prunedBackup
            ) {
                recoveryArtifacts.append(artifact)
            }
        }
        return recoveryArtifacts
    }

    /// Enumerates at most one explicit directory-entry budget and returns matching regular files.
    private func boundedBackupCandidates(
        in directoryDescriptor: Descriptor,
        baseName: String?,
        maximumEntryCount: Int
    ) throws -> [(name: String, identity: Identity)] {
        let directoryFD = directoryDescriptor.raw
        let enumerationFD = openat(
            directoryFD,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationFD >= 0, let directory = fdopendir(enumerationFD) else {
            if enumerationFD >= 0 { Darwin.close(enumerationFD) }
            throw currentPOSIXError()
        }
        defer { closedir(directory) }

        var candidates: [(name: String, identity: Identity)] = []
        var inspectedEntryCount = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw currentPOSIXError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            inspectedEntryCount += 1
            guard inspectedEntryCount <= maximumEntryCount else {
                throw WriteError.backupDirectoryTooLarge(maximum: maximumBackupDirectoryEntryCount)
            }
            guard let baseName,
                  Self.backupOrderIfValid(for: name, baseName: baseName) != nil else { continue }
            var info = Darwin.stat()
            let metadataResult = name.withCString {
                fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard metadataResult == 0 else { throw currentPOSIXError() }
            if (info.st_mode & S_IFMT) == S_IFREG {
                candidates.append((
                    name: name,
                    identity: Identity(device: info.st_dev, inode: info.st_ino)
                ))
            }
        }
        return candidates
    }

    /// Parses writer-generated timestamps and numeric collision suffixes for retention ordering.
    private static func backupOrderIfValid(
        for name: String,
        baseName: String
    ) -> (stamp: String, counter: Int)? {
        let prefix = "\(baseName)-"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count >= 21 else { return nil }
        let stamp = String(suffix.prefix(21))
        let stampCharacters = Array(stamp)
        let separatorOffsets: Set<Int> = [4, 7, 10, 17]
        guard stampCharacters.indices.allSatisfy({ index in
            separatorOffsets.contains(index)
                ? stampCharacters[index] == "-"
                : stampCharacters[index].isNumber
        }) else { return nil }

        let remainder = suffix.dropFirst(21)
        guard !remainder.isEmpty else { return (stamp, 0) }
        guard remainder.first == "-",
              let counter = Int(remainder.dropFirst()),
              counter > 0,
              String(counter) == remainder.dropFirst() else { return nil }
        return (stamp, counter)
    }

    // MARK: - Descriptor utilities

    private func openDirectory(
        _ url: URL,
        createMissing: Bool,
        rejectFinalSymlink: Bool
    ) throws -> OpenedDirectory {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw WriteError.unsafeTarget
        }
        var components = try pathComponents(of: url)
        var index = 0
        var hops = 0
        var checkpoints: [SymlinkCheckpoint] = []
        var current = try rootDescriptor()

        while index < components.count {
            let component = components[index]
            guard isSinglePathComponent(component) else {
                throw WriteError.unsafeTarget
            }
            var info = Darwin.stat()
            var status = component.withCString {
                fstatat(current.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if status != 0, errno == ENOENT, createMissing {
                let made = component.withCString { mkdirat(current.raw, $0, 0o700) }
                if made != 0, errno != EEXIST { throw currentPOSIXError() }
                status = component.withCString {
                    fstatat(current.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
            }
            guard status == 0 else { throw currentPOSIXError() }

            if (info.st_mode & S_IFMT) == S_IFLNK {
                if rejectFinalSymlink, index == components.count - 1 {
                    throw WriteError.unsafeBackupDirectory
                }
                guard hops < 40 else {
                    throw POSIXError(.ELOOP)
                }
                let destination = try readLink(parentFD: current.raw, name: component)
                checkpoints.append(SymlinkCheckpoint(
                    parent: current,
                    name: component,
                    identity: Identity(device: info.st_dev, inode: info.st_ino),
                    destination: destination
                ))
                let remaining = Array(components.dropFirst(index + 1))
                components = try pathComponents(of: resolvedLinkURL(destination, parentPath: current.path)) + remaining
                current = try rootDescriptor()
                index = 0
                hops += 1
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw rejectFinalSymlink ? WriteError.unsafeBackupDirectory : WriteError.unsafeTarget
            }
            let nextFD = try openFile(
                in: current.raw,
                name: component,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            var nextInfo = Darwin.stat()
            guard fstat(nextFD, &nextInfo) == 0 else {
                Darwin.close(nextFD)
                throw currentPOSIXError()
            }
            let nextPath = current.path == "/"
                ? "/\(component)"
                : "\(current.path)/\(component)"
            current = Descriptor(
                raw: nextFD,
                path: nextPath,
                identity: Identity(device: nextInfo.st_dev, inode: nextInfo.st_ino)
            )
            index += 1
        }
        return OpenedDirectory(descriptor: current, symlinks: checkpoints)
    }

    private func rootDescriptor() throws -> Descriptor {
        let fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw currentPOSIXError() }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else {
            Darwin.close(fd)
            throw currentPOSIXError()
        }
        return Descriptor(
            raw: fd,
            path: "/",
            identity: Identity(device: info.st_dev, inode: info.st_ino)
        )
    }

    private func openFile(in parentFD: Int32, name: String, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fd = name.withCString { openat(parentFD, $0, flags, mode) }
        guard fd >= 0 else { throw currentPOSIXError() }
        return fd
    }

    private func identity(of fd: Int32) throws -> Identity {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw currentPOSIXError() }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private func identity(in parentFD: Int32, name: String) throws -> Identity {
        guard let identity = try identityIfPresent(in: parentFD, name: name) else {
            throw WriteError.staleOriginal
        }
        return identity
    }

    private func identityIfPresent(in parentFD: Int32, name: String) throws -> Identity? {
        var info = Darwin.stat()
        let status = name.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0, errno == ENOENT { return nil }
        guard status == 0 else { throw currentPOSIXError() }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Outcome of moving a cleanup candidate out of its active namespace.
    private enum ArtifactCleanupResult {
        /// No entry remained at the observed name.
        case absent
        /// An entry was deliberately retained for recovery or inspection.
        case retained(RecoveryArtifact)
    }

    /// Atomically moves a validated candidate away from its active name before removal.
    ///
    /// The final identity check protects ordinary concurrent replacement and
    /// every injected race boundary immediately before `unlinkat`. Darwin has
    /// no compare-and-unlink primitive, so a malicious same-UID process can
    /// still replace any pathname in the final syscall window; that process
    /// already has authority to delete the user's files. This does not claim
    /// cryptographic protection against that unsatisfiable threat model.
    private func removeIdentifiedArtifact(
        in parent: Descriptor,
        name: String,
        identity expected: Identity,
        context: RecoveryArtifact.Context
    ) -> ArtifactCleanupResult {
        let originalArtifact = recoveryArtifact(in: parent, name: name, context: context)
        var info = Darwin.stat()
        let status = name.withCString { fstatat(parent.raw, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0, errno == ENOENT { return .absent }
        guard status == 0 else { return .retained(originalArtifact) }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              Identity(device: info.st_dev, inode: info.st_ino) == expected
        else {
            return .retained(originalArtifact)
        }

        do {
            try transactionHook?(.afterCleanupValidation)
        } catch {
            return .retained(originalArtifact)
        }

        let recoveryName = ".codingbuddy-recovery-\(UUID().uuidString)"
        let quarantined = name.withCString { source in
            recoveryName.withCString { destination in
                renameatx_np(
                    parent.raw,
                    source,
                    parent.raw,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if quarantined != 0, errno == ENOENT { return .absent }
        guard quarantined == 0 else { return .retained(originalArtifact) }

        let artifact = recoveryArtifact(in: parent, name: recoveryName, context: context)
        var quarantineInfo = Darwin.stat()
        let quarantineStatus = recoveryName.withCString {
            fstatat(parent.raw, $0, &quarantineInfo, AT_SYMLINK_NOFOLLOW)
        }
        if quarantineStatus != 0, errno == ENOENT { return .absent }
        guard quarantineStatus == 0,
              (quarantineInfo.st_mode & S_IFMT) == S_IFREG,
              Identity(device: quarantineInfo.st_dev, inode: quarantineInfo.st_ino) == expected
        else {
            return .retained(artifact)
        }

        do {
            try transactionHook?(.afterQuarantineValidation)
        } catch {
            return .retained(artifact)
        }

        // Keep this type-and-identity check adjacent to unlinkat: it is the
        // final observable race boundary available on Darwin.
        var finalInfo = Darwin.stat()
        let finalStatus = recoveryName.withCString {
            fstatat(parent.raw, $0, &finalInfo, AT_SYMLINK_NOFOLLOW)
        }
        if finalStatus != 0, errno == ENOENT { return .absent }
        guard finalStatus == 0,
              (finalInfo.st_mode & S_IFMT) == S_IFREG,
              Identity(device: finalInfo.st_dev, inode: finalInfo.st_ino) == expected
        else {
            return .retained(artifact)
        }
        let unlinkStatus = recoveryName.withCString { unlinkat(parent.raw, $0, 0) }
        if unlinkStatus == 0 || errno == ENOENT { return .absent }
        return .retained(artifact)
    }

    private func recoveryArtifact(
        in parent: Descriptor,
        name: String,
        context: RecoveryArtifact.Context
    ) -> RecoveryArtifact {
        let path = parent.path == "/" ? "/\(name)" : "\(parent.path)/\(name)"
        return RecoveryArtifact(lastKnownPath: path, context: context)
    }

    private func unique(_ artifacts: [RecoveryArtifact]) -> [RecoveryArtifact] {
        var result: [RecoveryArtifact] = []
        for artifact in artifacts where !result.contains(artifact) {
            result.append(artifact)
        }
        return result
    }

    private func readAll(from fd: Int32, maximumByteCount: Int? = nil) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw currentPOSIXError() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let requestedCount = maximumByteCount.map {
                min(buffer.count, max(1, $0 - result.count + 1))
            } ?? buffer.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, requestedCount)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            if let maximumByteCount, result.count + count > maximumByteCount {
                throw WriteError.targetTooLarge
            }
            result.append(buffer, count: count)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                offset += written
            }
        }
    }

    private func readLink(parentFD: Int32, name: String) throws -> String {
        var capacity = Int(PATH_MAX)
        while capacity <= 1024 * 1024 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = name.withCString { path in
                buffer.withUnsafeMutableBytes { readlinkat(parentFD, path, $0.baseAddress, $0.count) }
            }
            guard count >= 0 else { throw currentPOSIXError() }
            if count < capacity {
                guard let result = String(bytes: buffer.prefix(count), encoding: .utf8) else {
                    throw WriteError.unsafeTarget
                }
                return result
            }
            capacity *= 2
        }
        throw WriteError.unsafeTarget
    }

    private func resolvedLinkURL(_ destination: String, parentPath: String) throws -> URL {
        let candidate = destination.hasPrefix("/")
            ? destination
            : (parentPath == "/" ? "/\(destination)" : "\(parentPath)/\(destination)")
        let components = try normalizedAbsolutePathComponents(candidate)
        let path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        return URL(fileURLWithPath: path)
    }

    private func pathComponents(of url: URL) throws -> [String] {
        try normalizedAbsolutePathComponents(url.path)
    }

    /// Lexically normalizes an absolute path without resolving filesystem aliases.
    private func normalizedAbsolutePathComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw WriteError.unsafeTarget
        }
        var result: [String] = []
        for rawComponent in path.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            switch component {
            case ".":
                continue
            case "..":
                guard !result.isEmpty else { throw WriteError.unsafeTarget }
                result.removeLast()
            default:
                guard isSinglePathComponent(component) else { throw WriteError.unsafeTarget }
                result.append(component)
            }
        }
        return result
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
