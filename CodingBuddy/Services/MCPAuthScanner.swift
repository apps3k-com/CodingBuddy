//
//  MCPAuthScanner.swift
//  CodingBuddy
//

import CryptoKit
import Darwin
import Foundation

/// Validation policy for bounded reads of user-owned security-sensitive input.
nonisolated enum SecureInputReadPolicy: Sendable {
    /// OAuth cache and configuration input used by the MCP credential scanner.
    case credential
    /// Backup input selected for preview or restore.
    case backup
}

/// Deterministic failures for input that cannot be treated as a stable owned regular file.
nonisolated enum SecureInputReadError: Error, Equatable, Sendable {
    /// The path, file type, owner, or mode does not satisfy the selected policy.
    case unsafeFile
    /// The regular file exceeds the caller's explicit byte ceiling.
    case fileTooLarge
    /// A directory contains more entries than the scanner's explicit ceiling.
    case tooManyEntries
    /// The path, identity, metadata, or bytes changed after capture.
    case fileChanged
    /// A POSIX operation failed while opening or reading the input.
    case ioFailure
}

/// Fail-closed outcomes while walking an absolute path without following links.
nonisolated enum SecureAbsolutePathError: Error, Equatable, Sendable {
    /// The URL is not an absolute file URL made only of safe path components.
    case invalidPath
    /// One required directory entry does not exist.
    case missing
    /// A component is a link, has the wrong type, or violates creation policy.
    case unsafeComponent
    /// A directory entry changed between no-follow inspection and descriptor open.
    case changed
    /// A descriptor-relative filesystem operation failed.
    case ioFailure
}

