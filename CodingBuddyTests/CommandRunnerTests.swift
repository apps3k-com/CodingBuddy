//
//  CommandRunnerTests.swift
//  CodingBuddyTests
//

import Darwin
import Foundation
import Testing
@testable import CodingBuddy

struct CommandRunnerTests {
    /// Verifies caller-controlled limits cannot disable process resource bounds.
    @Test func requestNormalizesInvalidAndExcessiveResourceLimits() {
        let nonFinite = CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            timeout: .infinity,
            maximumOutputBytes: .max
        )
        #expect(nonFinite.timeout == CommandRequest.maximumTimeout)
        #expect(nonFinite.maximumOutputBytes == CommandRequest.maximumOutputByteCount)

        let nonPositive = CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            timeout: -.infinity,
            maximumOutputBytes: .min
        )
        #expect(nonPositive.timeout > 0)
        #expect(nonPositive.maximumOutputBytes == 1)
    }

    @Test func relativeFileURLIsRejectedBeforeItsResolvedPathCanBeUsed() async {
        let relativeURL = URL(fileURLWithPath: "bin/sh")
        #expect(relativeURL.baseURL != nil)
        #expect(relativeURL.path.hasPrefix("/"))

        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: relativeURL,
                arguments: []
            ))
            Issue.record("Expected the original relative file URL to be rejected")
        } catch let error as CommandRunnerError {
            #expect(error == .executableMustBeAbsolute)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
    }

    @Test func nonFileURLWithAbsolutePathIsRejected() async throws {
        let remoteURL = try #require(URL(string: "https://example.com/bin/sh"))
        #expect(remoteURL.path == "/bin/sh")

        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: remoteURL,
                arguments: []
            ))
            Issue.record("Expected the non-file URL to be rejected")
        } catch let error as CommandRunnerError {
            #expect(error == .executableMustBeAbsolute)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
    }

    @Test func embeddedNULInArgumentFailsBeforeLaunch() async {
        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: ["safe\0truncated"]
            ))
            Issue.record("Expected the NUL-containing argument to be rejected")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
    }

    @Test func embeddedNULInEnvironmentFailsBeforeLaunch() async {
        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ["CODING_BUDDY_TEST": "safe\0truncated"]
            ))
            Issue.record("Expected the NUL-containing environment value to be rejected")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
    }

    /// Environment names must remain unambiguous when encoded as POSIX `name=value` entries.
    @Test func emptyOrEqualsBearingEnvironmentNamesFailBeforeLaunch() async {
        for environment in [["": "value"], ["SAFE=INJECTED": "value"]] {
            do {
                _ = try await FoundationCommandRunner().run(CommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    environment: environment
                ))
                Issue.record("Expected the malformed environment name to be rejected")
            } catch let error as CommandRunnerError {
                #expect(error == .launchFailed)
            } catch {
                Issue.record("Expected CommandRunnerError, got \(error)")
            }
        }
    }

    @Test func cStringAllocationFailureFailsBeforeSpawn() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "CommandRunnerAllocationMarker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = FoundationCommandRunner(cStringAllocator: FailingAfterOneCStringAllocator())

        do {
            _ = try await runner.run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path]
            ))
            Issue.record("Expected C-string allocation failure to abort launch")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func nonblockingPipeSetupFailureFailsBeforeSpawn() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "CommandRunnerPipeMarker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = FoundationCommandRunner(pipeConfigurator: FailingCommandPipeConfigurator())

        do {
            _ = try await runner.run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf launched > \"$1\"", "fixture", marker.path]
            ))
            Issue.record("Expected nonblocking pipe setup failure to abort launch")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func lostProcessBindingTerminatesGroupBeforeReturning() async throws {
        let reaper = LostBindingCommandProcessReaper()
        defer { reaper.forceCleanup() }
        let runner = FoundationCommandRunner(
            processReaper: reaper,
            terminationTiming: .fastTest
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await runner.run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"],
                timeout: 30
            ))
            Issue.record("Expected the lost process binding to fail")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        }

        let processID = try #require(reaper.processID)
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await reaper.reapTerminatedChild())
        #expect(await waitUntilProcessGroupExits(processID))
    }

    @Test(arguments: OutputFloodStream.allCases)
    func combinedOutputLimitStopsFloodingProcessGroup(stream: OutputFloodStream) async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        payload='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        while :; do
          case "$2" in
            stdout) printf '%s' "$payload" ;;
            stderr) printf '%s' "$payload" >&2 ;;
            mixed)
              printf '%s' "$payload"
              printf '%s' "$payload" >&2
              ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let maximumOutputBytes = 1_024

        do {
            _ = try await FoundationCommandRunner().run(fixture.request(
                timeout: 5,
                maximumOutputBytes: maximumOutputBytes,
                additionalArguments: [stream.rawValue]
            ))
            Issue.record("Expected output capture to exceed its byte limit")
        } catch let error as CommandRunnerError {
            #expect(error == .outputLimitExceeded(maximumBytes: maximumOutputBytes))
        }

        let groupID = try await fixture.groupID()
        defer { killProcessGroup(groupID) }
        #expect(await waitUntilProcessGroupExits(groupID))
    }

    @Test func outputLimitExceededHasSafeLocalizedDescription() {
        let maximumOutputBytes = 1_024
        let error = CommandRunnerError.outputLimitExceeded(maximumBytes: maximumOutputBytes)
        let description = error.localizedDescription

        #expect(error.errorDescription != nil)
        #expect(!description.isEmpty)
        #expect(!description.contains("CommandRunnerError"))
        #expect(!description.contains("outputLimitExceeded"))
        #expect(!description.contains(String(maximumOutputBytes)))
    }

    @Test func childDoesNotInheritUnrelatedOpenDescriptor() async throws {
        let originalDescriptor = Darwin.open("/dev/null", O_RDONLY)
        #expect(originalDescriptor >= 0)
        let sentinelDescriptor = fcntl(originalDescriptor, F_DUPFD, 100)
        Darwin.close(originalDescriptor)
        #expect(sentinelDescriptor >= 100)
        guard sentinelDescriptor >= 100 else { return }
        defer { Darwin.close(sentinelDescriptor) }
        #expect(fcntl(sentinelDescriptor, F_SETFD, 0) == 0)

        let fixture = try CommandFixture(script: #"""
        if [ -e "/dev/fd/$2" ]; then
          exit 42
        fi
        exit 0
        """#)
        defer { fixture.remove() }

        let result = try await FoundationCommandRunner().run(fixture.request(
            timeout: 2,
            additionalArguments: [String(sentinelDescriptor)]
        ))

        #expect(result.exitCode == 0)
        #expect(fcntl(sentinelDescriptor, F_GETFD) >= 0)
    }

    @Test func timeoutKillsSIGTERMResistantProcessGroup() async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        (
          trap '' TERM
          while :; do /bin/sleep 1; done
        ) &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$1"
        wait "$child"
        """#)
        defer { fixture.remove() }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await FoundationCommandRunner().run(fixture.request(timeout: 0.15))
            Issue.record("Expected the command to time out")
        } catch let error as CommandRunnerError {
            #expect(error == .timedOut)
        }
        let elapsed = started.duration(to: clock.now)
        let processes = try await fixture.processes()
        defer { processes.killGroup() }

        #expect(elapsed < .seconds(2))
        #expect(await processes.waitUntilGroupExits())
    }

    @Test func cancellationKillsSIGTERMResistantProcessGroup() async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        (
          trap '' TERM
          while :; do /bin/sleep 1; done
        ) &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$1"
        wait "$child"
        """#)
        defer { fixture.remove() }

        let task = Task {
            try await FoundationCommandRunner().run(fixture.request(timeout: 30))
        }
        defer { task.cancel() }
        let processes = try await fixture.processes()
        defer { processes.killGroup() }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the command to be cancelled")
        } catch let error as CommandRunnerError {
            #expect(error == .cancelled)
        }
        #expect(await processes.waitUntilGroupExits())
    }

    @Test func successfulLeaderKillsSIGTERMResistantDescendantBeforeReturning() async throws {
        let fixture = try CommandFixture(script: #"""
        (
          trap '' TERM
          while :; do /bin/sleep 1; done
        ) &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$1"
        exit 0
        """#)
        defer { fixture.remove() }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await FoundationCommandRunner().run(fixture.request(timeout: 2))
        let elapsed = started.duration(to: clock.now)
        let processes = try await fixture.processes()
        defer { processes.killGroup() }

        #expect(result.exitCode == 0)
        #expect(elapsed < .seconds(1))
        #expect(await processes.waitUntilGroupExits())
    }

    @Test func unacceptableExitDoesNotRetainRawStandardError() async {
        let secret = "credential-\(UUID().uuidString)"

        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"$1\" >&2; exit 7", "fixture", secret],
                timeout: 2
            ))
            Issue.record("Expected an unacceptable exit status")
        } catch let error as CommandRunnerError {
            #expect(error == .unacceptableExit(code: 7))
            #expect(!String(reflecting: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        } catch {
            Issue.record("Expected CommandRunnerError, got \(error)")
        }
    }

    @Test func executableWithInvalidFormatFailsLaunchWithoutHanging() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CommandRunnerTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "invalid-executable")
        try Data("not a native executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        do {
            _ = try await FoundationCommandRunner().run(CommandRequest(
                executableURL: executable,
                arguments: [],
                timeout: 0.2
            ))
            Issue.record("Expected launch to fail")
        } catch let error as CommandRunnerError {
            #expect(error == .launchFailed)
        }
    }

    @Test func timeoutReturnsByHardDeadlineWhileLeaderReapingIsDeferred() async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        while :; do /bin/sleep 1; done
        """#)
        defer { fixture.remove() }
        let reaper = DeferredCommandProcessReaper()
        defer { reaper.killReapAndComplete() }
        let runner = FoundationCommandRunner(
            processReaper: reaper,
            terminationTiming: .fastTest
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await runner.run(fixture.request(timeout: 0.1))
            Issue.record("Expected the command to time out")
        } catch let error as CommandRunnerError {
            #expect(error == .timedOut)
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(reaper.hasPendingReap)
    }

    @Test func cancellationReturnsByHardDeadlineWhileLeaderReapingIsDeferred() async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        while :; do /bin/sleep 1; done
        """#)
        defer { fixture.remove() }
        let reaper = DeferredCommandProcessReaper()
        defer { reaper.killReapAndComplete() }
        let runner = FoundationCommandRunner(
            processReaper: reaper,
            terminationTiming: .fastTest
        )
        let task = Task { try await runner.run(fixture.request(timeout: 30)) }
        defer { task.cancel() }
        _ = try await fixture.groupID()

        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the command to be cancelled")
        } catch let error as CommandRunnerError {
            #expect(error == .cancelled)
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(reaper.hasPendingReap)
    }

    @Test func outputOverflowReturnsByHardDeadlineWhileLeaderReapingIsDeferred() async throws {
        let fixture = try CommandFixture(script: #"""
        trap '' TERM
        printf '%s\n' "$$" > "$1"
        payload='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        while :; do printf '%s' "$payload"; done
        """#)
        defer { fixture.remove() }
        let reaper = DeferredCommandProcessReaper()
        defer { reaper.killReapAndComplete() }
        let runner = FoundationCommandRunner(
            processReaper: reaper,
            terminationTiming: .fastTest
        )
        let maximumOutputBytes = 1_024

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await runner.run(fixture.request(
                timeout: 5,
                maximumOutputBytes: maximumOutputBytes
            ))
            Issue.record("Expected output capture to exceed its byte limit")
        } catch let error as CommandRunnerError {
            #expect(error == .outputLimitExceeded(maximumBytes: maximumOutputBytes))
        }

        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(reaper.hasPendingReap)
    }

    @Test func ordinaryExitIsReapedBeforeCompletion() async throws {
        let fixture = try CommandFixture(script: #"""
        printf '%s\n' "$$" > "$1"
        exit 0
        """#)
        defer { fixture.remove() }

        let result = try await FoundationCommandRunner().run(fixture.request(timeout: 2))
        let processID = try await fixture.groupID()
        var status: Int32 = 0
        errno = 0
        let waitResult = waitpid(processID, &status, WNOHANG)
        let waitError = errno

        #expect(result.exitCode == 0)
        #expect(waitResult == -1)
        #expect(waitError == ECHILD)
    }
}

private extension CommandTerminationTiming {
    static let fastTest = CommandTerminationTiming(
        terminationGrace: 0.02,
        postKillWait: 0.02,
        pollInterval: 0.002
    )
}

private nonisolated final class DeferredCommandProcessReaper: CommandProcessReaping, @unchecked Sendable {
    private struct PendingReap {
        let processID: pid_t
        let completion: @Sendable (Int32?) -> Void
    }

    private let lock = NSLock()
    private var pendingReap: PendingReap?

    var hasPendingReap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingReap != nil
    }

    func reap(
        processID: pid_t,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        lock.lock()
        pendingReap = PendingReap(processID: processID, completion: completion)
        lock.unlock()
    }

    func killReapAndComplete() {
        lock.lock()
        let pendingReap = pendingReap
        self.pendingReap = nil
        lock.unlock()
        guard let pendingReap else { return }

        if pendingReap.processID > 1 {
            _ = Darwin.kill(-pendingReap.processID, SIGKILL)
        }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pendingReap.processID, &status, 0)
        } while result == -1 && errno == EINTR
        pendingReap.completion(result == pendingReap.processID ? decodedExitCode(status) : nil)
    }

    private func decodedExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }
}

private nonisolated final class FailingAfterOneCStringAllocator: CommandCStringAllocating, @unchecked Sendable {
    private let lock = NSLock()
    private var allocationCount = 0

    /// Exercises cleanup of one successful allocation before simulating exhaustion.
    func duplicate(_ value: String) -> UnsafeMutablePointer<CChar>? {
        lock.withLock {
            allocationCount += 1
            return allocationCount == 1 ? strdup(value) : nil
        }
    }
}

private nonisolated struct FailingCommandPipeConfigurator: CommandPipeConfiguring {
    /// Simulates an `fcntl` failure while the pipe is still parent-owned.
    func configureNonBlocking(_ descriptor: Int32) -> Bool {
        false
    }
}

private nonisolated final class LostBindingCommandProcessReaper: CommandProcessReaping, @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcessID: pid_t?

    /// Process identifier captured from the launch before binding loss is reported.
    var processID: pid_t? {
        lock.withLock { storedProcessID }
    }

    /// Reports lost ownership immediately while preserving the identifier for cleanup assertions.
    func reap(
        processID: pid_t,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        lock.withLock { storedProcessID = processID }
        completion(nil)
    }

    /// Reaps the leader after the runner's bounded group-termination sequence.
    func reapTerminatedChild() async -> Bool {
        guard let processID else { return false }
        for _ in 0..<200 {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processID, &status, WNOHANG)
            } while result == -1 && errno == EINTR
            if result == processID || (result == -1 && errno == ECHILD) { return true }
            if result == -1 { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Prevents a failed assertion from leaking the injected child beyond the test.
    func forceCleanup() {
        guard let processID else { return }
        _ = Darwin.kill(-processID, SIGKILL)
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processID, &status, 0)
        } while result == -1 && errno == EINTR
    }
}

private struct CommandFixture {
    let directory: URL
    let script: URL
    let processFile: URL

    init(script source: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CommandRunnerTests-" + UUID().uuidString, directoryHint: .isDirectory)
        script = directory.appending(path: "fixture.sh")
        processFile = directory.appending(path: "processes.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: script)
    }

    func request(
        timeout: TimeInterval,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024,
        additionalArguments: [String] = []
    ) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, processFile.path] + additionalArguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    func groupID() async throws -> pid_t {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: processFile, encoding: .utf8),
               let identifier = contents.split(whereSeparator: \.isWhitespace).first,
               let groupID = pid_t(identifier) {
                return groupID
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CommandRunnerTestError.processIdentifiersUnavailable
    }

    func processes() async throws -> FixtureProcesses {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: processFile, encoding: .utf8) {
                let identifiers = contents.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                if identifiers.count == 2 {
                    return FixtureProcesses(groupID: identifiers[0], childID: identifiers[1])
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CommandRunnerTestError.processIdentifiersUnavailable
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FixtureProcesses {
    let groupID: pid_t
    let childID: pid_t

    var groupExists: Bool {
        if Darwin.kill(-groupID, 0) == 0 { return true }
        return errno == EPERM
    }

    func waitUntilGroupExits() async -> Bool {
        for _ in 0..<200 {
            if !groupExists { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !groupExists
    }

    func killGroup() {
        guard groupID > 1 else { return }
        _ = Darwin.kill(-groupID, SIGKILL)
    }
}

private nonisolated enum CommandRunnerTestError: Error {
    case processIdentifiersUnavailable
}

nonisolated enum OutputFloodStream: String, CaseIterable, Sendable {
    case stdout
    case stderr
    case mixed
}

private func processGroupExists(_ groupID: pid_t) -> Bool {
    if Darwin.kill(-groupID, 0) == 0 { return true }
    return errno == EPERM
}

private func waitUntilProcessGroupExits(_ groupID: pid_t) async -> Bool {
    for _ in 0..<200 {
        if !processGroupExists(groupID) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !processGroupExists(groupID)
}

private func killProcessGroup(_ groupID: pid_t) {
    guard groupID > 1 else { return }
    _ = Darwin.kill(-groupID, SIGKILL)
}
