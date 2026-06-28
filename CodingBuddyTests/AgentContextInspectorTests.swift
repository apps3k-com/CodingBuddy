//
//  AgentContextInspectorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

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
        #expect(mcpConfig.warnings.contains(.symlinkNotTraversed))
        #expect(mcpConfig.warnings.contains(.projectLocalMCPConfigPresent))
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
}
