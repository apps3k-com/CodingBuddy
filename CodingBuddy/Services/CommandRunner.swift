//
//  CommandRunner.swift
//  CodingBuddy
//

import Darwin
import Foundation

/// Fully separated native process request. No shell command string is accepted.
nonisolated struct CommandRequest: Equatable, Sendable {
    /// Absolute executable path passed directly to `posix_spawn`.
    let executableURL: URL
    /// Argument vector excluding the executable name.
    let arguments: [String]
    /// Environment overrides merged onto the current process environment.
    let environment: [String: String]
    /// Maximum runtime before the complete process group is terminated.
    let timeout: TimeInterval
    /// Maximum combined bytes retained from standard output and standard error.
    let maximumOutputBytes: Int
    /// Exit statuses that represent a successful invocation.
    let acceptedExitCodes: Set<Int32>

    /// Creates a bounded command request without accepting shell syntax.
    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024,
        acceptedExitCodes: Set<Int32> = [0]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.acceptedExitCodes = acceptedExitCodes
    }
}

/// Captured process output after a successful native invocation.
nonisolated struct CommandResult: Equatable, Sendable {
    /// Normalized status returned by the process leader.
    let exitCode: Int32
    /// Bytes captured from standard output before the process completed.
    let standardOutput: Data
    /// Bytes captured from standard error before the process completed.
    let standardError: Data

    /// Standard output decoded losslessly with UTF-8 replacement characters.
    var stdoutString: String { String(decoding: standardOutput, as: UTF8.self) }
    /// Standard error decoded losslessly with UTF-8 replacement characters.
    var stderrString: String { String(decoding: standardError, as: UTF8.self) }
}

/// Injectable command boundary used by every package provider.
nonisolated protocol CommandRunning: Sendable {
    /// Executes one bounded request or throws a UI-safe command failure.
    func run(_ request: CommandRequest) async throws -> CommandResult
}

/// Asynchronously owns a spawned child until it can be reaped without blocking a caller.
nonisolated protocol CommandProcessReaping: Sendable {
    /// Reports the normalized child status after reaping, or `nil` if ownership was lost.
    func reap(
        processID: pid_t,
        completion: @escaping @Sendable (Int32?) -> Void
    )
}

/// Timing policy for escalating process-group termination to a hard completion deadline.
nonisolated struct CommandTerminationTiming: Sendable {
    /// Delay between SIGTERM and SIGKILL.
    let terminationGrace: TimeInterval
    /// Maximum caller-facing delay after SIGKILL.
    let postKillWait: TimeInterval
    /// Frequency of process-group termination checks.
    let pollInterval: TimeInterval

    /// Production timing that gives cooperative processes a short opportunity to exit.
    static let standard = CommandTerminationTiming(
        terminationGrace: 0.25,
        postKillWait: 0.25,
        pollInterval: 0.01
    )
}

/// Safe failures produced before or during a native process invocation.
nonisolated enum CommandRunnerError: LocalizedError, Equatable, Sendable {
    /// Relative executable paths are rejected before launch.
    case executableMustBeAbsolute
    /// The requested executable is absent or not executable.
    case executableUnavailable(String)
    /// POSIX process or pipe setup failed before a child could run.
    case launchFailed
    /// The configured runtime elapsed and the process group was stopped.
    case timedOut
    /// The awaiting Swift task was cancelled and the process group was stopped.
    case cancelled
    /// Captured stdout and stderr exceeded the request's combined byte budget.
    case outputLimitExceeded(maximumBytes: Int)
    /// The child exited with a status outside the request's accepted set.
    case unacceptableExit(code: Int32)

    /// Localized failure text that never exposes command environment values.
    var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute:
            String(localized: "The executable path must be absolute.")
        case .executableUnavailable(let path):
            String(format: String(localized: "The executable is unavailable: %@"), path)
        case .launchFailed:
            String(localized: "The command could not be started.")
        case .timedOut:
            String(localized: "The command timed out.")
        case .cancelled:
            String(localized: "The command was cancelled.")
        case .outputLimitExceeded:
            String(localized: "The command produced more output than can be safely displayed.")
        case .unacceptableExit(let code):
            String(format: String(localized: "The command failed with exit code %lld."), Int64(code))
        }
    }
}

