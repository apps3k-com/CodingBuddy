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
        repositories: [GitHubRepositoryRef] = [],
        freshnessByRepository: [GitHubRepositoryRef: AgentPRGuidanceFreshness],
        defaultFreshness: AgentPRGuidanceFreshness = .fresh,
        actionAvailability: AgentPRGuidanceActionAvailability = .allAvailable
    ) -> PRAttentionQueueSnapshot {
        let newestFirst = rows.sorted(by: stableSourceOrder)
        let freshnessByIdentity = canonicalFreshness(freshnessByRepository)
        var representedPullRequests = Set<String>()
        var representedStaleRepositories = Set<String>()
        var items: [PRAttentionItem] = []

        for row in newestFirst {
            let repositoryIdentity = row.repository.canonicalID
            let pullRequestIdentity = "\(repositoryIdentity)#\(row.number)"
            guard representedPullRequests.insert(pullRequestIdentity).inserted else { continue }
            let freshness = freshnessByIdentity[repositoryIdentity] ?? defaultFreshness
            let state = AgentPRGuidanceCatalog.state(for: row, freshness: freshness)

            if state.isRepositoryScopedSnapshotState,
               !representedStaleRepositories.insert(repositoryIdentity).inserted {
                continue
            }

            items.append(
                PRAttentionItem(
                    source: .pullRequest(row),
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

        var knownRepositories: [String: GitHubRepositoryRef] = [:]
        for repository in (repositories + Array(freshnessByRepository.keys)).sorted(by: repositoryOrder) {
            knownRepositories[repository.canonicalID] = knownRepositories[repository.canonicalID] ?? repository
        }
        for repository in knownRepositories.values.sorted(by: repositoryOrder) {
            guard !representedStaleRepositories.contains(repository.canonicalID) else { continue }
            let freshness = freshnessByIdentity[repository.canonicalID] ?? defaultFreshness
            guard let state = AgentPRGuidanceCatalog.repositoryState(for: freshness),
                  let guidance = AgentPRGuidanceCatalog.guidance(
                      for: repository,
                      freshness: freshness,
                      actionAvailability: actionAvailability
                  ) else {
                continue
            }
            items.append(
                PRAttentionItem(
                    source: .repository(repository),
                    freshness: freshness,
                    state: state,
                    priority: state.attentionPriority,
                    guidance: guidance
                )
            )
        }

        return PRAttentionQueueSnapshot(items: items.sorted(by: attentionOrder))
    }

    /// Source order chooses a deterministic representative when repository freshness affects many PRs.
    private static func stableSourceOrder(_ lhs: AgentPullRequest, _ rhs: AgentPullRequest) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let lhsRepository = lhs.repository.canonicalID
        let rhsRepository = rhs.repository.canonicalID
        if lhsRepository != rhsRepository { return lhsRepository < rhsRepository }
        if lhs.repository.id != rhs.repository.id { return lhs.repository.id < rhs.repository.id }
        return lhs.number < rhs.number
    }

    /// Collapses case variants and keeps the most conservative freshness signal deterministically.
    private static func canonicalFreshness(
        _ source: [GitHubRepositoryRef: AgentPRGuidanceFreshness]
    ) -> [String: AgentPRGuidanceFreshness] {
        var result: [String: AgentPRGuidanceFreshness] = [:]
        for (repository, freshness) in source.sorted(by: { repositoryOrder($0.key, $1.key) }) {
            let identity = repository.canonicalID
            guard let current = result[identity] else {
                result[identity] = freshness
                continue
            }
            if freshnessRiskRank(freshness) < freshnessRiskRank(current) {
                result[identity] = freshness
            }
        }
        return result
    }

    /// Fail-closed precedence when duplicate provider spellings disagree about freshness.
    private static func freshnessRiskRank(_ freshness: AgentPRGuidanceFreshness) -> Int {
        switch freshness {
        case .authorizationRequired: 0
        case .refreshFailed: 1
        case .rateLimited: 2
        case .refreshing: 3
        case .fresh: 4
        }
    }

    /// Stable provider-independent ordering for repository-only entries.
    private static func repositoryOrder(_ lhs: GitHubRepositoryRef, _ rhs: GitHubRepositoryRef) -> Bool {
        let lhsNormalized = lhs.id.lowercased()
        let rhsNormalized = rhs.id.lowercased()
        if lhsNormalized != rhsNormalized { return lhsNormalized < rhsNormalized }
        return lhs.id < rhs.id
    }

    /// Product policy: state class first, then recent context and stable repository identity.
    private static func attentionOrder(_ lhs: PRAttentionItem, _ rhs: PRAttentionItem) -> Bool {
        if lhs.state.attentionRank != rhs.state.attentionRank {
            return lhs.state.attentionRank < rhs.state.attentionRank
        }
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
        let lhsRepository = lhs.repository.canonicalID
        let rhsRepository = rhs.repository.canonicalID
        if lhsRepository != rhsRepository { return lhsRepository < rhsRepository }
        if lhs.repository.id != rhs.repository.id { return lhs.repository.id < rhs.repository.id }
        return (lhs.pullRequest?.number ?? 0) < (rhs.pullRequest?.number ?? 0)
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
