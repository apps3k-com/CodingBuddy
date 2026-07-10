//
//  PRAttentionQueue.swift
//  CodingBuddy
//

import Foundation

/// Calm, user-facing urgency bands used by the attention queue.
nonisolated enum AttentionPriority: Int, CaseIterable, Comparable, Sendable {
    /// A confirmed blocker or visibility problem has a useful action now.
    case actNow
    /// A bounded follow-up is useful after immediate blockers.
    case next
    /// Another process or person must finish before more work helps.
    case waiting
    /// No known blocker is visible.
    case ready

    /// Stable ordering from most to least useful current attention.
    static func < (lhs: AttentionPriority, rhs: AttentionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Localized compact label shown in the queue table.
    var displayName: String {
        switch self {
        case .actNow:
            String(localized: "Attention priority act now", defaultValue: "Act now")
        case .next:
            String(localized: "Attention priority next", defaultValue: "Next")
        case .waiting:
            String(localized: "Attention priority waiting", defaultValue: "Waiting")
        case .ready:
            String(localized: "Attention priority ready", defaultValue: "Ready")
        }
    }

    /// Plain-language explanation of why this urgency band was assigned.
    var explanation: String {
        switch self {
        case .actNow:
            String(
                localized: "Attention priority act now explanation",
                defaultValue: "A confirmed blocker needs work, or CodingBuddy cannot verify the current repository state."
            )
        case .next:
            String(
                localized: "Attention priority next explanation",
                defaultValue: "A useful follow-up is available, but no confirmed urgent blocker is visible."
            )
        case .waiting:
            String(
                localized: "Attention priority waiting explanation",
                defaultValue: "Another process or person needs to finish before an additional action is useful."
            )
        case .ready:
            String(
                localized: "Attention priority ready explanation",
                defaultValue: "No known blocker is visible; this pull request stays in the queue for completion follow-up."
            )
        }
    }
}

/// One ranked pull request and the guidance that explains its current state.
nonisolated struct PRAttentionItem: Identifiable, Equatable, Sendable {
    /// Current pull request snapshot represented by the queue row.
    let row: AgentPullRequest
    /// Freshness used when classifying and explaining the snapshot.
    let freshness: AgentPRGuidanceFreshness
    /// Shared deterministic state used by both ranking and source guidance.
    let state: AgentPRGuidanceState
    /// Calm urgency band shown instead of an opaque score.
    let priority: AttentionPriority
    /// Existing source guidance and safe recommended action.
    let guidance: Guidance

    /// Stable identity matching the source pull request row.
    var id: AgentPullRequest.ID { row.id }

    /// Localized reason that distinguishes states inside one urgency band.
    var reasonDisplayName: String {
        switch state {
        case .staleAuthorization:
            String(localized: "Attention reason GitHub access", defaultValue: "GitHub access is unavailable")
        case .staleRateLimit:
            String(localized: "Attention reason rate limited", defaultValue: "GitHub is limiting refreshes")
        case .staleRefreshFailure:
            String(localized: "Attention reason refresh failed", defaultValue: "Repository refresh failed")
        case .refreshing:
            String(localized: "Attention reason refreshing", defaultValue: "Repository refresh is running")
        case .ready:
            String(localized: "Attention reason ready", defaultValue: "Ready to complete")
        case .waitingForContinuousIntegration:
            String(localized: "Attention reason waiting for CI", defaultValue: "CI is still running")
        case .waitingForReview:
            String(localized: "Attention reason waiting for review", defaultValue: "Review is still pending")
        case .waitingForSignals:
            String(localized: "Attention reason waiting for signals", defaultValue: "Readiness signals are incomplete")
        case .failedContinuousIntegration:
            String(localized: "Attention reason failed CI", defaultValue: "CI failed")
        case .changesRequested:
            String(localized: "Attention reason changes requested", defaultValue: "Changes were requested")
        case .unresolvedFindings:
            String(localized: "Attention reason unresolved findings", defaultValue: "Review findings are unresolved")
        case .draft:
            String(localized: "Attention reason draft", defaultValue: "Draft pull request")
        }
    }
}

/// Immutable queue result used by the view and sidebar badge.
nonisolated struct PRAttentionQueueSnapshot: Equatable, Sendable {
    /// Ranked items from most to least useful current attention.
    let items: [PRAttentionItem]

    /// First item shown as the recommended next focus.
    var recommendedItem: PRAttentionItem? { items.first }

    /// Number of items with a confirmed immediate blocker or visibility problem.
    var actNowCount: Int { items.filter { $0.priority == .actNow }.count }
}
