//
//  PRAttentionQueueBuilder.swift
//  CodingBuddy
//

import Foundation

/// Pure builder that turns PR monitor snapshots into a deterministic attention queue.
nonisolated enum PRAttentionQueueBuilder {
    /// Builds one ranked snapshot without retaining provider error text or adding persistence.
    static func snapshot(
        rows: [AgentPullRequest],
        freshnessByRepository: [GitHubRepositoryRef: AgentPRGuidanceFreshness],
        defaultFreshness: AgentPRGuidanceFreshness = .fresh,
        actionAvailability: AgentPRGuidanceActionAvailability = .allAvailable
    ) -> PRAttentionQueueSnapshot {
        let newestFirst = rows.sorted(by: stableSourceOrder)
        var representedStaleRepositories = Set<GitHubRepositoryRef>()
        var items: [PRAttentionItem] = []

        for row in newestFirst {
            let freshness = freshnessByRepository[row.repository] ?? defaultFreshness
            let state = AgentPRGuidanceCatalog.state(for: row, freshness: freshness)

            if state.isRepositoryScopedSnapshotState,
               !representedStaleRepositories.insert(row.repository).inserted {
                continue
            }

            items.append(
                PRAttentionItem(
                    row: row,
                    freshness: freshness,
                    state: state,
                    priority: state.attentionPriority,
                    guidance: AgentPRGuidanceCatalog.guidance(
                        for: row,
                        freshness: freshness,
                        actionAvailability: actionAvailability
                    )
                )
            )
        }

        return PRAttentionQueueSnapshot(items: items.sorted(by: attentionOrder))
    }

    /// Source order chooses a deterministic representative when repository freshness affects many PRs.
    private static func stableSourceOrder(_ lhs: AgentPullRequest, _ rhs: AgentPullRequest) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let lhsRepository = lhs.repository.id.lowercased()
        let rhsRepository = rhs.repository.id.lowercased()
        if lhsRepository != rhsRepository { return lhsRepository < rhsRepository }
        return lhs.number < rhs.number
    }

    /// Product policy: state class first, then recent context and stable repository identity.
    private static func attentionOrder(_ lhs: PRAttentionItem, _ rhs: PRAttentionItem) -> Bool {
        if lhs.state.attentionRank != rhs.state.attentionRank {
            return lhs.state.attentionRank < rhs.state.attentionRank
        }
        if lhs.row.updatedAt != rhs.row.updatedAt { return lhs.row.updatedAt > rhs.row.updatedAt }
        let lhsRepository = lhs.row.repository.id.lowercased()
        let rhsRepository = rhs.row.repository.id.lowercased()
        if lhsRepository != rhsRepository { return lhsRepository < rhsRepository }
        return lhs.row.number < rhs.row.number
    }
}

private extension AgentPRGuidanceState {
    /// Calm user-facing urgency band for one deterministic PR state.
    nonisolated var attentionPriority: AttentionPriority {
        switch self {
        case .staleAuthorization, .failedContinuousIntegration, .changesRequested, .unresolvedFindings:
            .actNow
        case .staleRefreshFailure, .draft:
            .next
        case .staleRateLimit, .refreshing, .waitingForContinuousIntegration,
             .waitingForReview, .waitingForSignals:
            .waiting
        case .ready:
            .ready
        }
    }

    /// Explicit state order inside urgency bands; this is never shown as a score.
    nonisolated var attentionRank: Int {
        switch self {
        case .staleAuthorization: 0
        case .failedContinuousIntegration: 1
        case .changesRequested: 2
        case .unresolvedFindings: 3
        case .staleRefreshFailure: 4
        case .draft: 5
        case .waitingForContinuousIntegration: 6
        case .waitingForReview: 7
        case .waitingForSignals: 8
        case .refreshing: 9
        case .staleRateLimit: 10
        case .ready: 11
        }
    }

    /// Repository refresh states are represented once to avoid repeating the same recovery action per PR.
    nonisolated var isRepositoryScopedSnapshotState: Bool {
        switch self {
        case .staleAuthorization, .staleRateLimit, .staleRefreshFailure, .refreshing:
            true
        case .ready, .waitingForContinuousIntegration, .waitingForReview, .waitingForSignals,
             .failedContinuousIntegration, .changesRequested, .unresolvedFindings, .draft:
            false
        }
    }
}