/// Native process runner that isolates every invocation in its own process group.
nonisolated struct FoundationCommandRunner: CommandRunning {
    private let processReaper: any CommandProcessReaping
    private let terminationTiming: CommandTerminationTiming

    /// Creates a runner with injectable process lifecycle boundaries for deterministic tests.
    init(
        processReaper: (any CommandProcessReaping)? = nil,
        terminationTiming: CommandTerminationTiming = .standard
    ) {
        self.processReaper = processReaper ?? POSIXCommandProcessReaper.shared
        self.terminationTiming = terminationTiming
    }

    /// Runs a command in a dedicated process group with bounded cancellation and output capture.
    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.executableURL.path.hasPrefix("/") else {
            throw CommandRunnerError.executableMustBeAbsolute
        }
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw CommandRunnerError.executableUnavailable(request.executableURL.path)
        }
        guard !Task.isCancelled else { throw CommandRunnerError.cancelled }

        let execution = ProcessExecution(
            request: request,
            processReaper: processReaper,
            terminationTiming: terminationTiming
        )
        return try await withTaskCancellationHandler {
            try await execution.start()
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Owns POSIX process and pipe state on a private serial queue.
private nonisolated final class ProcessExecution: @unchecked Sendable {
    private enum StopReason {
        /// The request exceeded its configured runtime.
        case timedOut
        /// The parent Swift task no longer needs the command.
        case cancelled
        /// The child emitted more bytes than the request permits retaining.
        case outputLimitExceeded(maximumBytes: Int)

        /// Public error corresponding to the internal stop trigger.
        var error: CommandRunnerError {
            switch self {
            case .timedOut: .timedOut
            case .cancelled: .cancelled
            case .outputLimitExceeded(let maximumBytes):
                .outputLimitExceeded(maximumBytes: maximumBytes)
            }
        }
    }

    private let request: CommandRequest
    private let processReaper: any CommandProcessReaping
    private let terminationTiming: CommandTerminationTiming
    private let queue = DispatchQueue(label: "com.apps3k.CodingBuddy.CommandRunner.execution")
    private var continuation: CheckedContinuation<CommandResult, any Error>?
    private var processID: pid_t?
    private var standardOutput = Data()
    private var standardError = Data()
    private var stdoutReader: PipeReader?
    private var stderrReader: PipeReader?
    private var timeoutTimer: DispatchSourceTimer?
    private var terminationTimer: DispatchSourceTimer?
    private var terminationStartedAt: DispatchTime?
    private var killSentAt: DispatchTime?
    private var stopReason: StopReason?
    private var leaderDidExit = false
    private var leaderExitCode: Int32?
    private var isCompletingTermination = false
    private var didFinish = false

    /// Creates one single-use process execution state machine.
    init(
        request: CommandRequest,
        processReaper: any CommandProcessReaping,
        terminationTiming: CommandTerminationTiming
    ) {
        self.request = request
        self.processReaper = processReaper
        self.terminationTiming = terminationTiming
    }

    /// Launches the request and returns without ever depending on pipe EOF.
    func start() async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !didFinish else {
                    continuation.resume(throwing: CommandRunnerError.cancelled)
                    return
                }
                self.continuation = continuation
                launch()
            }
        }
    }

    /// Requests bounded process-tree termination when the awaiting task is cancelled.
    func cancel() {
        queue.async { [self] in requestStop(.cancelled) }
    }

    private func launch() {
        if let stopReason {
            finish(throwing: stopReason.error)
            return
        }

        do {
            let stdoutDescriptors = try makePipe()
            let stderrDescriptors: [Int32]
            do {
                stderrDescriptors = try makePipe()
            } catch {
                closeDescriptors(stdoutDescriptors)
                throw error
            }
            let pid: pid_t
            do {
                pid = try spawn(stdout: stdoutDescriptors, stderr: stderrDescriptors)
            } catch {
                closeDescriptors(stdoutDescriptors)
                closeDescriptors(stderrDescriptors)
                throw error
            }
            processID = pid
            Darwin.close(stdoutDescriptors[1])
            Darwin.close(stderrDescriptors[1])
            stdoutReader = makeReader(descriptor: stdoutDescriptors[0], isStandardError: false)
            stderrReader = makeReader(descriptor: stderrDescriptors[0], isStandardError: true)
            scheduleTimeout()
            waitForExit(of: pid)
        } catch {
            finish(throwing: CommandRunnerError.launchFailed)
        }
    }

    private func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw CommandRunnerError.launchFailed }

        for index in descriptors.indices {
            if descriptors[index] <= STDERR_FILENO {
                let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
                guard duplicate >= 0 else {
                    closeDescriptors(descriptors)
                    throw CommandRunnerError.launchFailed
                }
                Darwin.close(descriptors[index])
                descriptors[index] = duplicate
            }
            guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) == 0 else {
                closeDescriptors(descriptors)
                throw CommandRunnerError.launchFailed
            }
        }
        return descriptors
    }

    private func spawn(stdout: [Int32], stderr: [Int32]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CommandRunnerError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CommandRunnerError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }

        guard
            posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO) == 0,
            posix_spawn_file_actions_addclose(&actions, stdout[0]) == 0,
            posix_spawn_file_actions_addclose(&actions, stderr[0]) == 0,
            posix_spawn_file_actions_addclose(&actions, stdout[1]) == 0,
            posix_spawn_file_actions_addclose(&actions, stderr[1]) == 0,
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CommandRunnerError.launchFailed
        }

        let environment = ProcessInfo.processInfo.environment
            .merging(request.environment) { _, override in override }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let arguments = [request.executableURL.path] + request.arguments
        var pid: pid_t = 0
        let result = withCStringArray(arguments) { argumentPointers in
            withCStringArray(environment) { environmentPointers in
                posix_spawn(
                    &pid,
                    request.executableURL.path,
                    &actions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        guard result == 0, pid > 0 else { throw CommandRunnerError.launchFailed }
        return pid
    }

    private func makeReader(descriptor: Int32, isStandardError: Bool) -> PipeReader {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }

        let reader = PipeReader(descriptor: descriptor, queue: queue) { [weak self] data in
            self?.receive(data, isStandardError: isStandardError) ?? false
        }
        reader.start()
        return reader
    }

    private func scheduleTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0.1, request.timeout))
        timer.setEventHandler { [self] in requestStop(.timedOut) }
        timeoutTimer = timer
        timer.resume()
    }

    private func waitForExit(of pid: pid_t) {
        processReaper.reap(processID: pid) { [self] exitCode in
            queue.async { [self] in
                processDidExit(exitCode: exitCode)
            }
        }
    }

    private func processDidExit(exitCode: Int32?) {
        guard !didFinish else { return }
        guard let exitCode else {
            processBindingWasLost()
            return
        }
        leaderDidExit = true
        leaderExitCode = exitCode
        cancelTimeout()

        if processGroupExists() {
            beginGroupTermination()
            return
        }

        completeAfterGroupTermination()
    }

    private func processBindingWasLost() {
        cancelTimeout()
        cancelTermination()
        closeReaders()
        finish(throwing: CommandRunnerError.launchFailed)
    }

    private func completeAfterGroupTermination() {
        guard !didFinish, !isCompletingTermination else { return }
        isCompletingTermination = true
        cancelTermination()
        drainReaders()
        closeReaders()
        isCompletingTermination = false

        if let stopReason {
            finish(throwing: stopReason.error)
            return
        }
        guard leaderDidExit else { return }
        finishLeaderResult()
    }

    private func finishLeaderResult() {
        guard let exitCode = leaderExitCode else {
            finish(throwing: CommandRunnerError.launchFailed)
            return
        }

        guard request.acceptedExitCodes.contains(exitCode) else {
            finish(throwing: CommandRunnerError.unacceptableExit(code: exitCode))
            return
        }
        finish(returning: CommandResult(
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        ))
    }

    private func requestStop(_ reason: StopReason) {
        guard !didFinish, stopReason == nil else { return }
        stopReason = reason
        cancelTimeout()
        cancelReadersWithoutDraining()
        guard let processID else {
            closeReaders()
            finish(throwing: reason.error)
            return
        }

        if isCompletingTermination { return }
        beginGroupTermination(processID: processID)
    }

    private func beginGroupTermination(processID: pid_t? = nil) {
        guard !didFinish, terminationTimer == nil else { return }
        guard let processID = processID ?? self.processID else {
            completeAfterGroupTermination()
            return
        }
        guard processGroupExists() else {
            completeAfterGroupTermination()
            return
        }

        _ = Darwin.kill(-processID, SIGTERM)
        terminationStartedAt = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: max(0.001, terminationTiming.pollInterval),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [self] in pollGroupTermination(processID: processID) }
        terminationTimer = timer
        timer.resume()
    }

    private func pollGroupTermination(processID: pid_t) {
        guard processGroupExists() else {
            completeAfterGroupTermination()
            return
        }

        let now = DispatchTime.now()
        if let killSentAt {
            if elapsed(from: killSentAt, to: now) >= terminationTiming.postKillWait {
                completeAfterGroupTermination()
            }
            return
        }

        guard let terminationStartedAt,
              elapsed(from: terminationStartedAt, to: now) >= terminationTiming.terminationGrace else {
            return
        }
        _ = Darwin.kill(-processID, SIGKILL)
        killSentAt = now
    }

    private func receive(_ data: Data, isStandardError: Bool) -> Bool {
        guard !didFinish, stopReason == nil else { return false }
        let capturedBytes = standardOutput.count + standardError.count
        let remainingBytes = request.maximumOutputBytes - capturedBytes
        if data.count > remainingBytes {
            if remainingBytes > 0 {
                append(data.prefix(remainingBytes), isStandardError: isStandardError)
            }
            requestStop(.outputLimitExceeded(maximumBytes: request.maximumOutputBytes))
            return false
        }
        append(data, isStandardError: isStandardError)
        return true
    }

    private func append<S: DataProtocol>(_ data: S, isStandardError: Bool) {
        if isStandardError {
            standardError.append(contentsOf: data)
        } else {
            standardOutput.append(contentsOf: data)
        }
    }

    private func processGroupExists() -> Bool {
        guard let processID else { return false }
        if Darwin.kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func drainReaders() {
        stdoutReader?.drain()
        stderrReader?.drain()
    }

    private func closeReaders() {
        drainReaders()
        cancelReadersWithoutDraining()
    }

    private func cancelReadersWithoutDraining() {
        stdoutReader?.cancel()
        stderrReader?.cancel()
        stdoutReader = nil
        stderrReader = nil
    }

    private func cancelTimeout() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
    }

    private func cancelTermination() {
        terminationTimer?.cancel()
        terminationTimer = nil
        terminationStartedAt = nil
        killSentAt = nil
    }

    private func elapsed(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func finish(returning result: CommandResult) {
        guard !didFinish else { return }
        didFinish = true
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finish(throwing error: any Error) {
        guard !didFinish else { return }
        didFinish = true
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}

/// Process-wide child owner that polls with `WNOHANG` and never blocks command completion.
private nonisolated final class POSIXCommandProcessReaper: CommandProcessReaping, @unchecked Sendable {
    /// Shared owner prevents one blocked thread per child that has not become waitable yet.
    static let shared = POSIXCommandProcessReaper()

    private let queue = DispatchQueue(label: "com.apps3k.CodingBuddy.CommandRunner.reaper")
    private let timer: DispatchSourceTimer
    private var completions: [pid_t: @Sendable (Int32?) -> Void] = [:]

    private init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    /// Registers a child for eventual nonblocking reaping.
    func reap(
        processID: pid_t,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        queue.async { [self] in
            let shouldStartPolling = completions.isEmpty
            completions[processID] = completion
            if shouldStartPolling {
                timer.schedule(
                    deadline: .now(),
                    repeating: .milliseconds(10),
                    leeway: .milliseconds(2)
                )
            }
        }
    }

    private func poll() {
        var completed: [(@Sendable (Int32?) -> Void, Int32?)] = []

        for (processID, completion) in completions {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processID, &status, WNOHANG)
            } while result == -1 && errno == EINTR

            if result == processID {
                completions.removeValue(forKey: processID)
                completed.append((completion, decodedExitCode(status)))
            } else if result == -1 {
                completions.removeValue(forKey: processID)
                completed.append((completion, nil))
            }
        }

        if completions.isEmpty {
            timer.schedule(deadline: .distantFuture)
        }
        for (completion, exitCode) in completed {
            completion(exitCode)
        }
    }

    private func decodedExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }
}

/// Non-blocking pipe reader whose descriptor is closed only after cancellation is delivered.
private nonisolated final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let receive: @Sendable (Data) -> Bool

    /// Creates a reader whose callbacks are serialized with process state changes.
    init(
        descriptor: Int32,
        queue: DispatchQueue,
        receive: @escaping @Sendable (Data) -> Bool
    ) {
        self.descriptor = descriptor
        self.receive = receive
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptor) }
    }

    /// Activates the suspended dispatch source exactly once.
    func start() {
        source.resume()
    }

    /// Reads all currently available bytes without waiting for EOF.
    func drain() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                if !receive(Data(buffer.prefix(count))) { return }
            } else if count == -1 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    /// Cancels the source; its cancellation handler owns descriptor closure.
    func cancel() {
        source.cancel()
    }
}

/// Calls a POSIX API with a temporary, null-terminated C string array.
private nonisolated func withCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil { free(pointer) }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
