//
//  SecretsGuard.swift
//  CodingBuddy
//

import Foundation
import LocalAuthentication
import Observation

/// Gatekeeper for secret values: masked by default, revealed only after the
/// user authenticates with Touch ID or the account password. The unlock
/// expires after the duration configured in Settings.
@Observable
final class SecretsGuard {
    /// UserDefaults key for the unlock duration in seconds; -1 keeps the
    /// unlock until the app quits.
    static let unlockDurationKey = "secretsUnlockDuration"
    /// Default reveal window when no explicit preference has been stored.
    static let defaultUnlockDuration: TimeInterval = 300

    private(set) var unlockedUntil: Date?
    /// Recoverable authentication failure shown by the owning view.
    private(set) var lastError: String?
    @ObservationIgnored private var pendingRelock: DispatchWorkItem?
    /// Monotonic revocation generation used to reject authentication results
    /// that complete after an explicit or scheduled lock.
    @ObservationIgnored private var lockGeneration = 0
    /// Injectable system-authentication boundary used by deterministic tests.
    @ObservationIgnored private let authenticate: @Sendable (String) async throws -> Bool

    /// Creates the production gate or a deterministic test gate.
    init(
        authenticate: @escaping @Sendable (String) async throws -> Bool = { reason in
            let context = LAContext()
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        }
    ) {
        self.authenticate = authenticate
    }

    /// Whether secret values may currently be rendered without masking.
    var isUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return unlockedUntil > Date()
    }

    /// Prompts for biometrics or the account password. Returns true and
    /// starts the unlock window on success.
    func requestUnlock() async -> Bool {
        lastError = nil
        let requestedGeneration = lockGeneration
        do {
            let success = try await authenticate(String(localized: "reveal secret values"))
            guard success,
                  !Task.isCancelled,
                  requestedGeneration == lockGeneration
            else { return false }
            unlock()
            return true
        } catch {
            guard requestedGeneration == lockGeneration,
                  !Task.isCancelled,
                  !Self.isSilentCancellation(error) else { return false }
            lastError = String(
                localized: "Authentication could not be completed. Check your Mac authentication settings and try again."
            )
            return false
        }
    }

    /// Clears an authentication message after its owning alert is dismissed.
    func clearError() {
        lastError = nil
    }

    /// Immediately revokes the reveal window and any scheduled relock.
    func lock() {
        lockGeneration &+= 1
        pendingRelock?.cancel()
        pendingRelock = nil
        unlockedUntil = nil
    }

    private func unlock() {
        pendingRelock?.cancel()
        pendingRelock = nil

        let stored = UserDefaults.standard.double(forKey: Self.unlockDurationKey)
        let duration = stored == 0 ? Self.defaultUnlockDuration : stored

        if duration < 0 {
            unlockedUntil = .distantFuture
            return
        }

        unlockedUntil = Date().addingTimeInterval(duration)
        let relock = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.lock() }
        }
        pendingRelock = relock
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: relock)
    }

    /// User- and lifecycle-initiated cancellations need no duplicate app alert.
    private static func isSilentCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoaError = error as NSError
        guard cocoaError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: cocoaError.code) else {
            return false
        }
        return code == .userCancel || code == .appCancel || code == .systemCancel
    }
}
