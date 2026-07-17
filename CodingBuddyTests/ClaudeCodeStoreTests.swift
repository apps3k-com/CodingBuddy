//
//  ClaudeCodeStoreTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

@MainActor
struct ClaudeCodeStoreTests {

    private let settingsFixture = """
    {
      "model": "opus",
      "env": {
        "GITHUB_TOKEN": "secret-a",
        "PLAIN": "value"
      },
      "hooks": { "PostToolUse": [] }
    }
    """

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingBuddyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHome(
        settings: String? = nil, settingsLocal: String? = nil, claudeJSON: String? = nil
    ) throws -> URL {
        let home = try makeTempDir()
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        if let settings {
            try settings.write(
                to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        if let settingsLocal {
            try settingsLocal.write(
                to: claudeDir.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)
        }
        if let claudeJSON {
            try claudeJSON.write(
                to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        return home
    }

    private func makeStore(
        home: URL,
        transactionHook: ((SafeFileWriter.TransactionPoint) throws -> Void)? = nil,
        readLimits: ClaudeCodeStore.ReadLimits = .production
    ) -> ClaudeCodeStore {
        ClaudeCodeStore(
            homeDirectory: home,
            backupDirectory: home.appendingPathComponent("Backups"),
            transactionHook: transactionHook,
            readLimits: readLimits
        )
    }

    /// Starts one asynchronous scan and waits for its generation to publish.
    private func load(_ store: ClaudeCodeStore) async {
        store.reload()
        for _ in 0..<5_000 {
            if store.loadState != .loading { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Claude Code snapshot did not finish loading")
    }

    /// Waits for the reload automatically started by a completed mutation.
    private func waitForMutationReload(_ store: ClaudeCodeStore) async {
        for _ in 0..<5_000 {
            if store.loadState != .loading { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Claude Code mutation reload did not finish")
    }

    /// Minimal immutable snapshot used to drive deterministic lifecycle tests.
    private func snapshot(
        directory: ClaudeCodeStore.SourceAvailability,
        settings: ClaudeCodeStore.SourceAvailability = .missing,
        settingsLocal: ClaudeCodeStore.SourceAvailability = .missing,
        entries: [ClaudeCodeStore.EnvEntry] = []
    ) -> ClaudeCodeStore.Snapshot {
        ClaudeCodeStore.Snapshot(
            sourceStatuses: [
                ClaudeCodeStore.SourceStatus(
                    id: "claude-directory",
                    kind: .claudeDirectory,
                    availability: directory,
                    revealURL: nil
                ),
                ClaudeCodeStore.SourceStatus(
                    id: "settings-settings",
                    kind: .settings(.settings),
                    availability: settings,
                    revealURL: nil
                ),
                ClaudeCodeStore.SourceStatus(
                    id: "settings-settingsLocal",
                    kind: .settings(.settingsLocal),
                    availability: settingsLocal,
                    revealURL: nil
                ),
                ClaudeCodeStore.SourceStatus(
                    id: "claude-state",
                    kind: .claudeState,
                    availability: .missing,
                    revealURL: nil
                ),
            ],
            envEntries: entries,
            servers: [],
            watchURLs: []
        )
    }

    /// Returns the latest classification for one unique source category.
    private func availability(
        _ kind: ClaudeCodeStore.SourceKind,
        in store: ClaudeCodeStore
    ) -> ClaudeCodeStore.SourceAvailability? {
        store.sourceStatuses.first { $0.kind == kind }?.availability
    }

    @Test func initializationPerformsNoIOAndLeavesRealHomeNeutral() async {
        let recorder = ClaudeLoadInvocationRecorder()
        let store = ClaudeCodeStore(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            loadSnapshot: { _ in
                await recorder.recordInvocation()
                return ClaudeCodeStore.Snapshot(
                    sourceStatuses: [], envEntries: [], servers: [], watchURLs: []
                )
            }
        )

        #expect(store.loadState == .notLoaded)
        #expect(store.sidebarState == .neutral)
        #expect(store.sourceStatuses.isEmpty)
        let invocationCount = await recorder.invocationCount
        #expect(invocationCount == 0)
    }

    @Test func asyncLoadPublishesExplicitTransitionsAndActionAvailability() async throws {
        let gate = ClaudeSnapshotGate()
        let store = ClaudeCodeStore(
            homeDirectory: try makeTempDir(),
            loadSnapshot: { _ in await gate.load() }
        )

        store.reload()
        #expect(store.loadState == .loading)
        #expect(store.sidebarState == .neutral)
        #expect(!store.canMutate(.settings))
        await gate.waitForRequestCount(1)
        await gate.resume(
            request: 0,
            with: snapshot(
                directory: .available,
                settings: .refused(.malformedJSON),
                settingsLocal: .available,
                entries: [ClaudeCodeStore.EnvEntry(source: .settingsLocal, key: "SAFE", value: "value")]
            )
        )
        await waitForMutationReload(store)

        #expect(store.loadState == .loaded)
        #expect(store.sidebarState == .available(count: 1))
        #expect(!store.canMutate(.settings))
        #expect(store.canMutate(.settingsLocal))
        #expect(store.firstMutableSource == .settingsLocal)
    }

    @Test func cancelledAndLateLoadsCannotOverwriteANewerGeneration() async throws {
        let gate = ClaudeSnapshotGate()
        let store = ClaudeCodeStore(
            homeDirectory: try makeTempDir(),
            loadSnapshot: { _ in await gate.loadIgnoringCancellation() }
        )
        let newerEntry = ClaudeCodeStore.EnvEntry(source: .settings, key: "NEW", value: "new")

        store.reload()
        await gate.waitForRequestCount(1)
        store.reload()
        await gate.waitForRequestCount(2)
        await gate.resume(
            request: 1,
            with: snapshot(directory: .available, settings: .available, entries: [newerEntry])
        )
        await waitForMutationReload(store)
        #expect(store.envEntries == [newerEntry])

        await gate.resume(request: 0, with: snapshot(directory: .missing))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.loadState == .loaded)
        #expect(store.envEntries == [newerEntry])
        #expect(store.sidebarState == .available(count: 1))
    }

    @Test func cancelledNavigationLoadReturnsToNeutralAndRejectsLateResult() async throws {
        let gate = ClaudeSnapshotGate()
        let store = ClaudeCodeStore(
            homeDirectory: try makeTempDir(),
            loadSnapshot: { _ in await gate.loadIgnoringCancellation() }
        )

        store.reload()
        await gate.waitForRequestCount(1)
        store.cancelLoading()
        await gate.resume(request: 0, with: snapshot(directory: .available, settings: .available))
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.loadState == .notLoaded)
        #expect(store.sidebarState == .neutral)
        #expect(store.sourceStatuses.isEmpty)
    }

    /// Verifies replacement and navigation cancellation reach work beyond the main-actor task.
    @Test func supersededReloadSignalsCancellationToBackgroundLoader() async throws {
        let probe = ClaudeCancellationProbe()
        let store = ClaudeCodeStore(
            homeDirectory: try makeTempDir(),
            loadSnapshot: { request in await probe.load(request) }
        )

        store.reload()
        await probe.waitForRequestCount(1)
        store.reload()
        await probe.waitForRequestCount(2)
        await probe.waitForCancellationCount(1)

        store.cancelLoading()
        await probe.waitForCancellationCount(2)

        #expect(store.loadState == .notLoaded)
        #expect(await probe.cancellationCount == 2)
    }

    @Test func unsafeClaudeDirectoryIsRefusedInsteadOfReportedMissing() async throws {
        let home = try makeTempDir()
        let external = try makeTempDir()
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude"),
            withDestinationURL: external
        )
        let store = makeStore(home: home)
        await load(store)

        #expect(store.loadState == .refused(.unsafePath))
        #expect(store.sidebarState == .refused)
        #expect(availability(.claudeDirectory, in: store) == .refused(.unsafePath))
        #expect(store.firstMutableSource == nil)
    }

    @Test func malformedInvalidUTF8AndOversizedSettingsHaveDistinctRefusals() async throws {
        let limits = ClaudeCodeStore.ReadLimits(
            configurationFileBytes: 64,
            projectMCPFileBytes: 64,
            projectCount: 4,
            projectMCPBytes: 128
        )

        let malformedHome = try makeHome(settings: "{")
        let malformed = makeStore(home: malformedHome, readLimits: limits)
        await load(malformed)
        #expect(availability(.settings(.settings), in: malformed) == .refused(.malformedJSON))

        let utf8Home = try makeHome()
        try Data([0xFF]).write(to: utf8Home.appendingPathComponent(".claude/settings.json"))
        let invalidUTF8 = makeStore(home: utf8Home, readLimits: limits)
        await load(invalidUTF8)
        #expect(availability(.settings(.settings), in: invalidUTF8) == .refused(.invalidUTF8))

        let oversizedHome = try makeHome(settings: String(repeating: " ", count: 65))
        let oversized = makeStore(home: oversizedHome, readLimits: limits)
        await load(oversized)
        #expect(availability(.settings(.settings), in: oversized) == .refused(.tooLarge))
        #expect(!oversized.canMutate(.settings))
    }

    @Test func loadsEnvEntriesFromBothSettingsFiles() async throws {
        let home = try makeHome(
            settings: settingsFixture,
            settingsLocal: #"{ "env": { "LOCAL_ONLY": "l" } }"#
        )
        let store = makeStore(home: home)
        await load(store)

        #expect(store.envEntries.count == 3)
        #expect(store.envEntries.first { $0.key == "GITHUB_TOKEN" }?.source == .settings)
        #expect(store.envEntries.first { $0.key == "LOCAL_ONLY" }?.source == .settingsLocal)
    }

    @Test func updateRewritesOnlyTheTargetValue() async throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)
        await load(store)
        let entry = try #require(store.envEntries.first { $0.key == "GITHUB_TOKEN" })

        store.update(entry, newValue: "secret-b")

        let url = home.appendingPathComponent(".claude/settings.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == settingsFixture.replacingOccurrences(of: "\"secret-a\"", with: "\"secret-b\""))
        #expect(store.lastError == nil)
        // Backup written before the change:
        let backups = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
    }

    @Test func updateRejectsExternallyChangedValues() async throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)
        await load(store)
        let entry = try #require(store.envEntries.first { $0.key == "GITHUB_TOKEN" })

        // Simulate Claude Code rewriting the file behind our back.
        let url = home.appendingPathComponent(".claude/settings.json")
        let external = settingsFixture.replacingOccurrences(of: "\"secret-a\"", with: "\"changed-outside\"")
        try external.write(to: url, atomically: true, encoding: .utf8)

        let saved = store.update(entry, newValue: "secret-b")

        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == external)
    }

    @Test func updateRejectsSameContentSymlinkReplacementAfterSnapshot() async throws {
        let home = try makeHome(settings: settingsFixture)
        let target = home.appendingPathComponent(".claude/settings.json")
        let displaced = home.appendingPathComponent("displaced-settings.json")
        let external = home.appendingPathComponent("external-settings.json")
        try settingsFixture.write(to: external, atomically: true, encoding: .utf8)
        let store = makeStore(
            home: home,
            transactionHook: { point in
                guard case .beforeSnapshotValidation = point else { return }
                try FileManager.default.moveItem(at: target, to: displaced)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            }
        )
        await load(store)
        let entry = try #require(store.envEntries.first { $0.key == "GITHUB_TOKEN" })

        store.update(entry, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try String(contentsOf: displaced, encoding: .utf8) == settingsFixture)
        #expect(try String(contentsOf: external, encoding: .utf8) == settingsFixture)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func updateRejectsFIFOWithoutOpeningIt() async throws {
        let home = try makeHome()
        let target = home.appendingPathComponent(".claude/settings.json")
        guard mkfifo(target.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let store = makeStore(home: home)
        await load(store)
        let entry = ClaudeCodeStore.EnvEntry(
            source: .settings,
            key: "GITHUB_TOKEN",
            value: "secret-a"
        )

        store.update(entry, newValue: "secret-b")

        #expect(store.lastError != nil)
        let type = try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType
        #expect(type == .typeUnknown)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func updateRejectsOversizedSettingsDocument() async throws {
        let home = try makeHome()
        let target = home.appendingPathComponent(".claude/settings.json")
        let oversized = Data(
            repeating: 0x20,
            count: ClaudeCodeStore.maximumConfigurationFileSize + 1
        )
        try oversized.write(to: target)
        let store = makeStore(home: home)
        await load(store)
        let entry = ClaudeCodeStore.EnvEntry(
            source: .settings,
            key: "GITHUB_TOKEN",
            value: "secret-a"
        )

        store.update(entry, newValue: "secret-b")

        #expect(store.lastError != nil)
        #expect(try Data(contentsOf: target).count == oversized.count)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Backups").path))
    }

    @Test func addAndDeleteMutateTheEnvBlock() async throws {
        let home = try makeHome(settings: settingsFixture)
        let store = makeStore(home: home)
        await load(store)

        store.add(key: "NEW_KEY", value: "new", to: .settings)
        await waitForMutationReload(store)
        #expect(store.envEntries.contains { $0.key == "NEW_KEY" && $0.source == .settings })

        let entry = try #require(store.envEntries.first { $0.key == "PLAIN" })
        store.delete(entry)
        await waitForMutationReload(store)
        #expect(!store.envEntries.contains { $0.key == "PLAIN" })
        #expect(store.lastError == nil)
    }

    @Test func addFailsWithoutEnvBlock() async throws {
        let home = try makeHome(settings: #"{ "model": "opus" }"#)
        let store = makeStore(home: home)
        await load(store)

        store.add(key: "X", value: "1", to: .settings)

        #expect(store.lastError != nil)
        #expect(store.envEntries.isEmpty)
    }

    @Test func serversComeFromUserScopeAndExistingProjectsOnly() async throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        try #"{ "mcpServers": { "project-file": { "command": "npx" } } }"#.write(
            to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let claudeJSON = """
        {
          "mcpServers": { "user-server": { "type": "http", "url": "https://u.example/mcp" } },
          "projects": {
            "\(project.path)": {
              "mcpServers": { "project-server": { "command": "npx", "env": { "K": "v" } } }
            },
            "/does/not/exist": {
              "mcpServers": { "stale-server": { "command": "gone" } }
            }
          }
        }
        """
        try claudeJSON.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let store = makeStore(home: home)
        await load(store)

        let names = Set(store.servers.map(\.name))
        #expect(names == ["user-server", "project-server", "project-file"])
        #expect(store.servers.first { $0.name == "user-server" }?.scope == "user")
        #expect(store.servers.first { $0.name == "project-server" }?.scope == project.path)
    }

    @Test func claudeStateFIFOIsRejectedWithoutBlocking() async throws {
        let home = try makeHome(settings: settingsFixture)
        let stateFile = home.appendingPathComponent(".claude.json")
        guard mkfifo(stateFile.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let store = makeStore(home: home)
        await load(store)

        #expect(store.envEntries.count == 2)
        #expect(store.servers.isEmpty)
    }

    @Test func claudeStateSymlinkIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        let external = home.appendingPathComponent("external-claude.json")
        try #"{ "mcpServers": { "leaked": { "command": "outside" } } }"#.write(
            to: external,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".claude.json"),
            withDestinationURL: external
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.isEmpty)
    }

    @Test func oversizedClaudeStateIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        try Data(
            repeating: 0x20,
            count: ClaudeCodeStore.maximumConfigurationFileSize + 1
        ).write(to: home.appendingPathComponent(".claude.json"))

        let store = makeStore(home: home)
        await load(store)

        #expect(store.envEntries.count == 2)
        #expect(store.servers.isEmpty)
    }

    @Test func projectMCPFIFOIsRejectedWithoutBlocking() async throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        let projectMCP = project.appendingPathComponent(".mcp.json")
        guard mkfifo(projectMCP.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try claudeState(for: project).write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.map(\.name) == ["embedded-project"])
    }

    @Test func projectMCPSymlinkIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        let external = home.appendingPathComponent("external-project-mcp.json")
        try #"{ "mcpServers": { "leaked": { "command": "outside" } } }"#.write(
            to: external,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".mcp.json"),
            withDestinationURL: external
        )
        try claudeState(for: project).write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.map(\.name) == ["embedded-project"])
    }

    @Test func oversizedProjectMCPIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        try Data(
            repeating: 0x20,
            count: ClaudeCodeStore.maximumProjectMCPFileSize + 1
        ).write(to: project.appendingPathComponent(".mcp.json"))
        try claudeState(for: project).write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.map(\.name) == ["embedded-project"])
    }

    @Test func symlinkedProjectRootIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        let realProject = try makeTempDir()
        let projectLink = home.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: projectLink, withDestinationURL: realProject)
        try claudeState(for: projectLink).write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.isEmpty)
    }

    @Test func projectRootWithIntermediateSymlinkIsRejected() async throws {
        let home = try makeHome(settings: settingsFixture)
        let realRoot = try makeTempDir()
        let realProject = realRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: realProject, withIntermediateDirectories: false)
        let linkedRoot = home.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let linkedProject = linkedRoot.appendingPathComponent("project", isDirectory: true)
        try claudeState(for: linkedProject).write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = makeStore(home: home)
        await load(store)

        #expect(store.servers.isEmpty)
    }

    @Test func projectEnumerationHonorsInjectedCountCeiling() async throws {
        let home = try makeHome(settings: settingsFixture)
        let first = home.appendingPathComponent("project-a", isDirectory: true)
        let second = home.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let state = """
        {
          "projects": {
            "\(first.path)": { "mcpServers": { "first": { "command": "one" } } },
            "\(second.path)": { "mcpServers": { "second": { "command": "two" } } }
          }
        }
        """
        try state.write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )
        let limits = ClaudeCodeStore.ReadLimits(
            configurationFileBytes: 16 * 1_024,
            projectMCPFileBytes: 1_024,
            projectCount: 1,
            projectMCPBytes: 1_024
        )

        let store = makeStore(home: home, readLimits: limits)
        await load(store)

        #expect(store.servers.map(\.name) == ["first"])
    }

    @Test func projectFilesHonorInjectedAggregateByteCeiling() async throws {
        let home = try makeHome(settings: settingsFixture)
        let first = home.appendingPathComponent("project-a", isDirectory: true)
        let second = home.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let firstMCP = #"{ "mcpServers": { "file-a": { "command": "one" } } }"#
        let secondMCP = #"{ "mcpServers": { "file-b": { "command": "two" } } }"#
        try firstMCP.write(
            to: first.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try secondMCP.write(
            to: second.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let state = """
        {
          "projects": {
            "\(first.path)": { "mcpServers": { "embedded-a": { "command": "one" } } },
            "\(second.path)": { "mcpServers": { "embedded-b": { "command": "two" } } }
          }
        }
        """
        try state.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let limits = ClaudeCodeStore.ReadLimits(
            configurationFileBytes: 16 * 1_024,
            projectMCPFileBytes: 1_024,
            projectCount: 2,
            projectMCPBytes: firstMCP.utf8.count
        )

        let store = makeStore(home: home, readLimits: limits)
        await load(store)

        #expect(Set(store.servers.map(\.name)) == ["embedded-a", "embedded-b", "file-a"])
    }

    @Test(arguments: ["{ malformed", #"{ "other": true }"#])
    func refusedProjectFilesStillConsumeAggregateByteBudget(firstMCP: String) async throws {
        let home = try makeHome(settings: settingsFixture)
        let first = home.appendingPathComponent("project-a", isDirectory: true)
        let second = home.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let secondMCP = #"{ "mcpServers": { "file-b": { "command": "two" } } }"#
        try firstMCP.write(
            to: first.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try secondMCP.write(
            to: second.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let state = """
        {
          "projects": {
            "\(first.path)": { "mcpServers": { "embedded-a": { "command": "one" } } },
            "\(second.path)": { "mcpServers": { "embedded-b": { "command": "two" } } }
          }
        }
        """
        try state.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let limits = ClaudeCodeStore.ReadLimits(
            configurationFileBytes: 16 * 1_024,
            projectMCPFileBytes: 1_024,
            projectCount: 2,
            projectMCPBytes: firstMCP.utf8.count
        )

        let store = makeStore(home: home, readLimits: limits)
        await load(store)

        #expect(Set(store.servers.map(\.name)) == ["embedded-a", "embedded-b"])
        #expect(store.sourceStatuses.contains {
            $0.id == "project-mcp-1" && $0.availability == .refused(.projectByteLimit)
        })
    }

    /// Verifies invalid UTF-8 consumes its bounded reservation before another project read.
    @Test func invalidUTF8ProjectFileConsumesAggregateByteBudget() async throws {
        let home = try makeHome(settings: settingsFixture)
        let first = home.appendingPathComponent("project-a", isDirectory: true)
        let second = home.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data([0xff]).write(to: first.appendingPathComponent(".mcp.json"))
        try #"{ "mcpServers": { "file-b": { "command": "two" } } }"#.write(
            to: second.appendingPathComponent(".mcp.json"),
            atomically: true,
            encoding: .utf8
        )
        let state = """
        {
          "projects": {
            "\(first.path)": { "mcpServers": { "embedded-a": { "command": "one" } } },
            "\(second.path)": { "mcpServers": { "embedded-b": { "command": "two" } } }
          }
        }
        """
        try state.write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )
        let limits = ClaudeCodeStore.ReadLimits(
            configurationFileBytes: 16 * 1_024,
            projectMCPFileBytes: 1_024,
            projectCount: 2,
            projectMCPBytes: 1
        )

        let store = makeStore(home: home, readLimits: limits)
        await load(store)

        #expect(Set(store.servers.map(\.name)) == ["embedded-a", "embedded-b"])
        #expect(store.sourceStatuses.contains {
            $0.id == "project-mcp-0" && $0.availability == .refused(.invalidUTF8)
        })
        #expect(store.sourceStatuses.contains {
            $0.id == "project-mcp-1" && $0.availability == .refused(.projectByteLimit)
        })
    }

    @Test func missingFilesYieldEmptyState() async throws {
        let home = try makeTempDir()
        let store = makeStore(home: home)
        await load(store)
        #expect(!store.directoryExists)
        #expect(store.envEntries.isEmpty)
        #expect(store.servers.isEmpty)
    }

    @Test func duplicateProjectServersDeduplicateWithLocalPrecedence() async throws {
        let home = try makeHome(settings: settingsFixture)
        let project = try makeTempDir()
        // Same name in .mcp.json and in ~/.claude.json's project scope:
        try #"{ "mcpServers": { "shared": { "command": "from-mcp-json" } } }"#.write(
            to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let claudeJSON = """
        {
          "projects": {
            "\(project.path)": {
              "mcpServers": { "shared": { "command": "from-claude-json" } }
            }
          }
        }
        """
        try claudeJSON.write(
            to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let store = makeStore(home: home)
        await load(store)

        let shared = store.servers.filter { $0.name == "shared" }
        #expect(shared.count == 1)
        #expect(shared.first?.command == "from-claude-json")
        #expect(Set(store.servers.map(\.id)).count == store.servers.count)
    }

    /// Claude state fixture whose project-local definition remains usable when
    /// the optional on-disk `.mcp.json` fails a safety check.
    private func claudeState(for project: URL) -> String {
        """
        {
          "projects": {
            "\(project.path)": {
              "mcpServers": {
                "embedded-project": { "command": "embedded" }
              }
            }
          }
        }
        """
    }
}

