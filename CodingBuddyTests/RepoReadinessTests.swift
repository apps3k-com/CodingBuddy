//
//  RepoReadinessTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Scanner and store coverage for the read-only Repo Readiness checklist.
@MainActor
@Suite(.serialized)
struct RepoReadinessTests {
    /// In-memory defaults replacement that keeps store tests away from real preferences.
    private final class MemoryDefaults: RepoReadinessDefaultsStoring {
        /// Stored key-value pairs for one test instance.
        private var values: [String: String] = [:]

        /// Returns a stored string for the given key.
        func string(forKey defaultName: String) -> String? {
            values[defaultName]
        }

        /// Stores a string for the given key.
        func setRepoReadinessString(_ value: String, forKey defaultName: String) {
            values[defaultName] = value
        }

        /// Removes a stored value for the given key.
        func removeObject(forKey defaultName: String) {
            values.removeValue(forKey: defaultName)
        }
    }

    /// Creates an isolated temporary repository fixture for a single test.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Finds a readiness result by stable check code.
    private func item(_ code: RepoReadinessCheckCode, in items: [RepoReadinessItem]) throws -> RepoReadinessItem {
        try #require(items.first { $0.code == code })
    }

    /// Waits for the store's background reload to publish scanner output.
    private func waitForItems(in store: RepoReadinessStore) async throws -> [RepoReadinessItem] {
        for _ in 0..<100 {
            if !store.items.isEmpty {
                return store.items
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.items
    }

    /// Verifies a repo with common agentic-coding project files reports stable passing checks.
    @Test func scannerReportsPassingChecklistForReadyRepository() throws {
        let repo = try makeTempDir()
        try write("# Agent rules\nUse Swift Testing and keep changes scoped.\n", to: repo.appendingPathComponent("AGENTS.md"))
        try write(
            """
            # Example

            Build with `xcodebuild -project Example.xcodeproj -scheme Example build`.
            Test with `xcodebuild test -project Example.xcodeproj -scheme Example -destination 'platform=macOS'`.
            """,
            to: repo.appendingPathComponent("README.md")
        )
        try write(
            """
            # Contributing

            Open a GitHub issue, create a branch, run tests, and submit a pull request.
            """,
            to: repo.appendingPathComponent("CONTRIBUTING.md")
        )
        try write("", to: repo.appendingPathComponent("Example.xcodeproj/project.pbxproj"))
        try write("enum FeatureFlag {}\n", to: repo.appendingPathComponent("Example/Services/FeatureFlags.swift"))
        try write("# Feature flags\n", to: repo.appendingPathComponent("docs/FEATURE_FLAGS.md"))
        try write(
            """
            #!/bin/sh
            git config core.hooksPath .githooks
            """,
            to: repo.appendingPathComponent("scripts/setup.sh")
        )
        try write("#!/bin/sh\n", to: repo.appendingPathComponent(".githooks/pre-commit"))
        try write("name: bug\n", to: repo.appendingPathComponent(".github/ISSUE_TEMPLATE/bug.yml"))
        try write("## Summary\n", to: repo.appendingPathComponent(".github/pull_request_template.md"))
        try write(
            """
            name: CI
            on: [push]
            jobs:
              test:
                steps:
                  - run: xcodebuild test -project Example.xcodeproj -scheme Example -destination 'platform=macOS'
            """,
            to: repo.appendingPathComponent(".github/workflows/ci.yml")
        )
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(items.map(\.code) == RepoReadinessCheckCode.allCases)
        #expect(items.count >= 8)
        #expect(items.allSatisfy { $0.status == .pass })
        #expect(items.allSatisfy { !$0.remediationHint.isEmpty })
        #expect(try item(.governance, in: items).source == "AGENTS.md")
        #expect(try item(.buildAndTestDocumentation, in: items).source == "README.md")
    }

    /// Verifies missing readiness files fail deterministically and scanning does not create files.
    @Test func scannerReportsFailuresForSparseRepositoryWithoutWritingFiles() throws {
        let repo = try makeTempDir()
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: repo.path))

        let items = RepoReadinessScanner(repositoryURL: repo).items()
        let after = try Set(FileManager.default.contentsOfDirectory(atPath: repo.path))

        #expect(before == after)
        #expect(items.map(\.code) == RepoReadinessCheckCode.allCases)
        #expect(try item(.governance, in: items).status == .fail)
        #expect(try item(.readme, in: items).status == .fail)
        #expect(try item(.buildAndTestDocumentation, in: items).status == .fail)
        #expect(try item(.contributionWorkflow, in: items).status == .fail)
        #expect(try item(.githubTemplates, in: items).status == .fail)
        #expect(try item(.setupAndHooks, in: items).status == .fail)
        #expect(try item(.ciWorkflow, in: items).status == .fail)
        #expect(try item(.repositoryState, in: items).status == .warn)
    }

