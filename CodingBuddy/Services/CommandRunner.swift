//
//  CommandRunner.swift
//  CodingBuddy
//

import Foundation

/// Fully separated native process request. No shell command string is accepted.
nonisolated struct CommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let acceptedExitCodes: Set<Int32>

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60,
        acceptedExitCodes: Set<Int32> = [0]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.acceptedExitCodes = acceptedExitCodes
    }
}

/// Captured process output after a successful native invocation.
nonisolated struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var stdoutString: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderrString: String { String(decoding: standardError, as: UTF8.self) }
}

/// Injectable command boundary used by every package provider.
nonisolated protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

/// Safe failures produced before or during a native process invocation.
nonisolated enum CommandRunnerError: LocalizedError, Equatable, Sendable {
    case executableMustBeAbsolute
    case executableUnavailable(String)
    case launchFailed
    case timedOut
    case cancelled
    case unacceptableExit(code: Int32, message: String)

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
        case .unacceptableExit(let code, _):
            String(format: String(localized: "The command failed with exit code %lld."), Int64(code))
        }
    }
}

/// Foundation.Process implementation shared by package inventory and updates.
nonisolated struct FoundationCommandRunner: CommandRunning {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.executableURL.path.hasPrefix("/") else {
            throw CommandRunnerError.executableMustBeAbsolute
        }
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw CommandRunnerError.executableUnavailable(request.executableURL.path)
        }

        let execution = ProcessExecution(request: request)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask { try await execution.start() }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(0.1, request.timeout)))
                    execution.terminate()
                    throw CommandRunnerError.timedOut
                }
                guard let result = try await group.next() else { throw CommandRunnerError.launchFailed }
                group.cancelAll()
                return result
            }
        } onCancel: {
            execution.terminate()
        }
    }
}

/// Owns non-Sendable Foundation process objects behind a lock-protected boundary.
private nonisolated final class ProcessExecution: @unchecked Sendable {
    private let request: CommandRequest
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    init(request: CommandRequest) {
        self.request = request
    }

    func start() async throws -> CommandResult {
        try Task.checkCancellation()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, override in override }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStandardError: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStandardError: true)
        }

        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do {
                try Task.checkCancellation()
                try process.run()
            } catch {
                continuation.resume(throwing: CommandRunnerError.launchFailed)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), toStandardError: false)
        append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), toStandardError: true)
        let output = capturedOutput()

        guard request.acceptedExitCodes.contains(code) else {
            throw CommandRunnerError.unacceptableExit(
                code: code,
                message: String(decoding: output.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return CommandResult(exitCode: code, standardOutput: output.stdout, standardError: output.stderr)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func append(_ data: Data, toStandardError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStandardError { stderr.append(data) } else { stdout.append(data) }
        lock.unlock()
    }

    private func capturedOutput() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
