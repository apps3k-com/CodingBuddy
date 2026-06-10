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
    static let defaultUnlockDuration: TimeInterval = 300

    private(set) var unlockedUntil: Date?
    @ObservationIgnored private var pendingRelock: DispatchWorkItem?

    var isUnlocked: Bool {
        guard let unlockedUntil else { return false }
        return unlockedUntil > Date()
    }

    /// Prompts for biometrics or the account password. Returns true and
    /// starts the unlock window on success.
    func requestUnlock() async -> Bool {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "reveal secret values")
            )
            if success { unlock() }
            return success
        } catch {
            // Cancelled or failed — the system UI already informed the user.
            return false
        }
    }

    func lock() {
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
}
