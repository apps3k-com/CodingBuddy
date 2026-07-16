//
//  AgentContextInspectorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Controllable asynchronous scanner boundary for repository-switch race tests.
private actor ControlledAgentContextScan {
    /// Pending continuations grouped by standardized repository path.
    private var pending: [String: [CheckedContinuation<AgentContextScanResult, Never>]] = [:]

    /// Suspends until the test publishes a result for the requested repository.
    func result(for repositoryURL: URL) async -> AgentContextScanResult {
        await withCheckedContinuation { continuation in
            pending[repositoryURL.standardizedFileURL.path, default: []].append(continuation)
        }
    }

    /// Number of suspended requests for one repository.
    func pendingCount(for repositoryURL: URL) -> Int {
        pending[repositoryURL.standardizedFileURL.path]?.count ?? 0
    }

    /// Resumes the oldest request for one repository and reports whether one existed.
    @discardableResult
    func complete(_ result: AgentContextScanResult, for repositoryURL: URL) -> Bool {
        let path = repositoryURL.standardizedFileURL.path
        guard var continuations = pending[path], !continuations.isEmpty else { return false }
        let continuation = continuations.removeFirst()
        pending[path] = continuations.isEmpty ? nil : continuations
        continuation.resume(returning: result)
        return true
    }
}

/// Scanner and store coverage for the read-only Agent Context Inspector.
@MainActor
@Suite(.serialized)
struct AgentContextInspectorTests {

    /// Creates an isolated temporary repository fixture for a single test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentContextInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes UTF-8 content while creating any missing parent directories.
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Finds a scanner result by repository-relative path.
    private func item(_ relativePath: String, in items: [AgentContextItem]) throws -> AgentContextItem {
        try #require(items.first { $0.relativePath == relativePath })
    }