    /// Verifies partial signals produce warnings instead of all-or-nothing failures.
    @Test func scannerReportsWarningsForPartialReadinessSignals() throws {
        let repo = try makeTempDir()
        try write("# Claude-only guidance\n", to: repo.appendingPathComponent("CLAUDE.md"))
        try write("", to: repo.appendingPathComponent("README.md"))
        try write("# Contributing\nOpen a pull request.\n", to: repo.appendingPathComponent("CONTRIBUTING.md"))
        try write("enum FeatureFlag {}\n", to: repo.appendingPathComponent("App/Services/FeatureFlags.swift"))
        try write("name: task\n", to: repo.appendingPathComponent(".github/ISSUE_TEMPLATE/task.yml"))
        try write("name: Release\non: [push]\n", to: repo.appendingPathComponent(".github/workflows/release.yml"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/rebase-merge", isDirectory: true), withIntermediateDirectories: true)

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.governance, in: items).status == .warn)
        #expect(try item(.readme, in: items).status == .warn)
        #expect(try item(.contributionWorkflow, in: items).status == .warn)
        #expect(try item(.githubTemplates, in: items).status == .warn)
        #expect(try item(.featureFlagDocumentation, in: items).status == .warn)
        #expect(try item(.ciWorkflow, in: items).status == .warn)
        #expect(try item(.repositoryState, in: items).status == .warn)
    }

    /// Verifies worktree-style .git files are resolved before checking lock markers.
    @Test func repositoryStateResolvesGitdirFileForWorktrees() throws {
        let repo = try makeTempDir()
        let gitDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessGit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try write("", to: gitDirectory.appendingPathComponent("index.lock"))
        try write("gitdir: \(gitDirectory.path)\n", to: repo.appendingPathComponent(".git"))

        let items = RepoReadinessScanner(repositoryURL: repo).items()
        let state = try item(.repositoryState, in: items)

        #expect(state.status == .fail)
        #expect(state.source == ".git/index.lock")
    }

    /// Verifies unresolvable .git files warn instead of reporting a clean repository state.
    @Test func repositoryStateWarnsForUnresolvedGitdirFile() throws {
        let repo = try makeTempDir()
        try write("gitdir: ../missing-git-dir\n", to: repo.appendingPathComponent(".git"))

        let items = RepoReadinessScanner(repositoryURL: repo).items()
        let state = try item(.repositoryState, in: items)

        #expect(state.status == .warn)
        #expect(state.source == ".git")
    }

