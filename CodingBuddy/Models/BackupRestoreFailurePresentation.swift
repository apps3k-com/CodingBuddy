//
//  BackupRestoreFailurePresentation.swift
//  CodingBuddy
//

import Foundation

/// Structured restore failure retained across navigation until the user reviews it.
nonisolated struct BackupRestoreFailurePresentation: Hashable {
    /// Best-known outcome of a failed restore transaction.
    enum Outcome: Hashable {
        /// The requested backup content was not committed to the target.
        case notApplied
        /// The requested backup content was committed but cleanup needs attention.
        case appliedWithRecovery
        /// The requested backup content was committed but cleanup durability needs verification.
        case appliedNeedsVerification
        /// A race prevented CodingBuddy from proving the final target state.
        case uncertain
        /// The failure happened outside the transactional recovery path.
        case ordinaryFailure
    }

    /// Best-known transactional outcome used to choose truthful copy.
    let outcome: Outcome
    /// Localized alert heading.
    let title: String
    /// Localized, path-aware recovery explanation.
    let message: String
    /// Retained artifact paths that can be revealed or copied for manual recovery.
    let recoveryURLs: [URL]

    /// Whether the store must retain an explicit recovery route after dismissing the alert.
    var requiresPersistentAttention: Bool {
        outcome != .ordinaryFailure
    }

    /// Preserves structured `SafeFileWriter` recovery state instead of flattening it to text.
    init(error: any Error) {
        if let cleanupError = error as? SafeFileWriter.CleanupDurabilityError {
            outcome = .appliedNeedsVerification
            title = String(localized: "Restore Applied; Verification Required")
            message = cleanupError.localizedDescription
            recoveryURLs = []
            return
        }

        guard let recoveryError = error as? SafeFileWriter.RecoveryError else {
            outcome = .ordinaryFailure
            title = String(localized: "Restore Failed")
            message = error.localizedDescription
            recoveryURLs = []
            return
        }

        switch recoveryError.commitState {
        case .notCommitted:
            outcome = .notApplied
            title = String(localized: "Restore Was Not Applied")
        case .committed:
            outcome = .appliedWithRecovery
            title = String(localized: "Restore Completed with Recovery Required")
        case .unknown:
            outcome = .uncertain
            title = String(localized: "Restore State Could Not Be Confirmed")
        }
        message = recoveryError.localizedDescription
        recoveryURLs = recoveryError.artifacts.map { URL(fileURLWithPath: $0.lastKnownPath) }
    }
}
