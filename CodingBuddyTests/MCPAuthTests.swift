//
//  MCPAuthTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct MCPAuthTests {

    private let serverURL = "https://gtm.example.com/mcp"

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    /// Returns the no-follow POSIX type for an exact directory entry.
    private func fileType(of url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_mode & S_IFMT
    }

    private func makeStore(
        root: URL,
        home: URL,
        resetStagingDirectory: URL? = nil,
        recoveryRecordURL: URL? = nil,
        trashItem: ((URL) throws -> URL)? = nil,
        beforeResetStage: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeResetRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        afterResetRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeRecoveryRename: @escaping (Int, URL) throws -> Void = { _, _ in },
        beforeTrashStage: @escaping (URL) throws -> Void = { _ in }
    ) -> MCPAuthStore {
        let resolvedTrashItem = trashItem ?? { url in
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("test-trash-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        return MCPAuthStore(
            rootDirectory: root,
            configHomeDirectory: home,
            backupDirectory: home.appendingPathComponent("Backups", isDirectory: true),
            resetStagingDirectory: resetStagingDirectory
                ?? home.appendingPathComponent("ResetStaging", isDirectory: true),
            recoveryRecordURL: recoveryRecordURL,
            trashItem: resolvedTrashItem,
            beforeResetStage: beforeResetStage,
            beforeResetRename: beforeResetRename,
            afterResetRename: afterResetRename,
            beforeRecoveryRename: beforeRecoveryRename,
            beforeTrashStage: beforeTrashStage
        )
    }

    /// Builds an ~/.mcp-auth lookalike: one resolved entry with tokens, one
    /// incomplete entry, one expired entry.
    private func makeFixtureRoot(in dir: URL) throws -> (root: URL, hash: String) {
        let root = dir.appendingPathComponent(".mcp-auth", isDirectory: true)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)

        let hash = MCPAuthScanner.md5Hex(serverURL)
        let tokens = #"{"access_token":"a-token","refresh_token":"r-token","token_type":"bearer","expires_in":3600,"scope":"read write"}"#
        let clientInfo = #"{"client_id":"abc","client_name":"MCP CLI Proxy"}"#

        try tokens.write(to: version.appendingPathComponent("\(hash)_tokens.json"), atomically: true, encoding: .utf8)
        try clientInfo.write(to: version.appendingPathComponent("\(hash)_client_info.json"), atomically: true, encoding: .utf8)
        try "verifier".write(to: version.appendingPathComponent("\(hash)_code_verifier.txt"), atomically: true, encoding: .utf8)

        let incompleteHash = String(repeating: "ab", count: 16)
        try clientInfo.write(to: version.appendingPathComponent("\(incompleteHash)_client_info.json"), atomically: true, encoding: .utf8)

        let expiredHash = String(repeating: "cd", count: 16)
        let expiredTokens = #"{"access_token":"x","expires_in":-60,"scope":"openid"}"#
        try expiredTokens.write(to: version.appendingPathComponent("\(expiredHash)_tokens.json"), atomically: true, encoding: .utf8)

        return (root, hash)
    }

    // MARK: - Scanner

    @Test func md5MatchesMCPRemoteHashing() {
        // Real-world vector: mcp-remote's file prefix for this server URL.
        #expect(MCPAuthScanner.md5Hex("https://gtm-mcp.stape.ai/mcp") == "d097dd57096938e420847d7e05ce995f")
    }

    @Test func scanGroupsResolvesAndClassifiesEntries() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)

        let entries = MCPAuthScanner.scan(root: root, knownServerURLs: [serverURL])
        #expect(entries.count == 3)

        let resolved = try #require(entries.first { $0.hash == hash })
        #expect(resolved.serverURL == serverURL)
        #expect(resolved.displayName == serverURL)
        #expect(resolved.scope == "read write")
        #expect(resolved.files.count == 3)
        #expect(resolved.status == .active(expiry: resolved.accessTokenExpiry))
        #expect(try #require(resolved.accessTokenExpiry) > Date())

        let incomplete = try #require(entries.first { $0.hash.hasPrefix("abab") })
        #expect(incomplete.serverURL == nil)
        #expect(incomplete.status == .incomplete)

        let expired = try #require(entries.first { $0.hash.hasPrefix("cdcd") })
        #expect(expired.status == .expired(try #require(expired.accessTokenExpiry)))
    }

    @Test func configuredServerURLsAreFoundInClaudeConfig() throws {
        let home = try makeTempDir()
        let config = #"{"mcpServers":{"gtm":{"command":"npx","args":["mcp-remote","\#(serverURL)"]}}}"#
        try config.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let urls = MCPAuthScanner.configuredServerURLs(homeDirectory: home)
        #expect(urls.contains(serverURL))
    }

    /// VoiceOver must not claim that no cache input was read when safe rows remain visible.
    @Test func scanSafetyAnnouncementDistinguishesPartialAndFullyRefusedScans() {
        let partial = MCPAuthScanSafetyPresentation.announcement(hasVisibleEntries: true)
        let refused = MCPAuthScanSafetyPresentation.announcement(hasVisibleEntries: false)

        #expect(partial == String(localized: "Some credential or recovery files were not read because their type, ownership, permissions, size, or directory count was unsafe."))
        #expect(refused == String(localized: "CodingBuddy found an unsafe or unexpectedly large credential cache and deliberately did not read it."))
        #expect(partial != refused)
    }

    // MARK: - Store

    @Test func resetMovesAllEntryFilesAway() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        var trashedDirectory: URL?

        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                let destination = url.deletingLastPathComponent()
                    .appendingPathComponent("trashed-transaction", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashedDirectory = destination
                return destination
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(store.reset(entry))

        #expect(store.lastError == nil)
        #expect(trashCalls == 1)
        #expect(
            trashedDirectory?.deletingLastPathComponent()
                == dir.appendingPathComponent("ResetStaging", isDirectory: true)
        )
        let trashedItems = try FileManager.default.contentsOfDirectory(
            at: try #require(trashedDirectory),
            includingPropertiesForKeys: nil
        )
        #expect(trashedItems.count == entry.files.count)
        #expect(try trashedItems.allSatisfy { try fileType(of: $0) == mode_t(S_IFREG) })
        #expect(!store.entries.contains { $0.hash == hash })
        #expect(store.entries.count == 2)
    }

    @Test func resetAllEmptiesTheRoot() throws {
        let dir = try makeTempDir()
        let (root, _) = try makeFixtureRoot(in: dir)
        var trashCalls = 0

        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                let destination = url.deletingLastPathComponent()
                    .appendingPathComponent("trashed-transaction", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
        #expect(!store.entries.isEmpty)

        store.resetAll()

        #expect(store.lastError == nil)
        #expect(trashCalls == 1)
        #expect(store.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// A newly added artifact for the confirmed server invalidates the reset inventory.
    @Test func resetRejectsArtifactAddedAfterConfirmationSnapshot() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let added = root
            .appendingPathComponent(entry.versionDirectory, isDirectory: true)
            .appendingPathComponent("\(hash)_additional.json")
        try #"{"new":"credential"}"#.write(
            to: added,
            atomically: true,
            encoding: .utf8
        )

        #expect(!store.reset(entry))

        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(FileManager.default.fileExists(atPath: added.path))
        for file in entry.files {
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    /// Removing one confirmed artifact invalidates the reset before transaction creation.
    @Test func resetRejectsArtifactRemovedAfterConfirmationSnapshot() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let removed = try #require(entry.files.first { $0.kind == .codeVerifier })
        try FileManager.default.removeItem(at: removed.url)

        #expect(!store.reset(entry))

        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        for file in entry.files where file.id != removed.id {
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    /// Replacing a confirmed path with equal bytes still changes its filesystem identity.
    @Test func resetRejectsEqualContentArtifactReplacementAfterConfirmationSnapshot() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let replaced = try #require(entry.files.first { $0.kind == .tokens })
        let content = try Data(contentsOf: replaced.url)
        try FileManager.default.removeItem(at: replaced.url)
        try content.write(to: replaced.url, options: .withoutOverwriting)

        #expect(!store.reset(entry))

        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(try Data(contentsOf: replaced.url) == content)
    }

    /// A represented artifact changed into a reset-only form and invalidates its bound identity.
    @Test func resetRejectsFreshScanRefusalBeforeStaging() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let oversized = Data(
            repeating: 0x20,
            count: MCPAuthScanner.maximumCredentialFileSize + 1
        )
        try oversized.write(to: tokens.url)

        #expect(!store.reset(entry))

        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(try Data(contentsOf: tokens.url) == oversized)
        for file in entry.files where file.id != tokens.id {
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    /// Reset-all binds every artifact moved with an already confirmed version directory.
    @Test func resetAllRejectsNestedArtifactAdditionAfterConfirmationSnapshot() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let addedArtifact = root
            .appendingPathComponent(entry.versionDirectory, isDirectory: true)
            .appendingPathComponent("untracked-state")
        try "new state".write(to: addedArtifact, atomically: true, encoding: .utf8)

        store.resetAll()

        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(FileManager.default.fileExists(atPath: addedArtifact.path))
        #expect(!store.entries.isEmpty)
    }

    /// A child added after the final preflight cannot hitch a ride inside a reset-all directory.
    @Test func resetAllRejectsNestedArtifactAddedAtRenameBoundary() throws {
        let dir = try makeTempDir()
        let (root, _) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let racedArtifact = version.appendingPathComponent("late-unconfirmed-state")
        let originalNames = Set(try FileManager.default.contentsOfDirectory(atPath: version.path))
        var injected = false
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            beforeResetRename: { index, _ in
                guard index == 0, !injected else { return }
                injected = true
                try "unconfirmed".write(
                    to: racedArtifact,
                    atomically: true,
                    encoding: .utf8
                )
            }
        )

        store.resetAll()

        #expect(injected)
        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(try String(contentsOf: racedArtifact, encoding: .utf8) == "unconfirmed")
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: version.path))
                == originalNames.union([racedArtifact.lastPathComponent])
        )
    }

    /// A process retaining a directory descriptor cannot add an unconfirmed child after rename.
    @Test func resetAllRollsBackNestedArtifactAddedAfterRename() throws {
        let dir = try makeTempDir()
        let (root, _) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let versionDescriptor = Darwin.open(version.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(versionDescriptor >= 0)
        guard versionDescriptor >= 0 else { return }
        defer { Darwin.close(versionDescriptor) }

        let racedName = "post-rename-unconfirmed-state"
        var injected = false
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            afterResetRename: { index, _ in
                guard index == 0, !injected else { return }
                let descriptor = Darwin.openat(
                    versionDescriptor,
                    racedName,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    0o600
                )
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { Darwin.close(descriptor) }
                let bytes = Array("unconfirmed".utf8)
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress, buffer.count)
                }
                guard written == bytes.count else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                injected = true
            }
        )

        store.resetAll()

        let racedArtifact = version.appendingPathComponent(racedName)
        #expect(injected)
        #expect(trashCalls == 0)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(try String(contentsOf: racedArtifact, encoding: .utf8) == "unconfirmed")
        #expect(!store.entries.isEmpty)
    }

    /// A replaced non-directory leaf is rejected before the transaction reaches Trash.
    @Test func resetRetainsRecoveryForLeafReplacedBeforeTrash() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var replaced = false
        var replacedStagedName: String?
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            beforeTrashStage: { stagedURL in
                let transaction = root.appendingPathComponent(
                    stagedURL.lastPathComponent,
                    isDirectory: true
                )
                let names = try FileManager.default.contentsOfDirectory(atPath: transaction.path)
                let stagedLeaf = try #require(names.sorted().first)
                let leafURL = transaction.appendingPathComponent(stagedLeaf)
                try FileManager.default.removeItem(at: leafURL)
                try "replacement".write(to: leafURL, atomically: false, encoding: .utf8)
                replacedStagedName = stagedLeaf
                replaced = true
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(!store.reset(entry))

        #expect(replaced)
        #expect(trashCalls == 0)
        let recoveryDirectory = try #require(store.lastRecoveryDirectory)
        let stagedName = try #require(replacedStagedName)
        #expect(stagedName.count > 5)
        let originalName = String(stagedName.dropFirst(5))
        let liveArtifact = root.appendingPathComponent(originalName)
        let retainedReplacement = recoveryDirectory.appendingPathComponent(stagedName)

        #expect(!FileManager.default.fileExists(atPath: liveArtifact.path))
        #expect(FileManager.default.fileExists(atPath: retainedReplacement.path))
        #expect(try String(contentsOf: retainedReplacement, encoding: .utf8) == "replacement")
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path).isEmpty
        )
        guard case .recoveryRequired = store.lastFailureKind else {
            Issue.record("Expected retained recovery after a staged leaf replacement")
            return
        }
    }

    /// Verifies reset-all cannot traverse an intermediate link into an external cache root.
    @Test func resetRejectsIntermediateRootSymlinkWithoutMovingExternalItems() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let externalParent = directory.appendingPathComponent("external", isDirectory: true)
        let (externalRoot, _) = try makeFixtureRoot(in: externalParent)
        let originalChildren = Set(
            try FileManager.default.contentsOfDirectory(atPath: externalRoot.path)
        )
        let marker = externalParent.appendingPathComponent("marker")
        try "external-safe".write(to: marker, atomically: true, encoding: .utf8)

        let configuredParent = directory.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredParent, withIntermediateDirectories: false)
        let redirect = configuredParent.appendingPathComponent("redirect", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: externalParent)
        let configuredRoot = redirect.appendingPathComponent(".mcp-auth", isDirectory: true)
        var trashCalls = 0
        let store = makeStore(
            root: configuredRoot,
            home: directory,
            trashItem: { url in
                trashCalls += 1
                return url
            }
        )

        store.resetAll()

        #expect(trashCalls == 0)
        #expect(store.lastError != nil)
        #expect(store.entries.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: externalRoot.path)) == originalChildren)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "external-safe")
    }

    /// Verifies a staging ancestor swapped to a symlink cannot redirect directory creation.
    @Test func resetRejectsIntermediateStagingSymlinkWithoutCreatingExternalState() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (root, hash) = try makeFixtureRoot(in: directory)
        let stagingParent = directory.appendingPathComponent("AppSupport", isDirectory: true)
            .appendingPathComponent("MutableParent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let displacedParent = directory.appendingPathComponent("DisplacedParent", isDirectory: true)
        let external = directory.appendingPathComponent("external-staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = external.appendingPathComponent("marker")
        try "external-safe".write(to: marker, atomically: true, encoding: .utf8)
        let staging = stagingParent.appendingPathComponent("ResetStaging", isDirectory: true)
        let safeRecoveryRecord = directory
            .appendingPathComponent("SafeRecovery", isDirectory: true)
            .appendingPathComponent("MCPAuthRecovery.json")
        var swapped = false
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: directory,
            resetStagingDirectory: staging,
            recoveryRecordURL: safeRecoveryRecord,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            beforeResetRename: { index, _ in
                guard index == 0, !swapped else { return }
                swapped = true
                try FileManager.default.moveItem(at: stagingParent, to: displacedParent)
                try FileManager.default.createSymbolicLink(
                    at: stagingParent,
                    withDestinationURL: external
                )
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let original = try Dictionary(uniqueKeysWithValues: entry.files.map {
            ($0.url.path, try String(contentsOf: $0.url, encoding: .utf8))
        })

        #expect(!store.reset(entry))

        #expect(swapped)
        #expect(trashCalls == 0)
        #expect(store.lastError != nil)
        #expect(!FileManager.default.fileExists(
            atPath: external.appendingPathComponent("ResetStaging", isDirectory: true).path
        ))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "external-safe")
        for file in entry.files {
            #expect(try String(contentsOf: file.url, encoding: .utf8) == original[file.url.path])
        }
    }

    @Test func saveRejectsInvalidJSON() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let original = try store.contents(of: tokens)

        store.save("{not json", to: tokens, expectedOriginalContent: original)

        #expect(store.lastError != nil)
        #expect(store.lastFailureKind == .other)
        #expect(try store.contents(of: tokens) == original)
    }

    @Test func saveRejectsContentChangedAfterEditorLoad() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let original = try store.contents(of: tokens)
        let external = #"{"access_token":"external"}"#
        try external.write(to: tokens.url, atomically: true, encoding: .utf8)

        let saved = store.save(
            #"{"access_token":"editor"}"#,
            to: tokens,
            expectedOriginalContent: original
        )

        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(store.lastFailureKind == .fileChangedExternally)
        #expect(try String(contentsOf: tokens.url, encoding: .utf8) == external)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
    }

    @Test func saveBacksUpAndPreservesCredentialPermissions() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let original = try store.contents(of: tokens)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokens.url.path)

        let saved = store.save(
            #"{"access_token":"changed"}"#,
            to: tokens,
            expectedOriginalContent: original
        )

        let backupDirectory = dir.appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(saved)
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == original)
        #expect(try mode(of: tokens.url) == 0o600)
        #expect(try mode(of: backupDirectory) == 0o700)
    }

    @Test func symlinkArtifactIsResetOnlyAndCannotBeSaved() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let tokenURL = version.appendingPathComponent("\(hash)_tokens.json")
        let target = dir.appendingPathComponent("real-tokens.json")
        let original = try String(contentsOf: tokenURL, encoding: .utf8)
        try FileManager.default.moveItem(at: tokenURL, to: target)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })

        let saved = store.save(
            #"{"access_token":"changed"}"#,
            to: tokens,
            expectedOriginalContent: original
        )

        let linkType = try FileManager.default.attributesOfItem(atPath: tokenURL.path)[.type] as? FileAttributeType
        #expect(!saved)
        #expect(linkType == .typeSymbolicLink)
        #expect(entry.hasTokens)
        #expect(!entry.hasSafelyReadableTokens)
        #expect(entry.status == .resetOnly)
        #expect(!tokens.isSafelyReadable)
        #expect(try String(contentsOf: target, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
    }

    /// A reset moves the symlink entry itself and never follows or mutates its target.
    @Test func resetMovesSymlinkArtifactWithoutFollowingTarget() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let tokenURL = version.appendingPathComponent("\(hash)_tokens.json")
        let target = dir.appendingPathComponent("external-tokens.json")
        let original = try String(contentsOf: tokenURL, encoding: .utf8)
        try FileManager.default.moveItem(at: tokenURL, to: target)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)
        var trashedTransaction: URL?
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                let destination = url.deletingLastPathComponent()
                    .appendingPathComponent("trashed-symlink-transaction", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashedTransaction = destination
                return destination
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(entry.status == .resetOnly)
        #expect(store.reset(entry))

        #expect(try String(contentsOf: target, encoding: .utf8) == original)
        #expect(access(tokenURL.path, F_OK) != 0)
        let trashedItems = try FileManager.default.contentsOfDirectory(
            at: try #require(trashedTransaction),
            includingPropertiesForKeys: nil
        )
        let stagedLink = try #require(trashedItems.first { $0.lastPathComponent.hasSuffix("_tokens.json") })
        #expect(try fileType(of: stagedLink) == mode_t(S_IFLNK))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: stagedLink.path) == target.path)
    }

    /// A reset renames a FIFO as a directory entry and cannot block waiting for a peer.
    @Test func resetMovesFIFOArtifactWithoutOpeningIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let tokenURL = version.appendingPathComponent("\(hash)_tokens.json")
        try FileManager.default.removeItem(at: tokenURL)
        guard mkfifo(tokenURL.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var trashedTransaction: URL?
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                let destination = url.deletingLastPathComponent()
                    .appendingPathComponent("trashed-fifo-transaction", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashedTransaction = destination
                return destination
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(entry.status == .resetOnly)
        #expect(!store.hasIncompleteCredentialInventory)
        #expect(store.reset(entry))

        #expect(access(tokenURL.path, F_OK) != 0)
        let trashedItems = try FileManager.default.contentsOfDirectory(
            at: try #require(trashedTransaction),
            includingPropertiesForKeys: nil
        )
        let stagedFIFO = try #require(trashedItems.first { $0.lastPathComponent.hasSuffix("_tokens.json") })
        #expect(try fileType(of: stagedFIFO) == mode_t(S_IFIFO))
    }

    /// A leaf replacement at the action boundary is preserved and aborts the reset.
    @Test func resetRejectsResetOnlyLeafReplacementRace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let tokenURL = version.appendingPathComponent("\(hash)_tokens.json")
        let target = dir.appendingPathComponent("external-tokens.json")
        try FileManager.default.moveItem(at: tokenURL, to: target)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)
        var replaced = false
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            beforeResetRename: { _, url in
                guard url == tokenURL, !replaced else { return }
                replaced = true
                try FileManager.default.removeItem(at: tokenURL)
                guard mkfifo(tokenURL.path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(!store.reset(entry))

        #expect(replaced)
        #expect(trashCalls == 0)
        #expect(store.lastError != nil)
        #expect(store.lastRecoveryDirectory == nil)
        #expect(try fileType(of: tokenURL) == mode_t(S_IFIFO))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// Transaction rollback restores special directory entries without opening them.
    @Test func resetRollsBackSymlinkAndFIFOAfterTrashFailure() throws {
        struct TrashFailure: Error {}
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let tokenURL = version.appendingPathComponent("\(hash)_tokens.json")
        let clientURL = version.appendingPathComponent("\(hash)_client_info.json")
        let target = dir.appendingPathComponent("external-tokens.json")
        try FileManager.default.moveItem(at: tokenURL, to: target)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)
        try FileManager.default.removeItem(at: clientURL)
        guard mkfifo(clientURL.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in throw TrashFailure() }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        #expect(!store.reset(entry))

        #expect(store.lastRecoveryDirectory == nil)
        #expect(try fileType(of: tokenURL) == mode_t(S_IFLNK))
        #expect(try fileType(of: clientURL) == mode_t(S_IFIFO))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func oversizedTokenArtifactRemainsVisibleAndResetOnly() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let tokenURL = root
            .appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
            .appendingPathComponent("\(hash)_tokens.json")
        try Data(
            repeating: 0x20,
            count: MCPAuthScanner.maximumCredentialFileSize + 1
        ).write(to: tokenURL)

        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })

        #expect(entry.status == .resetOnly)
        #expect(!tokens.isSafelyReadable)
        #expect(store.scanRefusals.contains(.credentialArtifactUnreadable))
        #expect(!store.hasIncompleteCredentialInventory)
    }

    @Test func onlyUnrepresentedScanRefusalsBlockCredentialResetCoverage() {
        #expect(!MCPAuthScanRefusal.credentialArtifactUnreadable.preventsCredentialReset)
        #expect(MCPAuthScanRefusal.credentialArtifact.preventsCredentialReset)
        #expect(MCPAuthScanRefusal.credentialArtifactEnumeration.preventsCredentialReset)
    }

    @Test func loadedCredentialSnapshotRejectsEqualContentSymlinkReplacement() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        let loaded = try store.loadContents(of: tokens)
        let displaced = dir.appendingPathComponent("displaced.json")
        let external = dir.appendingPathComponent("external.json")
        try FileManager.default.moveItem(at: tokens.url, to: displaced)
        try loaded.text.write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tokens.url, withDestinationURL: external)

        let saved = store.save(
            #"{"access_token":"changed"}"#,
            to: tokens,
            loaded: loaded
        )

        #expect(!saved)
        #expect(try String(contentsOf: external, encoding: .utf8) == loaded.text)
        #expect(try String(contentsOf: displaced, encoding: .utf8) == loaded.text)
    }

    @Test func actionTimeCredentialReadRejectsOversizedReplacement() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        try Data(
            repeating: 0x41,
            count: MCPAuthScanner.maximumCredentialFileSize + 1
        ).write(to: tokens.url)

        #expect(throws: SafeFileWriter.WriteError.targetTooLarge) {
            try store.loadContents(of: tokens)
        }
    }

    @Test func actionTimeCredentialReadRejectsFIFOReplacementWithoutOpeningIt() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(root: root, home: dir)
        let entry = try #require(store.entries.first { $0.hash == hash })
        let tokens = try #require(entry.files.first { $0.kind == .tokens })
        try FileManager.default.removeItem(at: tokens.url)
        guard mkfifo(tokens.url.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        #expect(throws: SafeFileWriter.WriteError.unsafeTarget) {
            try store.loadContents(of: tokens)
        }
    }

    @Test func resetRollsBackFilesAfterTransactionTrashFailure() throws {
        struct InjectedFailure: Error {}
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in
                trashCalls += 1
                throw InjectedFailure()
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let originalContents = try Dictionary(uniqueKeysWithValues: entry.files.map {
            ($0.url.path, try String(contentsOf: $0.url, encoding: .utf8))
        })

        #expect(!store.reset(entry))

        #expect(store.lastError != nil)
        #expect(trashCalls == 1)
        #expect(store.lastRecoveryDirectory == nil)
        for file in entry.files {
            #expect(try String(contentsOf: file.url, encoding: .utf8) == originalContents[file.url.path])
        }
        #expect(store.entries.contains { $0.hash == hash })
    }

    @Test func resetRollsBackOnlyItemsMovedBeforeStageFailure() throws {
        struct StageFailure: Error {}
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let store = makeStore(
            root: root,
            home: dir,
            beforeResetStage: { index, _ in
                if index == 1 { throw StageFailure() }
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let originalContents = try Dictionary(uniqueKeysWithValues: entry.files.map {
            ($0.url.path, try String(contentsOf: $0.url, encoding: .utf8))
        })

        store.reset(entry)

        #expect(store.lastError != nil)
        #expect(store.lastRecoveryDirectory == nil)
        for file in entry.files {
            #expect(try String(contentsOf: file.url, encoding: .utf8) == originalContents[file.url.path])
        }
        #expect(store.entries.contains { $0.hash == hash })
    }

    @Test func resetRejectsIntermediateDirectorySymlinkSwap() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let version = root.appendingPathComponent("mcp-remote-9.9.9", isDirectory: true)
        let originalVersion = root.appendingPathComponent("mcp-remote-9.9.9-original", isDirectory: true)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideMarker = outside.appendingPathComponent("outside-marker")
        try "external".write(to: outsideMarker, atomically: true, encoding: .utf8)
        var swapped = false
        let store = makeStore(
            root: root,
            home: dir,
            beforeResetStage: { index, _ in
                guard index == 0, !swapped else { return }
                swapped = true
                try FileManager.default.moveItem(at: version, to: originalVersion)
                try FileManager.default.createSymbolicLink(at: version, withDestinationURL: outside)
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        #expect(store.lastError != nil)
        #expect(try String(contentsOf: outsideMarker, encoding: .utf8) == "external")
        #expect(FileManager.default.fileExists(atPath: originalVersion.path))
        #expect(store.lastRecoveryDirectory == nil)
    }

    @Test func resetRetainsTransactionWhenRollbackDestinationIsOccupied() throws {
        struct TrashFailure: Error {}
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let initialStore = makeStore(root: root, home: dir)
        let initialEntry = try #require(initialStore.entries.first { $0.hash == hash })
        let occupiedURL = try #require(initialEntry.files.first?.url)
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in
                try "concurrent replacement".write(
                    to: occupiedURL,
                    atomically: true,
                    encoding: .utf8
                )
                throw TrashFailure()
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        let recovery = try #require(store.lastRecoveryDirectory)
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        )
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(store.lastError?.contains(recovery.path) == false)
        #expect(store.lastError?.contains(occupiedURL.path) == false)
        #expect(stagedItems.count == entry.files.count)
        #expect(try String(contentsOf: occupiedURL, encoding: .utf8) == "concurrent replacement")
        #expect(try mode(of: recovery) == 0o700)

        store.clearError()
        #expect(store.lastRecoveryDirectory == recovery)
        store.resetAll()
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(FileManager.default.fileExists(atPath: recovery.path))

        try FileManager.default.removeItem(at: recovery)
        store.reload()
        #expect(store.lastRecoveryDirectory == nil)
    }

    @Test func recoveryRenameNeverOverwritesTargetCreatedAfterPreflight() throws {
        struct TrashFailure: Error {}
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var racedURL: URL?
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in throw TrashFailure() },
            beforeRecoveryRename: { index, url in
                guard index == 0 else { return }
                racedURL = url
                try "concurrent replacement".write(to: url, atomically: true, encoding: .utf8)
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        let recovery = try #require(store.lastRecoveryDirectory)
        let protectedURL = try #require(racedURL)
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        )
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(try String(contentsOf: protectedURL, encoding: .utf8) == "concurrent replacement")
        #expect(stagedItems.count == entry.files.count)
    }

    /// Verifies recovery refuses a staged source replaced after the global preflight.
    @Test func recoveryRenameRejectsStagedSourceReplacedAfterPreflight() throws {
        struct TrashFailure: Error {}
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var replacedOriginalURL: URL?
        var replacedStagedName: String?
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in throw TrashFailure() },
            beforeRecoveryRename: { index, originalURL in
                guard index == 0 else { return }
                let stagingRoot = dir.appendingPathComponent("ResetStaging", isDirectory: true)
                let transactionName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
                        .first { $0.hasPrefix(".codingbuddy-reset-") }
                )
                let transaction = stagingRoot.appendingPathComponent(transactionName, isDirectory: true)
                let stagedName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: transaction.path)
                        .first { $0.hasSuffix("-\(originalURL.lastPathComponent)") }
                )
                let stagedURL = transaction.appendingPathComponent(stagedName)
                try FileManager.default.removeItem(at: stagedURL)
                try "source replacement".write(to: stagedURL, atomically: false, encoding: .utf8)
                replacedOriginalURL = originalURL
                replacedStagedName = stagedName
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        let recovery = try #require(store.lastRecoveryDirectory)
        let originalURL = try #require(replacedOriginalURL)
        let stagedName = try #require(replacedStagedName)
        let retainedReplacement = recovery.appendingPathComponent(stagedName)
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(FileManager.default.fileExists(atPath: retainedReplacement.path))
        #expect(try String(contentsOf: retainedReplacement, encoding: .utf8) == "source replacement")
    }

    @Test func transactionStagingRaceDoesNotOverwriteOrTrashCollision() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        var collisionURL: URL?
        var trashCalls = 0
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                trashCalls += 1
                return url
            },
            beforeTrashStage: { url in
                collisionURL = url
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try "do not remove".write(
                    to: url.appendingPathComponent("marker"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let originalContents = try Dictionary(uniqueKeysWithValues: entry.files.map {
            ($0.url.path, try String(contentsOf: $0.url, encoding: .utf8))
        })

        store.reset(entry)

        let protectedCollisionURL = try #require(collisionURL)
        #expect(trashCalls == 0)
        #expect(
            try String(
                contentsOf: protectedCollisionURL.appendingPathComponent("marker"),
                encoding: .utf8
            ) == "do not remove"
        )
        #expect(
            store.lastRecoveryDirectory?.resolvingSymlinksInPath()
                == protectedCollisionURL.resolvingSymlinksInPath()
        )
        for file in entry.files {
            #expect(try String(contentsOf: file.url, encoding: .utf8) == originalContents[file.url.path])
        }
    }

    @Test func resetRejectsTrashResultForDifferentTransactionIdentity() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let falseTrashResult = dir.appendingPathComponent("different-item", isDirectory: true)
        try FileManager.default.createDirectory(at: falseTrashResult, withIntermediateDirectories: false)
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                let actualTrash = dir.appendingPathComponent("actual-trash", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: actualTrash)
                return falseTrashResult
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })
        let originalContents = try Dictionary(uniqueKeysWithValues: entry.files.map {
            ($0.url.path, try String(contentsOf: $0.url, encoding: .utf8))
        })

        store.reset(entry)

        #expect(store.lastError != nil)
        #expect(store.entries.contains { $0.hash == hash })
        for file in entry.files {
            #expect(try String(contentsOf: file.url, encoding: .utf8) == originalContents[file.url.path])
        }
    }

    @Test func movedTransactionRecoveryPathSurvivesValidationConflictAndReload() throws {
        let dir = try makeTempDir()
        let (root, hash) = try makeFixtureRoot(in: dir)
        let trashDirectory = dir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: false)
        let falseTrashResult = dir.appendingPathComponent("different-item", isDirectory: true)
        try FileManager.default.createDirectory(at: falseTrashResult, withIntermediateDirectories: false)

        let initialStore = makeStore(root: root, home: dir)
        let initialEntry = try #require(initialStore.entries.first { $0.hash == hash })
        let occupiedURL = try #require(initialEntry.files.first?.url)
        var movedTransactionURL: URL?
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { url in
                let destination = trashDirectory.appendingPathComponent(
                    url.lastPathComponent,
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: url, to: destination)
                movedTransactionURL = destination
                try "concurrent replacement".write(
                    to: occupiedURL,
                    atomically: true,
                    encoding: .utf8
                )
                return falseTrashResult
            }
        )
        let entry = try #require(store.entries.first { $0.hash == hash })

        store.reset(entry)

        let movedTransaction = try #require(movedTransactionURL)
        let recovery = try #require(store.lastRecoveryDirectory)
        #expect(recovery.lastPathComponent == movedTransaction.lastPathComponent)
        #expect(recovery.deletingLastPathComponent().lastPathComponent == trashDirectory.lastPathComponent)
        #expect(store.lastFailureKind == .recoveryRequired(recovery))
        #expect(store.lastError?.contains(recovery.path) == false)
        #expect(store.lastError?.contains(occupiedURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        #expect(try String(contentsOf: occupiedURL, encoding: .utf8) == "concurrent replacement")

        store.reload()

        #expect(store.lastRecoveryDirectory == recovery)
        #expect(FileManager.default.fileExists(atPath: recovery.path))
    }

    @Test func resetAllRollsBackEveryRootChildAfterTrashFailure() throws {
        struct TrashFailure: Error {}
        let dir = try makeTempDir()
        let (root, _) = try makeFixtureRoot(in: dir)
        let extra = root.appendingPathComponent("second-version", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        try "credential".write(
            to: extra.appendingPathComponent("file"),
            atomically: true,
            encoding: .utf8
        )
        let originalChildren = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let store = makeStore(
            root: root,
            home: dir,
            trashItem: { _ in throw TrashFailure() }
        )

        store.resetAll()

        #expect(store.lastError != nil)
        #expect(store.lastRecoveryDirectory == nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == originalChildren)
    }

    // MARK: - Redactor

    @Test func redactorMasksSecretBearingKeysOnly() {
        let preview = MCPAuthRedactor.maskedPreview(
            text: #"{"access_token":"SECRETVALUE","scope":"read","client_id":"abc"}"#,
            isJSON: true
        )
        #expect(!preview.contains("SECRETVALUE"))
        #expect(preview.contains("••••••••"))
        #expect(preview.contains("read"))
        #expect(preview.contains("abc"))
    }

    @Test func redactorMasksNonJSONEntirely() {
        let preview = MCPAuthRedactor.maskedPreview(text: "raw-verifier-value", isJSON: false)
        #expect(preview == "••••••••")
    }

    @Test func safeWriterRecoveryMessagePreservesCommitStateAndPath() throws {
        let dir = try makeTempDir()
        let store = makeStore(root: dir.appendingPathComponent("root"), home: dir)
        let recoveryPath = dir.appendingPathComponent("retained-recovery").path
        let error = SafeFileWriter.RecoveryError(
            commitState: .unknown,
            artifacts: [
                SafeFileWriter.RecoveryArtifact(
                    lastKnownPath: recoveryPath,
                    context: .stagedWrite
                )
            ]
        )

        let message = store.userFacingMessage(for: error)

        #expect(message.contains(recoveryPath))
        #expect(message == error.localizedDescription)
        #expect(!message.contains("No unconfirmed changes were written"))
    }

    /// Verifies post-commit cleanup failures never regress to an uncommitted-write message.
    @Test func cleanupDurabilityMessagePreservesCommittedState() throws {
        let dir = try makeTempDir()
        let store = makeStore(root: dir.appendingPathComponent("root"), home: dir)
        let error = SafeFileWriter.CleanupDurabilityError()

        let message = store.userFacingMessage(for: error)

        #expect(message == error.localizedDescription)
        #expect(!message.contains("No unconfirmed changes were written"))
    }

    @Test func safeWriterRecoveryMapsToDirectArtifactAction() throws {
        let dir = try makeTempDir()
        let store = makeStore(root: dir.appendingPathComponent("root"), home: dir)
        let recoveryURL = dir.appendingPathComponent("retained-recovery")
        let error = SafeFileWriter.RecoveryError(
            commitState: .committed,
            artifacts: [
                SafeFileWriter.RecoveryArtifact(
                    lastKnownPath: recoveryURL.path,
                    context: .stagedWrite
                )
            ]
        )

        #expect(store.failureKind(for: error) == .writeRecovery(recoveryURL))
    }

    /// Verifies dismissal invalidates a pending authentication result even when
    /// a later sheet presentation has already started.
    @Test func editorLifecycleRejectsAuthenticationCompletedAfterDismissal() {
        var lifecycle = MCPAuthEditorLifecycle()
        let dismissedRequest = lifecycle.appear()
        #expect(lifecycle.accepts(dismissedRequest))

        lifecycle.disappear()
        #expect(!lifecycle.accepts(dismissedRequest))

        let currentRequest = lifecycle.appear()
        #expect(!lifecycle.accepts(dismissedRequest))
        #expect(lifecycle.accepts(currentRequest))
    }

    /// Verifies reset blockers retain the most actionable recovery location.
    @Test func resetSafetyBlockerPreservesRecoveryPrecedenceAndLocation() {
        let root = URL(fileURLWithPath: "/tmp/mcp-auth")
        let refused = URL(fileURLWithPath: "/tmp/recovery-scan")
        let recovery = URL(fileURLWithPath: "/tmp/recovery-transaction")

        #expect(
            MCPAuthResetSafetyBlocker.resolve(
                recoveryDirectory: recovery,
                recoveryDiscoveryRefusedAt: refused,
                hasIncompleteInventory: true,
                rootDirectory: root
            ) == .recoveryRequired(recovery)
        )
        #expect(
            MCPAuthResetSafetyBlocker.resolve(
                recoveryDirectory: nil,
                recoveryDiscoveryRefusedAt: refused,
                hasIncompleteInventory: true,
                rootDirectory: root
            ) == .recoveryDiscoveryUnavailable(refused)
        )
        #expect(
            MCPAuthResetSafetyBlocker.resolve(
                recoveryDirectory: nil,
                recoveryDiscoveryRefusedAt: nil,
                hasIncompleteInventory: true,
                rootDirectory: root
            ) == .incompleteInventory(root)
        )
        #expect(
            MCPAuthResetSafetyBlocker.resolve(
                recoveryDirectory: nil,
                recoveryDiscoveryRefusedAt: nil,
                hasIncompleteInventory: false,
                rootDirectory: root
            ) == nil
        )
    }

    /// Verifies safety refusals retain their specific user-facing explanation.
    @Test func loadSafetyErrorPreservesConcreteMessage() throws {
        let dir = try makeTempDir()
        let store = makeStore(root: dir.appendingPathComponent("root"), home: dir)
        let error = SafeFileWriter.WriteError.targetTooLarge
        let message = store.userFacingMessage(for: error)

        #expect(message == error.localizedDescription)
        #expect(
            message != String(
                localized: "CodingBuddy could not complete the credential operation. No unconfirmed changes were written."
            )
        )
    }
}
