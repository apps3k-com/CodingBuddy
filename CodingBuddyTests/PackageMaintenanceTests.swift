//
//  PackageMaintenanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct PackageMaintenanceTests {
    @Test func commandRunnerPassesMetacharactersAsLiteralArguments() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let literal = "$(touch \(marker.path))"
        let result = try await FoundationCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal]
        ))

        #expect(result.stdoutString == literal)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func commandRunnerRejectsRelativeExecutablesAndTimesOut() async {
        await #expect(throws: CommandRunnerError.self) {
            try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "printf", relativeTo: URL(fileURLWithPath: "/tmp")),
                arguments: []
            ))
        }
        await #expect(throws: CommandRunnerError.self) {
            try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05
            ))
        }
    }

    @Test func commandRunnerCancelsRunningProcess() async {
        let task = Task {
            try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            ))
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func executableLocatorUsesOverrideAndBuildsPNPMEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "pnpm")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("stub".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let suite = "PackageMaintenanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(executable.path, forKey: PackageExecutablePreference.key(for: .pnpm))

        let installation = try #require(PackageExecutableLocator(
            defaults: defaults,
            homeDirectory: root,
            processEnvironment: ["PATH": "/usr/bin"]
        ).installation(for: .pnpm))
        #expect(installation.executableURL == executable)
        #expect(installation.environment["PNPM_HOME"] == root.path)
        #expect(installation.environment["PATH"] == "\(root.path):/usr/bin")
    }

    @Test func executableLocatorPrefersStandardPNPMHomeForVersionManagedExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let executableDirectory = root.appending(path: ".nvm/versions/node/v24/bin", directoryHint: .isDirectory)
        let pnpmHome = root.appending(path: "Library/pnpm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pnpmHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = executableDirectory.appending(path: "pnpm")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("stub".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let installation = try #require(PackageExecutableLocator(
            homeDirectory: root,
            processEnvironment: ["PATH": "/usr/bin"]
        ).installation(for: .pnpm))
        #expect(installation.environment["PNPM_HOME"] == pnpmHome.path)
    }

    @Test func homebrewFixtureDecodesFormulaCaskPinsAndUnknownFields() async throws {
        let runner = StubCommandRunner(outputs: [
            .success(jsonResult(#"""
            {
              "formulae": [
                {"name":"jq","homepage":"https://jqlang.github.io/jq/","pinned":false,"installed":[{"version":"1.7","installed_on_request":true}],"future":"ignored"},
                {"name":"oniguruma","installed":[{"version":"6.9","installed_on_request":false}]}
              ],
              "casks": [{"token":"warp","version":"1.0","installed":"1.0","auto_updates":true,"pinned":false}]
            }
            """#)),
            .success(jsonResult(#"{"formulae":[{"name":"jq","current_version":"1.8"}],"casks":[]}"#)),
        ])
        let snapshot = try await HomebrewPackageProvider(runner: runner).scan(installation: installation(.homebrew))

        let jq = try #require(snapshot.packages.first { $0.name == "jq" })
        #expect(jq.isDirect)
        #expect(jq.status == .updateAvailable)
        #expect(jq.latestVersion == "1.8")
        #expect(snapshot.packages.first { $0.name == "oniguruma" }?.isDirect == false)
        #expect(snapshot.packages.first { $0.name == "warp" }?.status == .selfUpdating)
    }

    @Test func npmAndPNPMFixturesDecodeMajorAndCompatibleTargets() async throws {
        let npmRunner = StubCommandRunner(outputs: [
            .success(jsonResult(#"{"dependencies":{"typescript":{"version":"5.4.0","repository":{"url":"https://github.com/microsoft/TypeScript.git"}},"eslint":{"version":"9.1.0"}}}"#)),
            .success(jsonResult(#"{"typescript":{"current":"5.4.0","wanted":"5.5.0","latest":"6.0.0"},"eslint":{"current":"9.1.0","wanted":"9.2.0","latest":"9.3.0"}}"#)),
        ])
        let npm = try await NPMPackageProvider(runner: npmRunner).scan(installation: installation(.npm))
        let typescript = try #require(npm.packages.first { $0.name == "typescript" })
        #expect(typescript.status == .majorUpdateAvailable)
        #expect(typescript.targetVersion(for: .compatible) == "5.5.0")
        #expect(typescript.targetVersion(for: .latest) == "6.0.0")
        #expect(npm.packages.first { $0.name == "eslint" }?.status == .updateAvailable)

        let pnpmRunner = StubCommandRunner(outputs: [
            .success(jsonResult(#"[{"dependencies":{"pnpm":{"version":"9.0.0"}}}]"#)),
            .success(jsonResult(#"[{"name":"pnpm","current":"9.0.0","wanted":"9.1.0","latest":"10.0.0","unknown":true}]"#)),
        ])
        let pnpm = try await PNPMPackageProvider(runner: pnpmRunner).scan(installation: installation(.pnpm))
        #expect(pnpm.packages.first?.latestVersion == "10.0.0")
    }

    @Test func emptyProviderInventoriesAreValidSnapshots() async throws {
        let runner = StubCommandRunner(outputs: [
            .success(jsonResult(#"{"dependencies":{}}"#)),
            .success(jsonResult("{}")),
        ])
        let snapshot = try await NPMPackageProvider(runner: runner).scan(installation: installation(.npm))
        #expect(snapshot.packages.isEmpty)
    }

    @Test func emptyOutdatedOutputWithFailureExitCodeIsRejected() async {
        let runner = StubCommandRunner(outputs: [
            .success(jsonResult(#"{"dependencies":{}}"#)),
            .success(CommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())),
        ])
        await #expect(throws: PackageProviderError.self) {
            try await NPMPackageProvider(runner: runner).scan(installation: installation(.npm))
        }
    }

    @Test func mixedProviderFailureKeepsSuccessfulSnapshot() async {
        let good = FixturePackageProvider(manager: .npm, result: .success(snapshot(.npm, packages: [])))
        let bad = FixturePackageProvider(manager: .pnpm, result: .failure(PackageProviderError.invalidResponse(.pnpm)))
        let service = PackageMaintenanceService(
            providers: [good, bad],
            locator: StubLocator(installations: [.npm: installation(.npm), .pnpm: installation(.pnpm)])
        )
        let result = await service.scan()
        #expect(result.snapshots.map(\.installation.manager) == [.npm])
        #expect(result.issues.map(\.manager) == [.pnpm])
    }

    @Test func updatePlansSeparateCompatibleLatestAndRejectPinnedPackages() throws {
        let package = nodePackage(name: "typescript", status: .majorUpdateAvailable)
        let provider = FixturePackageProvider(manager: .npm, result: .success(snapshot(.npm, packages: [package])))
        let service = PackageMaintenanceService(
            providers: [provider],
            locator: StubLocator(installations: [.npm: installation(.npm)])
        )

        let compatible = try service.plan(packages: [package], mode: .compatible)
        let latest = try service.plan(packages: [package], mode: .latest)
        #expect(compatible.items.first?.command.arguments.last == "typescript@2.0.0")
        #expect(latest.items.first?.command.arguments.last == "typescript@3.0.0")

        let pinned = nodePackage(name: "pinned", status: .pinned)
        #expect(throws: PackageProviderError.self) {
            try service.plan(packages: [pinned], mode: .compatible)
        }
    }

    @Test func homebrewPlanUsesDocumentedDryRunBeforeUpgrade() throws {
        let package = InstalledPackage(
            manager: .homebrew,
            kind: .cask,
            name: "tool",
            installedVersion: "1",
            wantedVersion: "2",
            latestVersion: "2",
            isDirect: true,
            status: .updateAvailable,
            homepageURL: nil,
            repositoryURL: nil,
            installationID: installation(.homebrew).id
        )
        let service = PackageMaintenanceService(
            providers: [HomebrewPackageProvider(runner: StubCommandRunner(outputs: []))],
            locator: StubLocator(installations: [.homebrew: installation(.homebrew)])
        )
        let item = try #require(service.plan(packages: [package], mode: .compatible).items.first)
        #expect(item.previewCommand?.arguments == ["upgrade", "--dry-run", "--cask", "tool"])
        #expect(item.command.arguments == ["upgrade", "--cask", "tool"])
    }

    @Test func storeExecutesConfirmedPlanSequentiallyAndKeepsPartialResults() async throws {
        let first = nodePackage(name: "first", status: .updateAvailable)
        let second = nodePackage(name: "second", status: .updateAvailable)
        let provider = FixturePackageProvider(
            manager: .npm,
            result: .success(snapshot(.npm, packages: [first, second]))
        )
        let updateRunner = StubCommandRunner(outputs: [
            .success(CommandResult(exitCode: 0, standardOutput: Data("done".utf8), standardError: Data())),
            .failure(CommandRunnerError.unacceptableExit(code: 1, message: "failed")),
        ])
        let store = PackageMaintenanceStore(
            service: PackageMaintenanceService(
                providers: [provider],
                locator: StubLocator(installations: [.npm: installation(.npm)])
            ),
            runner: updateRunner,
            releaseNotesProvider: StubReleaseNotesProvider()
        )

        store.reload()
        await waitUntil { store.state == .loaded }
        store.selection = [first.id, second.id]
        store.prepareUpdatePlan()
        await waitUntil { store.pendingPlan != nil }
        #expect(store.pendingPlan?.items.count == 2)
        store.confirmPendingPlan()
        await waitUntil { store.updateEvents.contains { $0.state == .failed } && store.state == .loaded }

        #expect(store.updateEvents.map(\.state) == [.succeeded, .failed])
        let requests = await updateRunner.requests
        #expect(requests.map { $0.arguments.last } == ["first@2.0.0", "second@2.0.0"])
    }

    @Test func cancellingUpdatesStopsQueuedPackagesWithoutRollback() async throws {
        let first = nodePackage(name: "first", status: .updateAvailable)
        let second = nodePackage(name: "second", status: .updateAvailable)
        let provider = FixturePackageProvider(
            manager: .npm,
            result: .success(snapshot(.npm, packages: [first, second]))
        )
        let updateRunner = CancellableCommandRunner()
        let store = PackageMaintenanceStore(
            service: PackageMaintenanceService(
                providers: [provider],
                locator: StubLocator(installations: [.npm: installation(.npm)])
            ),
            runner: updateRunner,
            releaseNotesProvider: StubReleaseNotesProvider()
        )

        store.reload()
        await waitUntil { store.state == .loaded }
        store.selection = [first.id, second.id]
        store.prepareUpdatePlan()
        await waitUntil { store.pendingPlan != nil }
        store.confirmPendingPlan()
        await waitUntil { store.updateEvents.first?.state == .running }
        store.cancelUpdates()
        await waitUntil { store.state == .loaded && store.updateEvents.allSatisfy { $0.state == .cancelled } }

        #expect(await updateRunner.requestCount == 1)
        #expect(store.updateEvents.map(\.state) == [.cancelled, .cancelled])
    }

    @Test func releaseNotesPreferMatchingGitHubReleaseAndFallbackToRepository() async throws {
        let transport = StubGitHubTransport(statusCode: 200, body: #"{"tag_name":"v3.0.0","name":"Version 3","body":"Changes","html_url":"https://github.com/acme/tool/releases/tag/v3.0.0"}"#)
        let provider = GitHubPackageReleaseNotesProvider(transport: transport)
        let notes = await provider.releaseNotes(for: nodePackage(
            name: "tool",
            status: .majorUpdateAvailable,
            repositoryURL: URL(string: "git+https://github.com/acme/tool.git")
        ), targetVersion: "3.0.0")
        #expect(notes?.title == "Version 3")
        #expect((await transport.requestedURLs).first?.path == "/repos/acme/tool/releases/tags/v3.0.0")

        let missing = GitHubPackageReleaseNotesProvider(transport: StubGitHubTransport(statusCode: 404, body: "{}"))
        let fallback = await missing.releaseNotes(for: nodePackage(
            name: "tool",
            status: .majorUpdateAvailable,
            repositoryURL: URL(string: "https://github.com/acme/tool")
        ), targetVersion: "3.0.0")
        #expect(fallback?.sourceURL.absoluteString == "https://github.com/acme/tool")
    }

    @Test func nodeReleaseNotesResolveRepositoryLazilyFromRegistry() async {
        let runner = StubCommandRunner(outputs: [
            .success(jsonResult(#"{"repository":{"url":"git+https://github.com/acme/tool.git"},"homepage":"https://example.com"}"#)),
        ])
        let transport = StubGitHubTransport(
            statusCode: 200,
            body: #"{"tag_name":"v3.0.0","name":"Version 3","body":null,"html_url":"https://github.com/acme/tool/releases/tag/v3.0.0"}"#
        )
        let provider = GitHubPackageReleaseNotesProvider(
            transport: transport,
            locator: StubLocator(installations: [.npm: installation(.npm)]),
            runner: runner
        )

        let notes = await provider.releaseNotes(
            for: nodePackage(name: "tool", status: .majorUpdateAvailable),
            targetVersion: "3.0.0"
        )
        #expect(notes?.title == "Version 3")
        #expect((await runner.requests).first?.arguments == ["view", "tool", "repository", "homepage", "--json"])
    }
}

private func installation(_ manager: PackageManagerKind) -> PackageManagerInstallation {
    PackageManagerInstallation(
        manager: manager,
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        environment: manager == .pnpm ? ["PNPM_HOME": "/tmp/pnpm"] : [:],
        isWritable: true
    )
}

private func snapshot(_ manager: PackageManagerKind, packages: [InstalledPackage]) -> ProviderSnapshot {
    ProviderSnapshot(installation: installation(manager), packages: packages, scannedAt: Date(timeIntervalSince1970: 1))
}

private func nodePackage(
    name: String,
    status: PackageStatus,
    repositoryURL: URL? = nil
) -> InstalledPackage {
    InstalledPackage(
        manager: .npm,
        kind: .nodePackage,
        name: name,
        installedVersion: "1.0.0",
        wantedVersion: "2.0.0",
        latestVersion: "3.0.0",
        isDirect: true,
        status: status,
        homepageURL: nil,
        repositoryURL: repositoryURL,
        installationID: installation(.npm).id
    )
}

private func jsonResult(_ string: String) -> CommandResult {
    CommandResult(exitCode: 0, standardOutput: Data(string.utf8), standardError: Data())
}

private enum StubCommandOutput: Sendable {
    case success(CommandResult)
    case failure(any Error & Sendable)
}

private actor StubCommandRunner: CommandRunning {
    private var outputs: [StubCommandOutput]
    private(set) var requests: [CommandRequest] = []

    init(outputs: [StubCommandOutput]) { self.outputs = outputs }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        guard !outputs.isEmpty else { throw CommandRunnerError.launchFailed }
        switch outputs.removeFirst() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
}

private actor CancellableCommandRunner: CommandRunning {
    private(set) var requestCount = 0

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requestCount += 1
        try await Task.sleep(for: .seconds(5))
        return CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

private struct StubLocator: ExecutableLocating {
    let installations: [PackageManagerKind: PackageManagerInstallation]
    func installation(for manager: PackageManagerKind) -> PackageManagerInstallation? { installations[manager] }
}

private struct FixturePackageProvider: PackageProvider {
    let manager: PackageManagerKind
    let result: Result<ProviderSnapshot, PackageProviderError>

    func scan(installation: PackageManagerInstallation) async throws -> ProviderSnapshot { try result.get() }

    func updateRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest {
        guard let target = package.targetVersion(for: mode) else { throw PackageProviderError.unavailableTarget }
        return CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["install", "--global", "\(package.name)@\(target)"],
            environment: installation.environment
        )
    }
}

private struct StubReleaseNotesProvider: ReleaseNotesProviding {
    func releaseNotes(for package: InstalledPackage, targetVersion: String) async -> PackageReleaseNotes? { nil }
}

private actor StubGitHubTransport: GitHubTransport {
    let statusCode: Int
    let body: String
    private(set) var requestedURLs: [URL] = []

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requestedURLs.append(url)
        return (
            Data(body.utf8),
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor private func waitUntil(
    timeoutIterations: Int = 200,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<timeoutIterations {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