    /// Waits for the store's background reload to publish scanner output.
    private func waitForItems(in store: AgentContextInspectorStore) async throws -> [AgentContextItem] {
        for _ in 0..<100 {
            if !store.items.isEmpty {
                return store.items
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.items
    }

    /// Waits for the store to publish one expected presentation phase.
    private func waitForState(
        _ phase: AgentContextInspectorPhase,
        in store: AgentContextInspectorStore
    ) async throws -> AgentContextInspectorState {
        for _ in 0..<100 {
            if store.state.phase == phase {
                return store.state
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.state
    }

    /// Waits until a controlled scanner has accepted one repository request.
    private func waitForPendingRequest(
        for repositoryURL: URL,
        in scanner: ControlledAgentContextScan,
        count: Int = 1
    ) async throws {
        for _ in 0..<100 {
            if await scanner.pendingCount(for: repositoryURL) >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await scanner.pendingCount(for: repositoryURL) >= count)
    }

    /// Creates one deterministic row for store-only state-transition tests.
    private func testItem(_ relativePath: String, repositoryURL: URL) -> AgentContextItem {
        AgentContextItem(
            relativePath: relativePath,
            url: repositoryURL.appendingPathComponent(relativePath),
            kind: .documentation,
            entryType: .file,
            byteCount: 1,
            modifiedAt: nil,
            warnings: []
        )
    }

    /// Verifies deterministic discovery order and primary signals for supported context entries.
    @Test func scannerReportsGovernanceOptionalContextAndProjectConfig() throws {
        let repo = try makeTempDir()
        try write("# Agent rules\n", to: repo.appendingPathComponent("AGENTS.md"))
        try write("# Claude rules\n", to: repo.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".cursor/rules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("{}", to: repo.appendingPathComponent(".mcp.json"))
        try write("[project]\n", to: repo.appendingPathComponent(".codex/config.toml"))
        try write("# Example\n", to: repo.appendingPathComponent("README.md"))

        let items = AgentContextScanner(repositoryURL: repo).items()

        #expect(items.map(\.relativePath) == [
            "AGENTS.md",
            "CLAUDE.md",
            ".cursor/rules",
            ".mcp.json",
            ".codex/config.toml",
            "README.md",
        ])

        let agents = try item("AGENTS.md", in: items)
        let claude = try item("CLAUDE.md", in: items)
        #expect(agents.warnings.contains(.bothGovernanceFilesPresent))
        #expect(claude.warnings.contains(.bothGovernanceFilesPresent))

        let cursorRules = try item(".cursor/rules", in: items)
        #expect(cursorRules.entryType == .directory)
        #expect(cursorRules.actionCapability == .allowed)

        let mcpConfig = try item(".mcp.json", in: items)
        #expect(mcpConfig.warnings == [.projectLocalMCPConfigPresent])

        let codexConfig = try item(".codex/config.toml", in: items)
        #expect(codexConfig.warnings == [.codexProjectConfigPresent])
    }

    /// Verifies missing, empty, and oversized file warnings for governance and documentation entries.
    @Test func scannerFlagsMissingEmptyAndOversizedGovernanceFiles() throws {
        let repo = try makeTempDir()
        try write("", to: repo.appendingPathComponent("CLAUDE.md"))
        try write(
            String(repeating: "A", count: AgentContextScanner.oversizedFileByteThreshold + 1),
            to: repo.appendingPathComponent("README.md")
        )

        let items = AgentContextScanner(repositoryURL: repo).items()
        let agents = try item("AGENTS.md", in: items)
        let claude = try item("CLAUDE.md", in: items)
        let readme = try item("README.md", in: items)

        #expect(agents.entryType == .missing)
        #expect(agents.warnings == [.missingAgentsMarkdown])
        #expect(claude.entryType == .file)
        #expect(claude.warnings == [.emptyFile])
        #expect(readme.warnings == [.oversizedFile])
    }

    /// Verifies `.cursor/rules` may be a file without triggering recursive repository scans.
    @Test func scannerReportsCursorRulesFileWithoutRecursingRepository() throws {
        let repo = try makeTempDir()
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".cursor", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("Use Swift Testing only.\n", to: repo.appendingPathComponent(".cursor/rules"))
        try write("# Nested rules\n", to: repo.appendingPathComponent("Sources/AGENTS.md"))

        let items = AgentContextScanner(repositoryURL: repo).items()
        let cursorRules = try item(".cursor/rules", in: items)

        #expect(cursorRules.entryType == .file)
        #expect(!items.contains { $0.relativePath == "Sources/AGENTS.md" })
    }

    /// Verifies symlink entries are reported without traversing their targets.
    @Test func scannerReportsDanglingSymlinkAsPresentWithoutTraversingTarget() throws {
        let repo = try makeTempDir()
        let link = repo.appendingPathComponent(".mcp.json")
        let missingTarget = repo.appendingPathComponent("missing-config.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: missingTarget.path)

        let items = AgentContextScanner(repositoryURL: repo).items()
        let mcpConfig = try item(".mcp.json", in: items)

        #expect(mcpConfig.entryType == .symlink)
        #expect(mcpConfig.actionCapability == .blockedSymlink)
        #expect(!mcpConfig.actionCapability.allowsExternalActions)
        #expect(mcpConfig.warnings.contains(.symlinkNotTraversed))
        #expect(mcpConfig.warnings.contains(.projectLocalMCPConfigPresent))
    }

    /// Verifies a repository selected through a symbolic link is rejected at the root boundary.
    @Test func scannerRejectsSymlinkedRepositoryRoot() throws {
        let fixture = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("outside\n", to: outside.appendingPathComponent("AGENTS.md"))
        let linkedRoot = fixture.appendingPathComponent("linked-repository", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        let scanner = AgentContextScanner(repositoryURL: linkedRoot)

        #expect(scanner.scan() == .refused(.repositoryPathUnavailableOrUnsafe))
        #expect(scanner.items().isEmpty)
    }

    /// Verifies hidden agent directories cannot redirect nested scans outside the repository.
    @Test func scannerBlocksSymlinkedIntermediateAgentDirectories() throws {
        let repo = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }

        try write(
            String(repeating: "A", count: AgentContextScanner.oversizedFileByteThreshold + 1),
            to: outside.appendingPathComponent("cursor/rules")
        )
        try write(
            String(repeating: "B", count: AgentContextScanner.oversizedFileByteThreshold + 1),
            to: outside.appendingPathComponent("codex/config.toml")
        )
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent(".cursor").path,
            withDestinationPath: outside.appendingPathComponent("cursor").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent(".codex").path,
            withDestinationPath: outside.appendingPathComponent("codex").path
        )

        let items = AgentContextScanner(repositoryURL: repo).items()
        let cursorRules = try item(".cursor/rules", in: items)
        let codexConfig = try item(".codex/config.toml", in: items)

        #expect(cursorRules.entryType == .symlink)
        #expect(cursorRules.actionCapability == .blockedSymlink)
        #expect(!cursorRules.actionCapability.allowsExternalActions)
        #expect(cursorRules.warnings == [.symlinkNotTraversed])
        #expect(!cursorRules.warnings.contains(.oversizedFile))
        #expect(codexConfig.entryType == .symlink)
        #expect(codexConfig.actionCapability == .blockedSymlink)
        #expect(!codexConfig.actionCapability.allowsExternalActions)
        #expect(codexConfig.warnings == [.symlinkNotTraversed, .codexProjectConfigPresent])
        #expect(!codexConfig.warnings.contains(.oversizedFile))
    }

    /// Verifies normal nested agent context paths remain discoverable inside the repository.
    @Test func scannerPreservesNormalNestedAgentContextDiscovery() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("Use Swift Testing only.\n", to: repo.appendingPathComponent(".cursor/rules"))
        try write("[project]\n", to: repo.appendingPathComponent(".codex/config.toml"))

        let items = AgentContextScanner(repositoryURL: repo).items()
        let cursorRules = try item(".cursor/rules", in: items)
        let codexConfig = try item(".codex/config.toml", in: items)

        #expect(cursorRules.entryType == .file)
        #expect(cursorRules.actionCapability == .allowed)
        #expect(cursorRules.actionCapability.allowsExternalActions)
        #expect(cursorRules.warnings.isEmpty)
        #expect(codexConfig.entryType == .file)
        #expect(codexConfig.actionCapability == .allowed)
        #expect(codexConfig.actionCapability.allowsExternalActions)
        #expect(codexConfig.warnings == [.codexProjectConfigPresent])
    }

    /// Verifies a post-scan intermediate symlink cannot reach an external action route.
    @Test func actionValidationBlocksReplacedIntermediateDirectorySymlink() throws {
        let repo = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("inside\n", to: repo.appendingPathComponent(".cursor/rules"))
        try write("outside\n", to: outside.appendingPathComponent("rules"))

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item(".cursor/rules", in: scanner.items())
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".cursor"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent(".cursor").path,
            withDestinationPath: outside.path
        )

        var performed = false
        let result = scanner.performValidatedAction(for: scannedItem) { _ in
            performed = true
            return true
        }

        #expect(result == nil)
        #expect(!performed)
    }

    /// Verifies replacing the repository root with a symlink invalidates a scanned action.
    @Test func actionValidationBlocksRepositoryRootSymlinkSubstitution() throws {
        let fixture = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outside)
        }
        let repo = fixture.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try write("inside\n", to: repo.appendingPathComponent("AGENTS.md"))
        try write("outside\n", to: outside.appendingPathComponent("AGENTS.md"))

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        try FileManager.default.moveItem(
            at: repo,
            to: fixture.appendingPathComponent("original-repository", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(at: repo, withDestinationURL: outside)

        var performed = false
        let result = scanner.performValidatedAction(for: scannedItem) { _ in
            performed = true
            return true
        }

        #expect(result == nil)
        #expect(!performed)
    }

    /// Verifies a post-scan leaf symlink cannot reach an external action route.
    @Test func actionValidationBlocksReplacedLeafSymlink() throws {
        let repo = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("inside\n", to: repo.appendingPathComponent("AGENTS.md"))
        let outsideFile = outside.appendingPathComponent("AGENTS.md")
        try write("outside\n", to: outsideFile)

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        try FileManager.default.removeItem(at: repo.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("AGENTS.md").path,
            withDestinationPath: outsideFile.path
        )

        var performed = false
        let result = scanner.performValidatedAction(for: scannedItem) { _ in
            performed = true
            return true
        }

        #expect(result == nil)
        #expect(!performed)
    }

    /// Verifies a replacement immediately before handoff cannot reach the external action.
    @Test func actionValidationBlocksLeafSwapImmediatelyBeforeHandoff() throws {
        let repo = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        let repositoryFile = repo.appendingPathComponent("AGENTS.md")
        let outsideFile = outside.appendingPathComponent("AGENTS.md")
        try write("inside\n", to: repositoryFile)
        try write("outside\n", to: outsideFile)

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        var performed = false
        let result = scanner.performValidatedAction(
            for: scannedItem,
            beforeFinalValidation: {
                try? FileManager.default.removeItem(at: repositoryFile)
                try? FileManager.default.createSymbolicLink(
                    atPath: repositoryFile.path,
                    withDestinationPath: outsideFile.path
                )
            },
            { _ in
                performed = true
                return true
            }
        )

        #expect(result == nil)
        #expect(!performed)
    }

    /// Verifies unchanged regular entries open through a private read-only descriptor snapshot.
    @Test func actionValidationAllowsUnchangedValidFile() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("inside\n", to: repo.appendingPathComponent("AGENTS.md"))

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        let actionURL = try #require(scanner.performValidatedAction(for: scannedItem) { actionURL in
            let snapshotText = try? String(contentsOf: actionURL, encoding: .utf8)
            #expect(snapshotText == "inside\n")
            return actionURL
        })
        let snapshotRoot = actionURL.deletingLastPathComponent().deletingLastPathComponent()
        defer { AgentContextScanner.cleanupAllPrivateSnapshots(rootURL: snapshotRoot) }

        #expect(scannedItem.actionCapability == .allowed)
        #expect(actionURL != repo.appendingPathComponent("AGENTS.md"))
        #expect(actionURL.lastPathComponent == "AGENTS.md")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: actionURL.path)[.posixPermissions] as? Int
        )
        #expect(permissions & 0o777 == 0o400)
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: actionURL.deletingLastPathComponent().path
            )[.posixPermissions] as? Int
        )
        #expect(directoryPermissions & 0o777 == 0o500)
    }

    /// Verifies a repository-path replacement after snapshot creation cannot redirect the open.
    @Test func actionSnapshotRemainsBoundAfterRepositoryPathReplacement() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        let repositoryFile = repo.appendingPathComponent("AGENTS.md")
        try write("inside\n", to: repositoryFile)

        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        var snapshotRoot: URL?
        let openedText = scanner.performValidatedAction(for: scannedItem) { snapshotURL in
            snapshotRoot = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
            try? FileManager.default.removeItem(at: repositoryFile)
            try? self.write("replacement\n", to: repositoryFile)
            return try? String(contentsOf: snapshotURL, encoding: .utf8)
        }
        defer {
            if let snapshotRoot {
                AgentContextScanner.cleanupAllPrivateSnapshots(rootURL: snapshotRoot)
            }
        }

        #expect(openedText == "inside\n")
        #expect(try String(contentsOf: repositoryFile, encoding: .utf8) == "replacement\n")
    }

    /// Verifies a later process can remove a private snapshot left by an earlier process.
    @Test func stalePrivateSnapshotCleanupRemovesValidatedExpiredDirectory() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("inside\n", to: repo.appendingPathComponent("AGENTS.md"))
        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        let actionURL = try #require(scanner.performValidatedAction(for: scannedItem) { $0 })
        let snapshotDirectory = actionURL.deletingLastPathComponent()
        let snapshotRoot = snapshotDirectory.deletingLastPathComponent()
        defer { AgentContextScanner.cleanupAllPrivateSnapshots(rootURL: snapshotRoot) }
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-AgentContextScanner.privateSnapshotLifetime - 1)],
            ofItemAtPath: snapshotDirectory.path
        )

        let removed = AgentContextScanner.cleanupExpiredPrivateSnapshots(
            now: now,
            rootURL: snapshotRoot
        )

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectory.path))
    }

    /// Verifies quit-style cleanup preserves a fresh snapshot during its handoff lifetime.
    @Test func expiredSnapshotCleanupPreservesFreshLaunchServicesHandoff() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("inside\n", to: repo.appendingPathComponent("AGENTS.md"))
        let scanner = AgentContextScanner(repositoryURL: repo)
        let scannedItem = try item("AGENTS.md", in: scanner.items())
        let actionURL = try #require(scanner.performValidatedAction(for: scannedItem) { $0 })
        let snapshotDirectory = actionURL.deletingLastPathComponent()
        let snapshotRoot = snapshotDirectory.deletingLastPathComponent()
        defer { AgentContextScanner.cleanupAllPrivateSnapshots(rootURL: snapshotRoot) }

        let removed = AgentContextScanner.cleanupExpiredPrivateSnapshots(
            now: Date(),
            rootURL: snapshotRoot
        )

        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: actionURL.path))
        #expect(try String(contentsOf: actionURL, encoding: .utf8) == "inside\n")
    }

    /// Verifies cleanup never follows a UUID-named symlink outside its private root.
    @Test func privateSnapshotCleanupIgnoresSymlinkedDirectory() throws {
        let fixture = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("CodingBuddy-AgentContext", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("AGENTS.md")
        try write("outside\n", to: marker)
        let link = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let removed = AgentContextScanner.cleanupAllPrivateSnapshots(rootURL: root)

        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let linkType = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
    }

    /// Verifies missing and unexpected entries cannot route external actions.
    @Test func itemActionCapabilityBlocksNonActionableEntryTypes() {
        let baseURL = URL(fileURLWithPath: "/tmp/example")
        let missing = AgentContextItem(
            relativePath: "AGENTS.md",
            url: baseURL.appendingPathComponent("AGENTS.md"),
            kind: .governance,
            entryType: .missing,
            byteCount: nil,
            modifiedAt: nil,
            warnings: [.missingAgentsMarkdown]
        )
        let unexpected = AgentContextItem(
            relativePath: ".mcp.json",
            url: baseURL.appendingPathComponent(".mcp.json"),
            kind: .mcpConfig,
            entryType: .unexpected,
            byteCount: nil,
            modifiedAt: nil,
            warnings: [.unexpectedType]
        )

        #expect(missing.actionCapability == .blockedMissing)
        #expect(!missing.actionCapability.allowsExternalActions)
        #expect(unexpected.actionCapability == .blockedUnexpectedEntry)
        #expect(!unexpected.actionCapability.allowsExternalActions)
    }

    /// Verifies repository selection persistence and reload behavior use injected defaults.
    @Test func storePersistsRepositorySelectionAndReloadsItems() async throws {
        let repo = try makeTempDir()
        try write("# Agent rules\n", to: repo.appendingPathComponent("AGENTS.md"))
        let suiteName = "CodingBuddy.AgentContextInspectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let store = AgentContextInspectorStore(defaults: defaults)
        #expect(store.selectedRepositoryURL == nil)
        #expect(store.items.isEmpty)

        store.selectRepository(repo)
        let items = try await waitForItems(in: store)

        #expect(defaults.string(forKey: AgentContextInspectorStore.repositoryPathKey) == repo.standardizedFileURL.path)
        #expect(items.contains { $0.relativePath == "AGENTS.md" && $0.entryType == .file })

        let restoredStore = AgentContextInspectorStore(defaults: defaults)
        #expect(restoredStore.selectedRepositoryURL?.path == repo.standardizedFileURL.path)

        store.clearRepository()
        #expect(store.selectedRepositoryURL == nil)
        #expect(store.items.isEmpty)
        #expect(defaults.string(forKey: AgentContextInspectorStore.repositoryPathKey) == nil)
    }

    /// Verifies selecting another repository clears old rows before its scan completes.
    @Test func storeClearsStaleRowsImmediatelyWhenRepositoryChanges() async throws {
        let firstRepository = try makeTempDir()
        let secondRepository = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: firstRepository)
            try? FileManager.default.removeItem(at: secondRepository)
        }
        let suiteName = "CodingBuddy.AgentContextInspectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scanner = ControlledAgentContextScan()
        let store = AgentContextInspectorStore(defaults: defaults) { repositoryURL in
            await scanner.result(for: repositoryURL)
        }
        let firstItem = testItem("FIRST.md", repositoryURL: firstRepository)
        let secondItem = testItem("SECOND.md", repositoryURL: secondRepository)

        store.selectRepository(firstRepository)
        try await waitForPendingRequest(for: firstRepository, in: scanner)
        #expect(await scanner.complete(.loaded([firstItem]), for: firstRepository))
        let firstState = try await waitForState(.loaded, in: store)
        #expect(firstState == .loaded(firstRepository.standardizedFileURL, [firstItem]))

        store.selectRepository(secondRepository)

        #expect(store.state == .loading(secondRepository.standardizedFileURL))
        #expect(store.selectedRepositoryURL == secondRepository.standardizedFileURL)
        #expect(store.items.isEmpty)
        try await waitForPendingRequest(for: secondRepository, in: scanner)
        #expect(await scanner.complete(.loaded([secondItem]), for: secondRepository))
        let secondState = try await waitForState(.loaded, in: store)
        #expect(secondState == .loaded(secondRepository.standardizedFileURL, [secondItem]))
    }

    /// Verifies a cancelled older scan cannot replace a newer repository result.
    @Test func storeRejectsLateResultFromPreviouslySelectedRepository() async throws {
        let firstRepository = try makeTempDir()
        let secondRepository = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: firstRepository)
            try? FileManager.default.removeItem(at: secondRepository)
        }
        let suiteName = "CodingBuddy.AgentContextInspectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scanner = ControlledAgentContextScan()
        let store = AgentContextInspectorStore(defaults: defaults) { repositoryURL in
            await scanner.result(for: repositoryURL)
        }
        let oldItem = testItem("OLD.md", repositoryURL: firstRepository)
        let currentItem = testItem("CURRENT.md", repositoryURL: secondRepository)

        store.selectRepository(firstRepository)
        try await waitForPendingRequest(for: firstRepository, in: scanner)
        store.selectRepository(secondRepository)
        try await waitForPendingRequest(for: secondRepository, in: scanner)

        #expect(await scanner.complete(.loaded([currentItem]), for: secondRepository))
        _ = try await waitForState(.loaded, in: store)
        #expect(await scanner.complete(.loaded([oldItem]), for: firstRepository))
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(store.state == .loaded(secondRepository.standardizedFileURL, [currentItem]))
        #expect(store.items == [currentItem])
    }

    /// Verifies Retry can recover after an unsafe root is replaced by a regular directory.
    @Test func storeRetriesRefusedRootAndRecoversWhenPathBecomesSafe() async throws {
        let fixture = try makeTempDir()
        let outside = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outside)
        }
        let repository = fixture.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
        let suiteName = "CodingBuddy.AgentContextInspectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentContextInspectorStore(defaults: defaults)

        store.selectRepository(repository)
        let refusedState = try await waitForState(.refused, in: store)

        #expect(
            refusedState == .refused(
                repository.standardizedFileURL,
                .repositoryPathUnavailableOrUnsafe
            )
        )
        #expect(store.items.isEmpty)
        #expect(store.problemCount == 1)

        try FileManager.default.removeItem(at: repository)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try write("# Agent rules\n", to: repository.appendingPathComponent("AGENTS.md"))

        store.reload()
        #expect(store.state == .loading(repository.standardizedFileURL))
        let recoveredState = try await waitForState(.loaded, in: store)

        guard case let .loaded(loadedRepository, items) = recoveredState else {
            Issue.record("Expected a loaded state after retry")
            return
        }
        #expect(loadedRepository == repository.standardizedFileURL)
        #expect(items.contains { $0.relativePath == "AGENTS.md" && $0.entryType == .file })
    }

    /// Verifies repo-wide governance conflicts are counted once in the sidebar badge.
    @Test func storeCountsRepoWideGovernanceWarningOnce() async throws {
        let repo = try makeTempDir()
        try write("# Agent rules\n", to: repo.appendingPathComponent("AGENTS.md"))
        try write("# Claude rules\n", to: repo.appendingPathComponent("CLAUDE.md"))
        let suiteName = "CodingBuddy.AgentContextInspectorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let store = AgentContextInspectorStore(defaults: defaults)
        store.selectRepository(repo)
        _ = try await waitForItems(in: store)

        #expect(store.problemCount == 1)
    }

    /// Verifies inspector search covers paths, kinds, entry types, and warning signals.
    @Test func itemSearchMatchesPathKindTypeAndSignals() {
        let item = AgentContextItem(
            relativePath: ".mcp.json",
            url: URL(fileURLWithPath: "/tmp/example/.mcp.json"),
            kind: .mcpConfig,
            entryType: .file,
            byteCount: 2,
            modifiedAt: nil,
            warnings: [.projectLocalMCPConfigPresent]
        )

        #expect(item.matches(searchText: ".mcp"))
        #expect(item.matches(searchText: "mcpConfig"))
        #expect(item.matches(searchText: "file"))
        #expect(item.matches(searchText: "projectLocalMCPConfigPresent"))
        #expect(!item.matches(searchText: "cursor"))
    }

    /// Verifies an empty loaded repository is not presented as a failed search.
    @Test func emptyStateDistinguishesRepositoryContentFromSearchResults() {
        #expect(AgentContextInspectorEmptyState(searchText: "") == .noContextFiles)
        #expect(AgentContextInspectorEmptyState(searchText: "AGENTS") == .noSearchResults)
    }
}