/// Records whether an injected loader was invoked without touching any filesystem path.
private actor ClaudeLoadInvocationRecorder {
    /// Number of explicit load requests observed by the injected closure.
    private(set) var invocationCount = 0

    /// Records one explicit request.
    func recordInvocation() {
        invocationCount += 1
    }
}

/// Deterministic continuation gate used to complete load generations out of order.
private actor ClaudeSnapshotGate {
    /// Suspended load continuations keyed by request order.
    private var continuations: [Int: CheckedContinuation<ClaudeCodeStore.Snapshot, Never>] = [:]
    /// Number of loader requests that reached the gate.
    private var requestCount = 0

    /// Suspends one injected load until the test publishes its immutable snapshot.
    func load() async -> ClaudeCodeStore.Snapshot {
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    /// Uses a continuation deliberately unaffected by parent task cancellation.
    func loadIgnoringCancellation() async -> ClaudeCodeStore.Snapshot {
        await load()
    }

    /// Waits until the expected number of asynchronous requests reached this actor.
    func waitForRequestCount(_ expected: Int) async {
        for _ in 0..<5_000 {
            if requestCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected Claude snapshot request did not reach the gate")
    }

    /// Completes one selected generation with a test-owned immutable snapshot.
    func resume(request: Int, with snapshot: ClaudeCodeStore.Snapshot) {
        continuations.removeValue(forKey: request)?.resume(returning: snapshot)
    }
}

/// Loader probe that completes only after the store propagates generation cancellation.
private actor ClaudeCancellationProbe {
    /// Number of requests that reached the injected loader.
    private var requestCount = 0
    /// Number of requests that observed their shared cancellation signal.
    private(set) var cancellationCount = 0

    /// Suspends one request until cancellation is visible outside the main actor.
    func load(_ request: ClaudeCodeStore.LoadRequest) async -> ClaudeCodeStore.Snapshot {
        requestCount += 1
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if request.cancellation.isCancelled {
                cancellationCount += 1
                return ClaudeCodeStore.Snapshot(
                    sourceStatuses: [],
                    envEntries: [],
                    servers: [],
                    watchURLs: []
                )
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected Claude loader request to observe cancellation")
        return ClaudeCodeStore.Snapshot(
            sourceStatuses: [],
            envEntries: [],
            servers: [],
            watchURLs: []
        )
    }

    /// Waits for an expected number of loader invocations.
    func waitForRequestCount(_ expected: Int) async {
        for _ in 0..<5_000 {
            if requestCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected Claude cancellation probe request did not start")
    }

    /// Waits for an expected number of requests to observe cancellation.
    func waitForCancellationCount(_ expected: Int) async {
        for _ in 0..<5_000 {
            if cancellationCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected Claude loader did not observe cancellation")
    }
}