    /// Verifies fixed-name documentation symlinks are not followed outside the selected repository.
    @Test func scannerDoesNotReadSymlinkedDocumentationOutsideRepository() throws {
        let repo = try makeTempDir()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideREADME = outside.appendingPathComponent("README.md")
        try write(
            """
            # Outside

            Build with `xcodebuild build`.
            Test with `xcodebuild test`.
            """,
            to: outsideREADME
        )
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("README.md"),
            withDestinationURL: outsideREADME
        )

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.readme, in: items).status == .fail)
        #expect(try item(.buildAndTestDocumentation, in: items).status == .fail)
    }

    /// Verifies symlinked documentation directories are not enumerated outside the selected repository.
    @Test func scannerDoesNotReadSymlinkedDocumentationDirectoriesOutsideRepository() throws {
        let repo = try makeTempDir()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessOutsideDocs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write(
            """
            # Outside docs

            Build with `xcodebuild build`.
            Test with `xcodebuild test`.
            """,
            to: outside.appendingPathComponent("DEVELOPMENT.md")
        )
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("docs"),
            withDestinationURL: outside
        )

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.buildAndTestDocumentation, in: items).status == .fail)
    }

    /// Verifies nested GitHub paths are not read through a symlinked parent directory.
    @Test func scannerDoesNotReadThroughSymlinkedGitHubParentDirectory() throws {
        let repo = try makeTempDir()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessOutsideGitHub-\(UUID().uuidString)", isDirectory: true)
        try write("name: bug\n", to: outside.appendingPathComponent("ISSUE_TEMPLATE/bug.yml"))
        try write("## Summary\n", to: outside.appendingPathComponent("pull_request_template.md"))
        try write(
            """
            name: CI
            on: [push]
            jobs:
              test:
                steps:
                  - run: xcodebuild test -project Example.xcodeproj -scheme Example -destination 'platform=macOS'
            """,
            to: outside.appendingPathComponent("workflows/ci.yml")
        )
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent(".github"),
            withDestinationURL: outside
        )

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.githubTemplates, in: items).status == .fail)
        #expect(try item(.ciWorkflow, in: items).status == .fail)
    }

    /// Verifies structural scans do not recurse into symlinked directories.
    @Test func scannerDoesNotTraverseSymlinkedDirectoriesForSwiftAppDetection() throws {
        let repo = try makeTempDir()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoReadinessOutsideApp-\(UUID().uuidString)", isDirectory: true)
        try write("enum FeatureFlag {}\n", to: outside.appendingPathComponent("Services/FeatureFlags.swift"))
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("App"),
            withDestinationURL: outside
        )

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.featureFlagDocumentation, in: items).status == .pass)
    }

    /// Verifies a later complete workflow document can satisfy the check after an incomplete candidate.
    @Test func contributionWorkflowScansAllCandidateDocuments() throws {
        let repo = try makeTempDir()
        try write("# Contributing\nOpen a pull request.\n", to: repo.appendingPathComponent("CONTRIBUTING.md"))
        try write(
            """
            # Conventions

            Start from a GitHub issue, create a feature branch, run tests and CI, then open a pull request.
            """,
            to: repo.appendingPathComponent("docs/wiki/Conventions.md")
        )

        let items = RepoReadinessScanner(repositoryURL: repo).items()

        #expect(try item(.contributionWorkflow, in: items).status == .pass)
        #expect(try item(.contributionWorkflow, in: items).source == "docs/wiki/Conventions.md")
    }

    /// Verifies repository selection persistence and reload behavior use injected defaults.
    @Test func storePersistsRepositorySelectionAndReloadsItems() async throws {
        let repo = try makeTempDir()
        let secondRepo = try makeTempDir()
        try write("# Agent rules\n", to: repo.appendingPathComponent("AGENTS.md"))
        let defaults = MemoryDefaults()

        let store = RepoReadinessStore(defaults: defaults)
        #expect(store.selectedRepositoryURL == nil)
        #expect(store.items.isEmpty)

        store.selectRepository(repo)
        let items = try await waitForItems(in: store)

        #expect(defaults.string(forKey: RepoReadinessStore.repositoryPathKey) == repo.standardizedFileURL.path)
        #expect(items.contains { $0.code == .governance && $0.status == .pass })
        #expect(store.problemCount == items.filter { $0.status != .pass }.count)

        let restoredStore = RepoReadinessStore(defaults: defaults)
        #expect(restoredStore.selectedRepositoryURL?.path == repo.standardizedFileURL.path)

        store.selectRepository(secondRepo)
        #expect(store.items.isEmpty)

        store.clearRepository()
        #expect(store.selectedRepositoryURL == nil)
        #expect(store.items.isEmpty)
        #expect(defaults.string(forKey: RepoReadinessStore.repositoryPathKey) == nil)
    }

    /// Verifies checklist search covers codes, statuses, titles, sources, and remediation hints.
    @Test func itemSearchMatchesChecklistFields() {
        let item = RepoReadinessItem(
            code: .ciWorkflow,
            status: .warn,
            title: "CI workflow",
            detail: "GitHub workflows exist but none obviously run build or tests.",
            source: ".github/workflows",
            remediationHint: "Add a CI workflow that runs the documented build and test commands."
        )

        #expect(item.matches(searchText: "ciWorkflow"))
        #expect(item.matches(searchText: "warn"))
        #expect(item.matches(searchText: "CI workflow"))
        #expect(item.matches(searchText: ".github/workflows"))
        #expect(item.matches(searchText: "documented build"))
        #expect(!item.matches(searchText: "feature flags"))
    }
}
