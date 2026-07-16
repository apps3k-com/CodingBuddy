import Darwin
import Foundation

/// Safe, non-diagnostic reason why a repository scan was refused.
nonisolated enum AgentContextScanRefusalReason: Error, Equatable, Sendable {
    /// The repository root could not be bound without following a symbolic link.
    case repositoryPathUnavailableOrUnsafe
}

/// Structured result of one descriptor-bound repository scan.
nonisolated enum AgentContextScanResult: Equatable, Sendable {
    /// Context entries captured from one safely opened repository root.
    case loaded([AgentContextItem])
    /// The selected repository could not be inspected within the safety boundary.
    case refused(AgentContextScanRefusalReason)
}

/// Scans a selected repository for known agent context files without parsing their content.
nonisolated struct AgentContextScanner: Sendable {
    /// Files above this size are flagged because they are costly to feed into agents.
    static let oversizedFileByteThreshold = 64 * 1024
    /// Descriptor-bound external-open snapshots are capped to prevent unbounded synchronous reads.
    static let maximumExternalSnapshotByteCount = 1 * 1024 * 1024
    /// Private snapshots are eligible for stale cleanup after Launch Services has consumed them.
    static let privateSnapshotLifetime: TimeInterval = 10 * 60
    /// Maximum number of private snapshot directories inspected by one cleanup pass.
    static let maximumPrivateSnapshotDirectoryCount = 256
    /// Maximum aggregate file bytes accepted by one cleanup pass.
    static let maximumPrivateSnapshotCleanupBytes = 256 * maximumExternalSnapshotByteCount

    /// App-owned root for descriptor-bound external-open snapshots.
    static var privateSnapshotRootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddy-AgentContext", isDirectory: true)
    }

    /// Root folder selected by the user.
    let repositoryURL: URL

    /// Creates a scanner for a repository root.
    init(repositoryURL: URL) {
        self.repositoryURL = repositoryURL.standardizedFileURL
    }

    /// Returns a structured result that preserves repository-root safety refusals.
    func scan() -> AgentContextScanResult {
        guard let rootDescriptor = openRepositoryRoot() else {
            return .refused(.repositoryPathUnavailableOrUnsafe)
        }
        defer { close(rootDescriptor) }
        return discoveredItems(rootDescriptor: rootDescriptor)
    }

    /// Returns discovered entries in a deterministic order for compatibility callers.
    func items() -> [AgentContextItem] {
        guard case let .loaded(items) = scan() else { return [] }
        return items
    }

    /// Builds one result from a single safely opened repository-root snapshot.
    private func discoveredItems(rootDescriptor: Int32) -> AgentContextScanResult {
        do {
            guard let agents = try contextItem(
                kind: .governance,
                relativePath: "AGENTS.md",
                includeMissing: true,
                rootDescriptor: rootDescriptor
            ), let claude = try contextItem(
                kind: .governance,
                relativePath: "CLAUDE.md",
                includeMissing: true,
                rootDescriptor: rootDescriptor
            ) else {
                return .refused(.repositoryPathUnavailableOrUnsafe)
            }

            let bothGovernanceFilesExist = agents.exists && claude.exists
            var rows = [
                withGovernanceWarnings(
                    agents,
                    missingWarning: .missingAgentsMarkdown,
                    bothExist: bothGovernanceFilesExist
                ),
                withGovernanceWarnings(
                    claude,
                    missingWarning: .missingClaudeMarkdown,
                    bothExist: bothGovernanceFilesExist
                )
            ]

            if let cursorRules = try contextItem(
                kind: .cursorRules,
                relativePath: ".cursor/rules",
                includeMissing: false,
                rootDescriptor: rootDescriptor
            ) {
                rows.append(cursorRules)
            }

            if let mcpConfig = try contextItem(
                kind: .mcpConfig,
                relativePath: ".mcp.json",
                includeMissing: false,
                rootDescriptor: rootDescriptor
            ) {
                rows.append(appending(.projectLocalMCPConfigPresent, to: mcpConfig))
            }

            if let codexConfig = try contextItem(
                kind: .codexConfig,
                relativePath: ".codex/config.toml",
                includeMissing: false,
                rootDescriptor: rootDescriptor
            ) {
                rows.append(appending(.codexProjectConfigPresent, to: codexConfig))
            } else if let codexDirectory = try contextItem(
                kind: .codexConfig,
                relativePath: ".codex",
                includeMissing: false,
                rootDescriptor: rootDescriptor
            ) {
                rows.append(appending(.codexProjectConfigPresent, to: codexDirectory))
            }

            for path in Self.documentationPaths {
                if let item = try contextItem(
                    kind: .documentation,
                    relativePath: path,
                    includeMissing: false,
                    rootDescriptor: rootDescriptor
                ) {
                    rows.append(item)
                }
            }

            return .loaded(rows)
        } catch {
            return .refused(.repositoryPathUnavailableOrUnsafe)
        }
    }

    /// Documentation files that commonly contain developer setup instructions.
    private static let documentationPaths = [
        "README.md",
        "CONTRIBUTING.md",
        "DEVELOPMENT.md",
        "docs/Development-Setup.md",
        "docs/wiki/Development-Setup.md"
    ]

    /// Returns one inspected allowlist entry or a missing placeholder when requested.
    private func contextItem(
        kind: AgentContextKind,
        relativePath: String,
        includeMissing: Bool,
        rootDescriptor: Int32
    ) throws -> AgentContextItem? {
        let url = url(for: relativePath)
        switch inspect(relativePath: relativePath, rootDescriptor: rootDescriptor) {
        case .unsafeRoot:
            throw AgentContextScanRefusalReason.repositoryPathUnavailableOrUnsafe
        case .missing:
            guard includeMissing else { return nil }
            return AgentContextItem(
                relativePath: relativePath,
                url: url,
                kind: kind,
                entryType: .missing,
                byteCount: nil,
                modifiedAt: nil,
                warnings: []
            )
        case let .present(metadata, snapshot):
            let warnings = metadataWarnings(entryType: metadata.entryType, byteCount: metadata.byteCount)

            return AgentContextItem(
                relativePath: relativePath,
                url: snapshotURL(for: url, snapshot: snapshot),
                kind: kind,
                entryType: metadata.entryType,
                byteCount: metadata.byteCount,
                modifiedAt: metadata.modifiedAt,
                warnings: warnings
            )
        }
    }

    /// Runs a synchronous external action against a private descriptor-bound file snapshot.
    ///
    /// The optional hook exists for deterministic race-condition tests. Production callers
    /// leave it empty so final path validation and the external handoff are adjacent.
    func performValidatedAction<Result>(
        for item: AgentContextItem,
        beforeFinalValidation: () -> Void = {},
        _ action: (URL) -> Result
    ) -> Result? {
        guard item.entryType == .file,
              let descriptor = openedActionDescriptor(for: item)
        else { return nil }
        defer { close(descriptor) }

        beforeFinalValidation()
        guard actionPathStillMatches(item, heldDescriptor: descriptor),
              let snapshotURL = privateSnapshotURL(for: item, heldDescriptor: descriptor)
        else { return nil }
        defer { scheduleSnapshotRemoval(snapshotURL.deletingLastPathComponent()) }
        return action(snapshotURL)
    }

    /// Runs an asynchronous external action against a private descriptor-bound file snapshot.
    ///
    /// The external application receives a read-only private path whose bytes came from the
    /// verified descriptor, so a later replacement of the repository path cannot redirect it.
    func performValidatedAction<Result>(
        for item: AgentContextItem,
        beforeFinalValidation: () -> Void = {},
        _ action: (URL) async -> Result
    ) async -> Result? {
        guard item.entryType == .file,
              let descriptor = openedActionDescriptor(for: item)
        else { return nil }
        defer { close(descriptor) }

        beforeFinalValidation()
        guard actionPathStillMatches(item, heldDescriptor: descriptor),
              let snapshotURL = privateSnapshotURL(for: item, heldDescriptor: descriptor)
        else { return nil }
        defer { scheduleSnapshotRemoval(snapshotURL.deletingLastPathComponent()) }
        return await action(snapshotURL)
    }

    /// Copies stable bytes from the held file descriptor into a private read-only temporary file.
    private func privateSnapshotURL(
        for item: AgentContextItem,
        heldDescriptor: Int32
    ) -> URL? {
        guard let data = stableData(from: heldDescriptor) else { return nil }
        Self.cleanupExpiredPrivateSnapshots()

        let rootURL = Self.privateSnapshotRootURL
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let rootDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { return nil }
        defer { close(rootDescriptor) }

        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              Self.isOwnedNonWritableDirectory(rootStatus),
              fchmod(rootDescriptor, 0o700) == 0,
              fstat(rootDescriptor, &rootStatus) == 0,
              Self.isOwnedPrivateDirectory(rootStatus) else { return nil }

        let directoryName = UUID().uuidString
        guard directoryName.withCString({ mkdirat(rootDescriptor, $0, 0o700) }) == 0 else {
            return nil
        }
        var snapshotCreated = false
        defer {
            if !snapshotCreated {
                _ = Self.removePrivateSnapshot(named: directoryName, rootURL: rootURL)
            }
        }

        let directoryDescriptor = directoryName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { return nil }
        defer { close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              Self.isOwnedPrivateDirectory(directoryStatus) else { return nil }

        let snapshotDirectory = rootURL.appendingPathComponent(directoryName, isDirectory: true)
        let snapshotURL = snapshotDirectory
            .appendingPathComponent(item.url.lastPathComponent, isDirectory: false)
        let fileName = snapshotURL.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/") else {
            return nil
        }
        let fileDescriptor = fileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }

        guard writeAll(data, to: fileDescriptor),
              fchmod(fileDescriptor, 0o400) == 0,
              fchmod(directoryDescriptor, 0o500) == 0 else { return nil }
        snapshotCreated = true
        return snapshotURL
    }

    /// Writes all bytes to a newly created descriptor while handling interrupted writes.
    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads one bounded descriptor while rejecting content or metadata changes during the copy.
    private func stableData(from descriptor: Int32) -> Data? {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size >= 0,
              before.st_size <= off_t(Self.maximumExternalSnapshotByteCount)
        else { return nil }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let requestCount = buffer.count
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, requestCount, off_t(offset))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= Self.maximumExternalSnapshotByteCount else { return nil }
            data.append(buffer, count: count)
            offset += count
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              descriptorState(from: before) == descriptorState(from: after),
              data.count == Int(after.st_size)
        else { return nil }
        return data
    }

    /// Schedules cleanup after Launch Services has had time to consume the private snapshot path.
    private func scheduleSnapshotRemoval(_ directoryURL: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.privateSnapshotLifetime
        ) {
            _ = Self.removePrivateSnapshot(
                named: directoryURL.lastPathComponent,
                rootURL: directoryURL.deletingLastPathComponent()
            )
        }
    }

    /// Removes app-owned private snapshots older than their normal handoff lifetime.
    @discardableResult
    static func cleanupExpiredPrivateSnapshots(
        now: Date = Date(),
        rootURL: URL = privateSnapshotRootURL
    ) -> Int {
        cleanupPrivateSnapshots(
            rootURL: rootURL,
            modifiedBefore: now.addingTimeInterval(-privateSnapshotLifetime)
        )
    }

    /// Best-effort termination cleanup for all validated app-owned private snapshots.
    @discardableResult
    static func cleanupAllPrivateSnapshots(rootURL: URL = privateSnapshotRootURL) -> Int {
        cleanupPrivateSnapshots(rootURL: rootURL, modifiedBefore: .distantFuture)
    }

    /// Sweeps a bounded set of UUID-named directories without following links.
    private static func cleanupPrivateSnapshots(rootURL: URL, modifiedBefore cutoff: Date) -> Int {
        let rootDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { return 0 }
        defer { close(rootDescriptor) }

        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              isOwnedNonWritableDirectory(rootStatus),
              fchmod(rootDescriptor, 0o700) == 0,
              fstat(rootDescriptor, &rootStatus) == 0,
              isOwnedPrivateDirectory(rootStatus) else { return 0 }

        let duplicate = dup(rootDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return 0
        }

        var inspectedCount = 0
        var candidates: [SnapshotCleanupCandidate] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            inspectedCount += 1
            guard inspectedCount <= maximumPrivateSnapshotDirectoryCount else { break }
            guard let uuid = UUID(uuidString: name), uuid.uuidString == name.uppercased() else {
                continue
            }

            var info = stat()
            let statResult = name.withCString {
                fstatat(rootDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0, isOwnedPrivateDirectory(info) else { continue }
            let modifiedAt = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            guard modifiedAt <= cutoff else { continue }
            candidates.append(SnapshotCleanupCandidate(name: name, status: info))
        }
        closedir(directory)

        var acceptedBytes = 0
        var removedCount = 0
        for candidate in candidates {
            var directoryBytes = 0
            guard removePrivateSnapshot(
                named: candidate.name,
                rootDescriptor: rootDescriptor,
                expected: candidate.status,
                acceptedBytes: &directoryBytes
            ) else { continue }
            let (nextBytes, overflowed) = acceptedBytes.addingReportingOverflow(directoryBytes)
            guard !overflowed, nextBytes <= maximumPrivateSnapshotCleanupBytes else { break }
            acceptedBytes = nextBytes
            removedCount += 1
        }
        return removedCount
    }

    /// Removes one exact UUID snapshot directory after descriptor-relative validation.
    private static func removePrivateSnapshot(named name: String, rootURL: URL) -> Bool {
        guard let uuid = UUID(uuidString: name), uuid.uuidString == name.uppercased() else {
            return false
        }
        let rootDescriptor = rootURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { return false }
        defer { close(rootDescriptor) }

        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              isOwnedNonWritableDirectory(rootStatus),
              fchmod(rootDescriptor, 0o700) == 0,
              fstat(rootDescriptor, &rootStatus) == 0,
              isOwnedPrivateDirectory(rootStatus) else { return false }
        var info = stat()
        let statResult = name.withCString {
            fstatat(rootDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0, isOwnedPrivateDirectory(info) else { return false }
        var acceptedBytes = 0
        return removePrivateSnapshot(
            named: name,
            rootDescriptor: rootDescriptor,
            expected: info,
            acceptedBytes: &acceptedBytes
        )
    }

    /// Deletes at most one validated regular snapshot file, then its unchanged parent directory.
    private static func removePrivateSnapshot(
        named name: String,
        rootDescriptor: Int32,
        expected: stat,
        acceptedBytes: inout Int
    ) -> Bool {
        let directoryDescriptor = name.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { return false }
        defer { close(directoryDescriptor) }

        var opened = stat()
        guard fstat(directoryDescriptor, &opened) == 0,
              isOwnedPrivateDirectory(opened),
              sameIdentity(opened, expected) else { return false }

        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return false
        }
        var child: SnapshotCleanupEntry?
        var invalid = false
        while let entry = readdir(directory) {
            let childName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard childName != ".", childName != ".." else { continue }
            guard child == nil, !childName.contains("/") else {
                invalid = true
                break
            }
            var childInfo = stat()
            let childStatResult = childName.withCString {
                fstatat(directoryDescriptor, $0, &childInfo, AT_SYMLINK_NOFOLLOW)
            }
            guard childStatResult == 0,
                  isOwnedPrivateFile(childInfo),
                  let byteCount = Int(exactly: childInfo.st_size),
                  byteCount >= 0,
                  byteCount <= maximumExternalSnapshotByteCount else {
                invalid = true
                break
            }
            child = SnapshotCleanupEntry(name: childName, status: childInfo, byteCount: byteCount)
        }
        closedir(directory)
        guard !invalid else { return false }
        acceptedBytes = child?.byteCount ?? 0

        guard fchmod(directoryDescriptor, 0o700) == 0 else { return false }
        if let child {
            var currentChild = stat()
            let childStatResult = child.name.withCString {
                fstatat(directoryDescriptor, $0, &currentChild, AT_SYMLINK_NOFOLLOW)
            }
            guard childStatResult == 0,
                  isOwnedPrivateFile(currentChild),
                  sameIdentity(currentChild, child.status),
                  child.name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
                return false
            }
        }

        var currentDirectory = stat()
        let finalStatResult = name.withCString {
            fstatat(rootDescriptor, $0, &currentDirectory, AT_SYMLINK_NOFOLLOW)
        }
        guard finalStatResult == 0,
              isOwnedPrivateDirectory(currentDirectory),
              sameIdentity(currentDirectory, opened) else { return false }
        return name.withCString({ unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }) == 0
    }

    /// Whether metadata describes an owner-only regular snapshot file.
    private static func isOwnedPrivateFile(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o077)) == 0
            && (info.st_mode & mode_t(0o6000)) == 0
    }

    /// Whether metadata describes an owner-only snapshot directory.
    private static func isOwnedPrivateDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o077)) == 0
    }

    /// Whether an owned directory can be safely tightened without trusting writable peers.
    private static func isOwnedNonWritableDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o022)) == 0
    }

    /// Compares stable identity while permitting cleanup-related mode changes.
    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    /// Validated leaf retained while one snapshot directory is removed.
    private struct SnapshotCleanupEntry {
        /// Single child name resolved relative to the held snapshot directory.
        let name: String
        /// Identity captured before permission changes and deletion.
        let status: stat
        /// Bounded file size charged to the cleanup pass.
        let byteCount: Int
    }

    /// One stale UUID directory retained after bounded enumeration completes.
    private struct SnapshotCleanupCandidate {
        /// UUID directory name resolved relative to the held snapshot root.
        let name: String
        /// Identity and permissions captured without following the directory entry.
        let status: stat
    }

    /// Converts mutable descriptor metadata into the fields that must remain stable while copying.
    private func descriptorState(from status: stat) -> DescriptorSnapshotState {
        DescriptorSnapshotState(
            device: status.st_dev,
            inode: status.st_ino,
            byteCount: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec,
            modifiedNanoseconds: status.st_mtimespec.tv_nsec,
            changedSeconds: status.st_ctimespec.tv_sec,
            changedNanoseconds: status.st_ctimespec.tv_nsec
        )
    }

    /// Resolves one static allowlist path under the selected root.
    private func url(for relativePath: String) -> URL {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(repositoryURL) { url, pathComponent in
                url.appendingPathComponent(String(pathComponent))
            }
    }

    /// Binds a displayed path to the descriptor-relative identities captured during its scan.
    private func snapshotURL(for url: URL, snapshot: PathSnapshot) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = snapshot.token
        return components?.url ?? url
    }

    /// Opens the selected repository root from `/` without following user-controlled symlinks.
    ///
    /// Darwin exposes `/var`, `/tmp`, and `/etc` as immutable compatibility aliases. Those
    /// exact root entries are re-read and translated to `/private/...`; every other component
    /// must be a descriptor-bound directory whose no-follow identity remains stable across open.
    private func openRepositoryRoot() -> Int32? {
        guard repositoryURL.isFileURL,
              repositoryURL.path.hasPrefix("/"),
              !repositoryURL.path.utf8.contains(0)
        else { return nil }

        var components = repositoryURL.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            return nil
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directoryDescriptor = "/".withCString { open($0, directoryFlags) }
        guard directoryDescriptor >= 0 else { return nil }

        var currentPath = "/"
        var index = 0
        while index < components.count {
            let component = components[index]
            var pathStatus = stat()
            let statResult = component.withCString {
                fstatat(directoryDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                close(directoryDescriptor)
                return nil
            }

            if (pathStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                guard currentPath == "/",
                      let expectedDestination = Self.permittedSystemAliasDestination(for: component),
                      readLink(parentDescriptor: directoryDescriptor, name: component) == expectedDestination
                else {
                    close(directoryDescriptor)
                    return nil
                }

                let remaining = components.dropFirst(index + 1)
                components = expectedDestination
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init) + remaining
                index = 0
                continue
            }

            guard (pathStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                close(directoryDescriptor)
                return nil
            }

            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, directoryFlags)
            }
            guard nextDescriptor >= 0 else {
                close(directoryDescriptor)
                return nil
            }

            var openedStatus = stat()
            guard fstat(nextDescriptor, &openedStatus) == 0,
                  (openedStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  Self.sameIdentity(pathStatus, openedStatus)
            else {
                close(nextDescriptor)
                close(directoryDescriptor)
                return nil
            }

            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
            currentPath = currentPath == "/"
                ? "/\(component)"
                : "\(currentPath)/\(component)"
            index += 1
        }

        return directoryDescriptor
    }

    /// Returns the exact target of one immutable macOS root compatibility alias.
    private static func permittedSystemAliasDestination(for name: String) -> String? {
        switch name {
        case "var": "private/var"
        case "tmp": "private/tmp"
        case "etc": "private/etc"
        default: nil
        }
    }

    /// Reads one symbolic-link destination relative to a held directory descriptor.
    private func readLink(parentDescriptor: Int32, name: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = name.withCString { path in
            buffer.withUnsafeMutableBytes {
                readlinkat(parentDescriptor, path, $0.baseAddress, $0.count)
            }
        }
        guard count >= 0,
              count < buffer.count,
              let destination = String(bytes: buffer.prefix(count), encoding: .utf8)
        else { return nil }
        return destination
    }

    /// Inspects an allowlisted path relative to opened in-repository directory descriptors.
    private func inspect(
        relativePath: String,
        verifyLeafDescriptor: Bool = false,
        rootDescriptor: Int32? = nil
    ) -> PathInspection {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." })
        else { return .missing }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        let openedRootDescriptor: Int32?
        if let rootDescriptor {
            let duplicate = dup(rootDescriptor)
            openedRootDescriptor = duplicate >= 0 ? duplicate : nil
        } else {
            openedRootDescriptor = openRepositoryRoot()
        }
        guard var directoryDescriptor = openedRootDescriptor else {
            return .unsafeRoot
        }
        defer { close(directoryDescriptor) }

        var rootStatus = stat()
        guard fstat(directoryDescriptor, &rootStatus) == 0 else { return .missing }
        var identities = [identity(from: rootStatus)]

        for (index, component) in components.enumerated() {
            var status = stat()
            let statResult = component.withCString {
                fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { return .missing }

            let metadata = metadata(from: status)
            if metadata.entryType == .symlink || index == components.count - 1 {
                identities.append(identity(from: status))
                if verifyLeafDescriptor,
                   metadata.entryType == .file || metadata.entryType == .directory {
                    guard descriptorMatches(
                        status,
                        name: component,
                        parentDescriptor: directoryDescriptor,
                        entryType: metadata.entryType
                    ) else { return .missing }
                }
                return .present(metadata, PathSnapshot(identities: identities))
            }

            guard metadata.entryType == .directory else { return .missing }
            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, directoryFlags | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else { return .missing }

            var openedStatus = stat()
            guard fstat(nextDescriptor, &openedStatus) == 0,
                  identity(from: openedStatus) == identity(from: status)
            else {
                close(nextDescriptor)
                return .missing
            }

            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
            identities.append(identity(from: openedStatus))
        }

        return .missing
    }

    /// Opens an actionable leaf without following it and confirms the path still names that inode.
    private func descriptorMatches(
        _ expectedStatus: stat,
        name: String,
        parentDescriptor: Int32,
        entryType: AgentContextEntryType
    ) -> Bool {
        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        if entryType == .directory {
            flags |= O_DIRECTORY
        }

        let descriptor = name.withCString { openat(parentDescriptor, $0, flags) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var openedStatus = stat()
        return fstat(descriptor, &openedStatus) == 0
            && identity(from: openedStatus) == identity(from: expectedStatus)
    }

    /// Opens the actionable leaf descriptor-relative and binds it to the scan-time token.
    private func openedActionDescriptor(for item: AgentContextItem) -> Int32? {
        guard item.actionCapability.allowsExternalActions else { return nil }

        let expectedURL = url(for: item.relativePath)
        guard item.url.isFileURL,
              item.url.path == expectedURL.path,
              let expectedToken = item.url.fragment,
              case let .present(metadata, snapshot) = inspect(relativePath: item.relativePath),
              metadata.entryType == item.entryType,
              snapshot.token == expectedToken
        else { return nil }

        let components = item.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let leafName = components.last else { return nil }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        guard var directoryDescriptor = openRepositoryRoot() else { return nil }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, directoryFlags | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else {
                close(directoryDescriptor)
                return nil
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        var leafFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        if item.entryType == .directory {
            leafFlags |= O_DIRECTORY
        }
        let leafDescriptor = leafName.withCString {
            openat(directoryDescriptor, $0, leafFlags)
        }
        close(directoryDescriptor)
        guard leafDescriptor >= 0 else { return nil }

        var openedStatus = stat()
        guard fstat(leafDescriptor, &openedStatus) == 0,
              identity(from: openedStatus) == snapshot.identities.last
        else {
            close(leafDescriptor)
            return nil
        }
        return leafDescriptor
    }

    /// Confirms the path still names the descriptor-held object immediately before handoff.
    private func actionPathStillMatches(
        _ item: AgentContextItem,
        heldDescriptor: Int32
    ) -> Bool {
        guard let expectedToken = item.url.fragment,
              case let .present(metadata, snapshot) = inspect(
                  relativePath: item.relativePath,
                  verifyLeafDescriptor: true
              ),
              metadata.entryType == item.entryType,
              snapshot.token == expectedToken
        else { return false }

        var heldStatus = stat()
        return fstat(heldDescriptor, &heldStatus) == 0
            && identity(from: heldStatus) == snapshot.identities.last
    }

    /// Converts descriptor-relative `stat` data without resolving a symbolic-link target.
    private func metadata(from status: stat) -> EntryMetadata {
        let fileType = status.st_mode & mode_t(S_IFMT)
        let entryType: AgentContextEntryType
        switch fileType {
        case mode_t(S_IFREG):
            entryType = .file
        case mode_t(S_IFDIR):
            entryType = .directory
        case mode_t(S_IFLNK):
            entryType = .symlink
        default:
            entryType = .unexpected
        }

        let byteCount = entryType == .directory ? nil : Int(exactly: status.st_size)
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return EntryMetadata(entryType: entryType, byteCount: byteCount, modifiedAt: modifiedAt)
    }

    /// Metadata gathered without crossing the selected repository's descriptor boundary.
    private struct EntryMetadata {
        /// File-system shape of the inspected component.
        let entryType: AgentContextEntryType
        /// Size of files, symlinks, and unexpected entries when representable as `Int`.
        let byteCount: Int?
        /// Last modification time reported by the file system.
        let modifiedAt: Date
    }

    /// Stable identity and type for one descriptor-relative path component.
    private struct PathIdentity: Equatable {
        /// Device containing the file-system object.
        let device: dev_t
        /// Inode identifying the object on its device.
        let inode: ino_t
        /// File-system shape captured without following a symlink.
        let entryType: AgentContextEntryType
    }

    /// Scan-time identity chain for the selected root and each relative path component.
    private struct PathSnapshot {
        /// Ordered identities from repository root through the actionable leaf.
        let identities: [PathIdentity]

        /// Opaque value retained by the item and compared after action-time reinspection.
        var token: String {
            "codingbuddy-v1." + identities.map {
                "\($0.entryType.rawValue)-\($0.device)-\($0.inode)"
            }.joined(separator: ".")
        }
    }

    /// Descriptor metadata that must remain unchanged while a private open snapshot is copied.
    private struct DescriptorSnapshotState: Equatable {
        /// Device containing the opened file.
        let device: dev_t
        /// Inode identifying the opened file.
        let inode: ino_t
        /// Exact file size in bytes.
        let byteCount: off_t
        /// Whole seconds of the modification timestamp.
        let modifiedSeconds: Int
        /// Nanosecond remainder of the modification timestamp.
        let modifiedNanoseconds: Int
        /// Whole seconds of the metadata-change timestamp.
        let changedSeconds: Int
        /// Nanosecond remainder of the metadata-change timestamp.
        let changedNanoseconds: Int
    }

    /// Captures identity and type from one no-follow `stat` result.
    private func identity(from status: stat) -> PathIdentity {
        PathIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            entryType: metadata(from: status).entryType
        )
    }

    /// Result of inspecting one allowlisted repository-relative path.
    private enum PathInspection {
        /// The selected root could not be bound without following an untrusted symlink.
        case unsafeRoot
        /// The path is absent, inaccessible, or blocked by a non-directory component.
        case missing
        /// Metadata for the leaf or first symlink encountered inside the repository.
        case present(EntryMetadata, PathSnapshot)
    }

    /// Derives deterministic metadata warnings from entry type and size.
    private func metadataWarnings(
        entryType: AgentContextEntryType,
        byteCount: Int?
    ) -> [AgentContextWarningCode] {
        var warnings: [AgentContextWarningCode] = []

        if entryType == .symlink {
            warnings.append(.symlinkNotTraversed)
        }

        if entryType == .unexpected {
            warnings.append(.unexpectedType)
        }

        guard entryType == .file, let byteCount else { return warnings }

        if byteCount == 0 {
            warnings.append(.emptyFile)
        }

        if byteCount > Self.oversizedFileByteThreshold {
            warnings.append(.oversizedFile)
        }

        return warnings
    }

    /// Adds governance-file warnings that depend on paired AGENTS.md and CLAUDE.md state.
    private func withGovernanceWarnings(
        _ item: AgentContextItem,
        missingWarning: AgentContextWarningCode,
        bothExist: Bool
    ) -> AgentContextItem {
        var warnings = item.warnings

        if !item.exists {
            warnings.append(missingWarning)
        }

        if bothExist {
            warnings.append(.bothGovernanceFilesPresent)
        }

        return AgentContextItem(
            relativePath: item.relativePath,
            url: item.url,
            kind: item.kind,
            entryType: item.entryType,
            byteCount: item.byteCount,
            modifiedAt: item.modifiedAt,
            warnings: warnings
        )
    }

    /// Returns a copy of an item with one additional scanner signal.
    private func appending(
        _ warning: AgentContextWarningCode,
        to item: AgentContextItem
    ) -> AgentContextItem {
        AgentContextItem(
            relativePath: item.relativePath,
            url: item.url,
            kind: item.kind,
            entryType: item.entryType,
            byteCount: item.byteCount,
            modifiedAt: item.modifiedAt,
            warnings: item.warnings + [warning]
        )
    }
}