/// Descriptor-relative absolute-path traversal shared by MCP scanning and recovery.
///
/// No caller-supplied component is resolved with `realpath` or an absolute `open`.
/// The only accepted links are Darwin's exact immutable root compatibility aliases.
nonisolated enum SecureAbsolutePath {
    /// Opens an existing absolute directory and transfers descriptor ownership to the caller.
    static func openDirectory(at url: URL) throws -> Int32 {
        try openDirectory(components: components(for: url), createMissing: false, mode: 0o700)
    }

    /// Opens an absolute directory, creating missing app-owned components as owner-only folders.
    static func openOrCreateDirectory(at url: URL, mode: mode_t = 0o700) throws -> Int32 {
        guard mode & mode_t(0o7000) == 0, mode & mode_t(0o077) == 0 else {
            throw SecureAbsolutePathError.invalidPath
        }
        return try openDirectory(components: components(for: url), createMissing: true, mode: mode)
    }

    /// Opens an absolute file path's existing parent and returns its single-component leaf.
    static func openParent(of url: URL) throws -> (descriptor: Int32, leaf: String) {
        var pathComponents = try components(for: url)
        guard let leaf = pathComponents.popLast(), isSafeComponent(leaf) else {
            throw SecureAbsolutePathError.invalidPath
        }
        return (
            try openDirectory(components: pathComponents, createMissing: false, mode: 0o700),
            leaf
        )
    }

    /// Opens or creates an absolute file path's app-owned parent directory.
    static func openOrCreateParent(
        of url: URL,
        mode: mode_t = 0o700
    ) throws -> (descriptor: Int32, leaf: String) {
        guard mode & mode_t(0o7000) == 0, mode & mode_t(0o077) == 0 else {
            throw SecureAbsolutePathError.invalidPath
        }
        var pathComponents = try components(for: url)
        guard let leaf = pathComponents.popLast(), isSafeComponent(leaf) else {
            throw SecureAbsolutePathError.invalidPath
        }
        return (
            try openDirectory(components: pathComponents, createMissing: true, mode: mode),
            leaf
        )
    }

    /// Returns no-follow metadata after securing every intermediate component.
    static func status(at url: URL) throws -> Darwin.stat {
        let parent = try openParent(of: url)
        defer { Darwin.close(parent.descriptor) }
        var info = Darwin.stat()
        let result = parent.leaf.withCString {
            fstatat(parent.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw errno == ENOENT ? SecureAbsolutePathError.missing : .ioFailure
        }
        return info
    }

    /// Validates and splits one absolute file URL without canonicalizing links.
    private static func components(for url: URL) throws -> [String] {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0)
        else {
            throw SecureAbsolutePathError.invalidPath
        }
        let pathComponents = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathComponents.allSatisfy(isSafeComponent) else {
            throw SecureAbsolutePathError.invalidPath
        }
        return pathComponents
    }

    /// Walks from `/`, checking each entry before and after its no-follow open.
    private static func openDirectory(
        components initialComponents: [String],
        createMissing: Bool,
        mode: mode_t
    ) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = "/".withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else { throw SecureAbsolutePathError.ioFailure }

        var components = initialComponents
        var currentPath = "/"
        var index = 0
        do {
            while index < components.count {
                let component = components[index]
                var pathInfo = Darwin.stat()
                var statResult = component.withCString {
                    fstatat(descriptor, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
                }
                var created = false
                var materializedAfterMissing = false

                if statResult != 0 {
                    guard errno == ENOENT else { throw SecureAbsolutePathError.ioFailure }
                    guard createMissing else { throw SecureAbsolutePathError.missing }
                    materializedAfterMissing = true
                    let mkdirResult = component.withCString { mkdirat(descriptor, $0, mode) }
                    if mkdirResult != 0, errno != EEXIST {
                        throw SecureAbsolutePathError.ioFailure
                    }
                    created = mkdirResult == 0
                    statResult = component.withCString {
                        fstatat(descriptor, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statResult == 0 else {
                        throw SecureAbsolutePathError.changed
                    }
                }

                if (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                    guard currentPath == "/",
                          let destination = permittedSystemAliasDestination(for: component),
                          readLink(parentDescriptor: descriptor, name: component) == destination
                    else {
                        throw SecureAbsolutePathError.unsafeComponent
                    }

                    let remaining = components.dropFirst(index + 1)
                    components = destination
                        .split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init) + remaining
                    index = 0
                    continue
                }

                guard (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw SecureAbsolutePathError.unsafeComponent
                }

                let nextDescriptor = component.withCString {
                    openat(descriptor, $0, flags)
                }
                guard nextDescriptor >= 0 else {
                    throw SecureAbsolutePathError.unsafeComponent
                }

                var openedInfo = Darwin.stat()
                guard fstat(nextDescriptor, &openedInfo) == 0,
                      (openedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      sameIdentity(pathInfo, openedInfo)
                else {
                    Darwin.close(nextDescriptor)
                    throw SecureAbsolutePathError.changed
                }

                if materializedAfterMissing {
                    if created, fchmod(nextDescriptor, mode) != 0 {
                        Darwin.close(nextDescriptor)
                        throw SecureAbsolutePathError.ioFailure
                    }
                    guard openedInfo.st_uid == geteuid(),
                          fstat(nextDescriptor, &openedInfo) == 0,
                          (openedInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                          openedInfo.st_uid == geteuid(),
                          openedInfo.st_mode & mode_t(0o7777) == mode,
                          sameIdentity(pathInfo, openedInfo)
                    else {
                        Darwin.close(nextDescriptor)
                        throw SecureAbsolutePathError.unsafeComponent
                    }
                }

                Darwin.close(descriptor)
                descriptor = nextDescriptor
                currentPath = currentPath == "/"
                    ? "/\(component)"
                    : "\(currentPath)/\(component)"
                index += 1
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Returns the expected target for one immutable Darwin root alias.
    private static func permittedSystemAliasDestination(for name: String) -> String? {
        switch name {
        case "var": "private/var"
        case "tmp": "private/tmp"
        case "etc": "private/etc"
        default: nil
        }
    }

    /// Reads one root-relative link target without following it.
    private static func readLink(parentDescriptor: Int32, name: String) -> String? {
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

    /// Compares the stable filesystem identity of two metadata snapshots.
    private static func sameIdentity(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    /// Rejects traversal and embedded-separator components before any syscall.
    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }
}

/// A bounded byte snapshot retained with the descriptor from which it was read.
nonisolated struct SecureInputSnapshot: @unchecked Sendable {
    /// Exact bytes captured from the validated descriptor.
    let data: Data

    fileprivate let state: SecureInputState
    fileprivate let descriptor: SecureInputDescriptor

    /// Modification date captured from the validated descriptor.
    var modifiedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(state.modifiedSeconds)
                + TimeInterval(state.modifiedNanoseconds) / 1_000_000_000
        )
    }

    /// Stable file-system metadata captured from the validated descriptor.
    var metadata: SecureInputMetadata {
        SecureInputMetadata(state: state)
    }
}

/// Stable identity and mutation metadata for a validated sensitive input file.
nonisolated struct SecureInputMetadata: Equatable, Hashable, Sendable {
    fileprivate let state: SecureInputState

    /// Exact byte count reported by the validated file metadata.
    var byteCount: Int { state.byteCount }

    /// Modification date reported by the validated file metadata.
    var modifiedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(state.modifiedSeconds)
                + TimeInterval(state.modifiedNanoseconds) / 1_000_000_000
        )
    }
}

/// Bounded, no-follow reads shared by credential scanning and backup restore input.
nonisolated enum SecureInputReader {
    /// Validates metadata already obtained without following a directory entry.
    static func metadata(
        from info: Darwin.stat,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputMetadata {
        SecureInputMetadata(
            state: try validatedFileState(
                info,
                maximumByteCount: maximumByteCount,
                policy: policy
            )
        )
    }

    /// Opens an absolute path without following any component and captures stable bytes.
    static func capture(
        at url: URL,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputSnapshot {
        guard url.isFileURL, url.path.hasPrefix("/"), maximumByteCount >= 0 else {
            throw SecureInputReadError.unsafeFile
        }

        let parent: (descriptor: Int32, leaf: String)
        do {
            parent = try SecureAbsolutePath.openParent(of: url)
        } catch {
            throw SecureInputReadError.unsafeFile
        }
        defer { Darwin.close(parent.descriptor) }

        var pathInfo = Darwin.stat()
        let statResult = parent.leaf.withCString {
            fstatat(parent.descriptor, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else {
            throw SecureInputReadError.ioFailure
        }
        let expected = try validatedFileState(
            pathInfo,
            maximumByteCount: maximumByteCount,
            policy: policy
        )

        let fileDescriptor = parent.leaf.withCString {
            openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else { throw SecureInputReadError.unsafeFile }

        return try captureOpenedFile(
            descriptor: fileDescriptor,
            expected: expected,
            maximumByteCount: maximumByteCount,
            policy: policy,
            finalPathState: {
                var finalInfo = Darwin.stat()
                let result = parent.leaf.withCString {
                    fstatat(parent.descriptor, $0, &finalInfo, AT_SYMLINK_NOFOLLOW)
                }
                guard result == 0 else {
                    throw SecureInputReadError.fileChanged
                }
                return try validatedFileState(
                    finalInfo,
                    maximumByteCount: maximumByteCount,
                    policy: policy
                )
            }
        )
    }

    /// Captures stable bytes only when the file still matches discovery metadata.
    static func capture(
        at url: URL,
        matching metadata: SecureInputMetadata,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputSnapshot {
        let snapshot = try capture(
            at: url,
            maximumByteCount: maximumByteCount,
            policy: policy
        )
        guard snapshot.metadata == metadata else {
            throw SecureInputReadError.fileChanged
        }
        return snapshot
    }

    /// Reopens a path and requires the same inode, accepted mode, and exact bytes as a prior capture.
    static func revalidatedData(
        from snapshot: SecureInputSnapshot,
        at url: URL,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> Data {
        let current: SecureInputSnapshot
        do {
            current = try capture(
                at: url,
                maximumByteCount: maximumByteCount,
                policy: policy
            )
        } catch {
            throw SecureInputReadError.fileChanged
        }

        guard current.state.identity == snapshot.state.identity,
              current.state.owner == snapshot.state.owner,
              current.state.mode == snapshot.state.mode,
              current.data == snapshot.data
        else {
            throw SecureInputReadError.fileChanged
        }
        return snapshot.data
    }

    fileprivate static func capture(
        name: String,
        in directory: SecureInputDirectory,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputSnapshot {
        guard isSinglePathComponent(name), maximumByteCount >= 0 else {
            throw SecureInputReadError.unsafeFile
        }

        var pathInfo = Darwin.stat()
        let statResult = name.withCString {
            fstatat(directory.descriptor.raw, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw SecureInputReadError.ioFailure }
        let expected = try validatedFileState(
            pathInfo,
            maximumByteCount: maximumByteCount,
            policy: policy
        )

        let fileDescriptor = name.withCString {
            openat(
                directory.descriptor.raw,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else { throw SecureInputReadError.unsafeFile }

        return try captureOpenedFile(
            descriptor: fileDescriptor,
            expected: expected,
            maximumByteCount: maximumByteCount,
            policy: policy,
            finalPathState: {
                var finalInfo = Darwin.stat()
                let result = name.withCString {
                    fstatat(directory.descriptor.raw, $0, &finalInfo, AT_SYMLINK_NOFOLLOW)
                }
                guard result == 0 else { throw SecureInputReadError.fileChanged }
                return try validatedFileState(
                    finalInfo,
                    maximumByteCount: maximumByteCount,
                    policy: policy
                )
            }
        )
    }

    private static func captureOpenedFile(
        descriptor: Int32,
        expected: SecureInputState,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy,
        finalPathState: () throws -> SecureInputState
    ) throws -> SecureInputSnapshot {
        do {
            var openedInfo = Darwin.stat()
            guard fstat(descriptor, &openedInfo) == 0 else {
                throw SecureInputReadError.ioFailure
            }
            let opened = try validatedFileState(
                openedInfo,
                maximumByteCount: maximumByteCount,
                policy: policy
            )
            guard opened == expected else { throw SecureInputReadError.fileChanged }

            let data = try readAll(from: descriptor, maximumByteCount: maximumByteCount)

            var finalDescriptorInfo = Darwin.stat()
            guard fstat(descriptor, &finalDescriptorInfo) == 0 else {
                throw SecureInputReadError.ioFailure
            }
            let finalDescriptorState = try validatedFileState(
                finalDescriptorInfo,
                maximumByteCount: maximumByteCount,
                policy: policy
            )
            guard finalDescriptorState == opened,
                  finalDescriptorState.byteCount == data.count,
                  try finalPathState() == finalDescriptorState
            else {
                throw SecureInputReadError.fileChanged
            }

            return SecureInputSnapshot(
                data: data,
                state: finalDescriptorState,
                descriptor: SecureInputDescriptor(raw: descriptor)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validatedFileState(
        _ info: Darwin.stat,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputState {
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid()
        else {
            throw SecureInputReadError.unsafeFile
        }

        let mode = info.st_mode & mode_t(0o7777)
        let externallyWritable = mode & mode_t(0o022) != 0
        let hasPrivilegeBits = mode & mode_t(0o6000) != 0
        switch policy {
        case .credential, .backup:
            guard !externallyWritable, !hasPrivilegeBits else {
                throw SecureInputReadError.unsafeFile
            }
        }

        guard info.st_size >= 0 else { throw SecureInputReadError.unsafeFile }
        guard info.st_size <= off_t(maximumByteCount) else {
            throw SecureInputReadError.fileTooLarge
        }

        return SecureInputState(
            identity: SecureInputIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            ),
            byteCount: Int(info.st_size),
            owner: UInt32(info.st_uid),
            mode: UInt16(mode),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func readAll(from descriptor: Int32, maximumByteCount: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(min(maximumByteCount, 64 * 1024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0

        while true {
            let requestCount = min(buffer.count, maximumByteCount - result.count + 1)
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, requestCount, off_t(offset))
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureInputReadError.ioFailure
            }
            guard result.count + count <= maximumByteCount else {
                throw SecureInputReadError.fileTooLarge
            }
            result.append(buffer, count: count)
            offset += count
        }
    }

    fileprivate static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }
}

/// Sanitized categories explaining why scanner input was deliberately refused.
nonisolated enum MCPAuthScanRefusal: Hashable, Sendable {
    /// The cache root could not be opened as a stable, user-owned directory.
    case cacheRoot
    /// The cache root exceeded the bounded version-directory count.
    case versionDirectoryEnumeration
    /// One child could not be opened as a stable version directory.
    case versionDirectory
    /// One version exceeded the bounded artifact count.
    case credentialArtifactEnumeration
    /// One credential-shaped artifact failed type, ownership, mode, size, or stability checks.
    case credentialArtifact
    /// One safely identified artifact remained visible but its contents were deliberately not read.
    case credentialArtifactUnreadable
    /// The scan-wide artifact or byte ceiling was reached before all cache input could be inspected.
    case aggregateScanBudget

    /// Whether this refusal means a reset cannot prove that it covers the complete inventory.
    var preventsCredentialReset: Bool {
        self != .credentialArtifactUnreadable
    }
}

/// Credential metadata plus any safety refusals encountered during a bounded scan.
nonisolated struct MCPAuthScanResult: Sendable {
    /// Safely discovered credential groups, including partial results.
    let entries: [MCPAuthEntry]
    /// Sanitized refusal categories that contain no filesystem paths or secret data.
    let refusals: Set<MCPAuthScanRefusal>

    /// Whether the scan deliberately omitted any security-sensitive input.
    var hasSafetyRefusal: Bool { !refusals.isEmpty }
}

/// Reads the `~/.mcp-auth` credential cache that `mcp-remote` maintains for
/// OAuth-connected MCP servers. Pure file inspection -- never logs or exposes
/// token values itself.
nonisolated enum MCPAuthScanner {
    /// Credential caches and related config are expected to stay well below 1 MiB.
    /// The fixed ceiling bounds MainActor work and rejects implausible input.
    static let maximumCredentialFileSize = 1 * 1024 * 1024
    /// Historical mcp-remote installs should never require unbounded version enumeration.
    static let maximumVersionDirectoryCount = 32
    /// Four artifacts per server are typical; 512 still permits a large local inventory.
    static let maximumCredentialArtifactsPerVersion = 512
    /// Scan-wide entry ceiling that prevents many individually valid versions from multiplying work.
    static let maximumCredentialArtifactCount = 768
    /// Scan-wide byte ceiling for credential contents retained only long enough to parse metadata.
    static let maximumCredentialScanByteCount = 4 * maximumCredentialFileSize

    /// `mcp-remote` names files `<md5(serverURL)>_<kind>`; the URL itself is
    /// not stored. We recover it by hashing the server URLs found in the
    /// local Claude configuration files.
    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Collects every http(s) URL mentioned in the Claude config files --
    /// candidates for MCP server URLs. Over-collecting is harmless: only
    /// exact md5 matches are ever used.
    static func configuredServerURLs(homeDirectory: URL) -> [String] {
        let configFiles = [
            homeDirectory.appendingPathComponent(".claude.json"),
            homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
        ]
        var urls: Set<String> = []
        for file in configFiles {
            guard let snapshot = try? SecureInputReader.capture(
                at: file,
                maximumByteCount: maximumCredentialFileSize,
                policy: .credential
            ), let json = try? JSONSerialization.jsonObject(with: snapshot.data) else {
                continue
            }
            collectHTTPStrings(in: json, into: &urls)
        }
        return urls.sorted()
    }

    /// Scans versioned credential-cache directories and correlates hashed entries with known server URLs.
    static func scan(root: URL, knownServerURLs: [String]) -> [MCPAuthEntry] {
        scanResult(root: root, knownServerURLs: knownServerURLs).entries
    }

    /// Scans bounded credential input while preserving sanitized refusal diagnostics.
    static func scanResult(root: URL, knownServerURLs: [String]) -> MCPAuthScanResult {
        let urlByHash = Dictionary(
            knownServerURLs.map { (md5Hex($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let rootDirectory: SecureInputDirectory
        do {
            rootDirectory = try SecureInputDirectory.open(at: root)
        } catch {
            return MCPAuthScanResult(entries: [], refusals: [.cacheRoot])
        }

        let versionNames: [String]
        do {
            versionNames = try rootDirectory.entryNames(
                maximumCount: maximumVersionDirectoryCount
            )
        } catch let error as SecureInputReadError where error == .tooManyEntries {
            return MCPAuthScanResult(entries: [], refusals: [.versionDirectoryEnumeration])
        } catch {
            return MCPAuthScanResult(entries: [], refusals: [.cacheRoot])
        }

        var entries: [MCPAuthEntry] = []
        var refusals: Set<MCPAuthScanRefusal> = []
        var scannedArtifactCount = 0
        var consumedByteCount = 0
        versionLoop: for versionName in versionNames {
            let directory: SecureInputDirectory
            do {
                directory = try rootDirectory.openChildDirectory(named: versionName)
            } catch {
                refusals.insert(.versionDirectory)
                continue
            }

            let fileNames: [String]
            do {
                fileNames = try directory.entryNames(
                    maximumCount: maximumCredentialArtifactsPerVersion
                )
            } catch let error as SecureInputReadError where error == .tooManyEntries {
                refusals.insert(.credentialArtifactEnumeration)
                continue
            } catch {
                refusals.insert(.versionDirectory)
                continue
            }

            var acceptedFiles: [ScannedAuthFile] = []
            var reachedAggregateBudget = false
            for fileName in fileNames {
                guard credentialHash(from: fileName) != nil else { continue }
                guard scannedArtifactCount < maximumCredentialArtifactCount else {
                    refusals.insert(.aggregateScanBudget)
                    reachedAggregateBudget = true
                    break
                }
                scannedArtifactCount += 1

                switch authFile(
                    named: fileName,
                    in: directory,
                    remainingByteBudget: maximumCredentialScanByteCount - consumedByteCount
                ) {
                case .accepted(let file):
                    acceptedFiles.append(file)
                    consumedByteCount += file.consumedByteCount
                case .ignored:
                    break
                case .refused(let file):
                    if let file {
                        acceptedFiles.append(file)
                        refusals.insert(.credentialArtifactUnreadable)
                    } else {
                        refusals.insert(.credentialArtifact)
                    }
                case .budgetExceeded(let file):
                    if let file { acceptedFiles.append(file) }
                    refusals.insert(.aggregateScanBudget)
                    reachedAggregateBudget = true
                }
                if reachedAggregateBudget { break }
            }
            let grouped = Dictionary(
                grouping: acceptedFiles,
                by: \ScannedAuthFile.hash
            )
            for (hash, scannedFiles) in grouped {
                var entry = MCPAuthEntry(
                    hash: hash,
                    versionDirectory: versionName,
                    files: scannedFiles.map(\.file).sorted { $0.fileName < $1.fileName },
                    serverURL: urlByHash[hash],
                    scope: nil,
                    accessTokenExpiry: nil
                )
                if let tokens = scannedFiles.first(where: { $0.file.kind == .tokens }) {
                    entry.scope = tokens.scope
                    entry.accessTokenExpiry = tokens.accessTokenExpiry
                }
                entries.append(entry)
            }
            if reachedAggregateBudget { break versionLoop }
        }

        // Resolved servers first, then by name -- stable, scannable order.
        let sortedEntries = entries.sorted {
            switch ($0.serverURL != nil, $1.serverURL != nil) {
            case (true, false): true
            case (false, true): false
            default: $0.displayName < $1.displayName
            }
        }
        return MCPAuthScanResult(entries: sortedEntries, refusals: refusals)
    }

    // MARK: - Helpers

    private struct ScannedAuthFile {
        /// Hash prefix parsed from the credential artifact name.
        let hash: String
        /// Display and mutation model retained without secret metadata.
        let file: MCPAuthFile
        /// Bytes charged against the scan-wide budget after one bounded capture.
        let consumedByteCount: Int
        /// Non-secret OAuth scope parsed before the descriptor-backed snapshot is released.
        let scope: String?
        /// Best-effort token expiry parsed before the descriptor-backed snapshot is released.
        let accessTokenExpiry: Date?
    }

    /// Result of classifying one child without conflating irrelevant names with refused input.
    private enum AuthFileScanResult {
        /// Safely accepted artifact.
        case accepted(ScannedAuthFile)
        /// Unrelated cache child that does not resemble a credential artifact.
        case ignored
        /// Credential-shaped child rejected by the secure input policy, with
        /// reset-only metadata when its path was still identified safely.
        case refused(ScannedAuthFile?)
        /// A safely identified artifact would exceed the remaining scan-wide byte budget.
        case budgetExceeded(ScannedAuthFile?)
    }

    private static func authFile(
        named name: String,
        in directory: SecureInputDirectory,
        remainingByteBudget: Int
    ) -> AuthFileScanResult {
        guard let hash = credentialHash(from: name) else { return .ignored }
        guard let entryType = try? directory.entryType(named: name) else { return .refused(nil) }

        let url = directory.url.appendingPathComponent(name)
        func resetOnlyFile() -> ScannedAuthFile {
            ScannedAuthFile(
                hash: hash,
                file: MCPAuthFile(
                    url: url,
                    kind: .init(fileName: name),
                    modified: nil,
                    isSafelyReadable: false
                ),
                consumedByteCount: 0,
                scope: nil,
                accessTokenExpiry: nil
            )
        }

        switch entryType {
        case mode_t(S_IFREG):
            let metadata: SecureInputMetadata
            do {
                metadata = try directory.entryMetadata(
                    named: name,
                    maximumByteCount: maximumCredentialFileSize,
                    policy: .credential
                )
            } catch {
                return .refused(resetOnlyFile())
            }
            guard metadata.byteCount <= remainingByteBudget else {
                return .budgetExceeded(resetOnlyFile())
            }

            let snapshot: SecureInputSnapshot
            do {
                snapshot = try SecureInputReader.capture(
                    name: name,
                    in: directory,
                    maximumByteCount: min(maximumCredentialFileSize, remainingByteBudget),
                    policy: .credential
                )
            } catch let error as SecureInputReadError
                where error == .fileTooLarge && remainingByteBudget < maximumCredentialFileSize {
                return .budgetExceeded(resetOnlyFile())
            } catch {
                return .refused(resetOnlyFile())
            }

            let file = MCPAuthFile(
                url: url,
                kind: .init(fileName: name),
                modified: snapshot.modifiedAt,
                isSafelyReadable: true
            )
            let metadataValues = tokenMetadata(from: snapshot.data, file: file)
            return .accepted(ScannedAuthFile(
                hash: hash,
                file: file,
                consumedByteCount: snapshot.data.count,
                scope: metadataValues.scope,
                accessTokenExpiry: metadataValues.accessTokenExpiry
            ))
        case mode_t(S_IFLNK):
            // Keep the artifact visible for guarded reset/edit workflows, but
            // never follow it while deriving scanner metadata.
            return .accepted(resetOnlyFile())
        default:
            return .refused(resetOnlyFile())
        }
    }

    /// Parses only non-secret token metadata while the bounded snapshot remains local.
    private static func tokenMetadata(
        from data: Data,
        file: MCPAuthFile
    ) -> (scope: String?, accessTokenExpiry: Date?) {
        guard file.kind == .tokens,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let expiry = (json["expires_in"] as? Double).flatMap { expiresIn in
            file.modified?.addingTimeInterval(expiresIn)
        }
        return (json["scope"] as? String, expiry)
    }

    /// Returns the credential hash prefix only for a structurally valid cache artifact name.
    private static func credentialHash(from name: String) -> String? {
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        let hash = String(name[..<underscore])
        return hash.count == 32 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    private static func collectHTTPStrings(in value: Any, into urls: inout Set<String>) {
        switch value {
        case let string as String where string.hasPrefix("https://") || string.hasPrefix("http://"):
            urls.insert(string)
        case let array as [Any]:
            for element in array { collectHTTPStrings(in: element, into: &urls) }
        case let dictionary as [String: Any]:
            for element in dictionary.values { collectHTTPStrings(in: element, into: &urls) }
        default:
            break
        }
    }
}

/// Reference-counted ownership for open descriptors retained by secure snapshots.
nonisolated fileprivate final class SecureInputDescriptor: @unchecked Sendable {
    /// Open descriptor closed when its final owner is released.
    let raw: Int32

    /// Takes ownership of an already-open descriptor.
    init(raw: Int32) {
        self.raw = raw
    }

    deinit {
        Darwin.close(raw)
    }
}

/// Stable file identity used to detect atomic path replacement.
nonisolated fileprivate struct SecureInputIdentity: Equatable, Hashable, Sendable {
    /// Device containing the file-system object.
    let device: UInt64
    /// Inode identifying the object on its device.
    let inode: UInt64
}

/// Metadata that must remain stable across one descriptor-bound read.
nonisolated fileprivate struct SecureInputState: Equatable, Hashable, Sendable {
    /// Stable device and inode pair.
    let identity: SecureInputIdentity
    /// File length captured by `fstat`.
    let byteCount: Int
    /// Effective owner accepted for this read.
    let owner: UInt32
    /// Permission and special-mode bits.
    let mode: UInt16
    /// Whole seconds of the modification timestamp.
    let modifiedSeconds: Int64
    /// Nanosecond remainder of the modification timestamp.
    let modifiedNanoseconds: Int64
    /// Whole seconds of the metadata-change timestamp.
    let changedSeconds: Int64
    /// Nanosecond remainder of the metadata-change timestamp.
    let changedNanoseconds: Int64
}

/// An owned, no-follow directory descriptor used to enumerate credential caches safely.
nonisolated fileprivate final class SecureInputDirectory {
    /// Display path corresponding to the opened directory.
    let url: URL
    /// Descriptor anchoring enumeration and child opens.
    let descriptor: SecureInputDescriptor
    private let identity: SecureInputIdentity

    private init(url: URL, descriptor: SecureInputDescriptor, identity: SecureInputIdentity) {
        self.url = url
        self.descriptor = descriptor
        self.identity = identity
    }

    /// Opens and validates an owned directory without following any component.
    static func open(at url: URL) throws -> SecureInputDirectory {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SecureInputReadError.unsafeFile
        }

        let raw: Int32
        do {
            raw = try SecureAbsolutePath.openDirectory(at: url)
        } catch let error as SecureAbsolutePathError where error == .missing {
            throw SecureInputReadError.ioFailure
        } catch {
            throw SecureInputReadError.unsafeFile
        }
        do {
            var openedInfo = Darwin.stat()
            guard fstat(raw, &openedInfo) == 0 else { throw SecureInputReadError.ioFailure }
            let expected = try validatedDirectoryIdentity(openedInfo)
            return SecureInputDirectory(
                url: url,
                descriptor: SecureInputDescriptor(raw: raw),
                identity: expected
            )
        } catch {
            Darwin.close(raw)
            throw error
        }
    }

    /// Opens an owned child directory relative to this anchored descriptor.
    func openChildDirectory(named name: String) throws -> SecureInputDirectory {
        guard SecureInputReader.isSinglePathComponent(name) else {
            throw SecureInputReadError.unsafeFile
        }

        var pathInfo = Darwin.stat()
        let statResult = name.withCString {
            fstatat(descriptor.raw, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw SecureInputReadError.ioFailure }
        let expected = try Self.validatedDirectoryIdentity(pathInfo)

        let raw = name.withCString {
            openat(descriptor.raw, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard raw >= 0 else { throw SecureInputReadError.unsafeFile }
        do {
            var openedInfo = Darwin.stat()
            guard fstat(raw, &openedInfo) == 0,
                  try Self.validatedDirectoryIdentity(openedInfo) == expected
            else {
                throw SecureInputReadError.fileChanged
            }
            return SecureInputDirectory(
                url: url.appendingPathComponent(name, isDirectory: true),
                descriptor: SecureInputDescriptor(raw: raw),
                identity: expected
            )
        } catch {
            Darwin.close(raw)
            throw error
        }
    }

    /// Enumerates a bounded set of safe single-component names through a duplicate descriptor.
    func entryNames(maximumCount: Int) throws -> [String] {
        guard maximumCount >= 0 else { throw SecureInputReadError.unsafeFile }
        var descriptorInfo = Darwin.stat()
        guard fstat(descriptor.raw, &descriptorInfo) == 0,
              try Self.validatedDirectoryIdentity(descriptorInfo) == identity
        else {
            throw SecureInputReadError.fileChanged
        }

        let duplicate = dup(descriptor.raw)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw SecureInputReadError.ioFailure
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if SecureInputReader.isSinglePathComponent(name) {
                names.append(name)
                guard names.count <= maximumCount else {
                    throw SecureInputReadError.tooManyEntries
                }
            }
            errno = 0
        }
        guard errno == 0 else { throw SecureInputReadError.ioFailure }
        return names.sorted()
    }

    /// Returns one entry's type bits without following a symbolic link.
    func entryType(named name: String) throws -> mode_t {
        guard SecureInputReader.isSinglePathComponent(name) else {
            throw SecureInputReadError.unsafeFile
        }
        var info = Darwin.stat()
        let result = name.withCString {
            fstatat(descriptor.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw SecureInputReadError.ioFailure }
        return info.st_mode & mode_t(S_IFMT)
    }

    /// Returns validated no-follow metadata before a caller spends aggregate read budget.
    func entryMetadata(
        named name: String,
        maximumByteCount: Int,
        policy: SecureInputReadPolicy
    ) throws -> SecureInputMetadata {
        guard SecureInputReader.isSinglePathComponent(name) else {
            throw SecureInputReadError.unsafeFile
        }
        var info = Darwin.stat()
        let result = name.withCString {
            fstatat(descriptor.raw, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw SecureInputReadError.ioFailure }
        return try SecureInputReader.metadata(
            from: info,
            maximumByteCount: maximumByteCount,
            policy: policy
        )
    }

    private static func validatedDirectoryIdentity(_ info: Darwin.stat) throws -> SecureInputIdentity {
        let mode = info.st_mode & mode_t(0o7777)
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              mode & mode_t(0o022) == 0
        else {
            throw SecureInputReadError.unsafeFile
        }
        return SecureInputIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }
}
