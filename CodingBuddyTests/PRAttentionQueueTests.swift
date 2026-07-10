//
//  PRAttentionQueueTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Deterministic ranking coverage for the cross-repository PR attention queue.
@Suite("PR Attention Queue")
struct PRAttentionQueueTests {
    @Test func confirmedBlockersLeadWhileWaitingAndReadyWorkStayCalm() {
        let rows = [
            makeRow(number: 1, checkState: .green, reviewDecision: .approved),
            makeRow(number: 2, checkState: .waiting, reviewDecision: .approved),
            makeRow(number: 3, isDraft: true),
            makeRow(number: 4, unresolvedFindingCount: 2),
            makeRow(number: 5, reviewDecision: .changesRequested),
            makeRow(number: 6, checkState: .failed),
        ]

        let snapshot = PRAttentionQueueBuilder.snapshot(rows: rows, freshnessByRepository: [:])

        #expect(snapshot.items.map(\.row.number) == [6, 5, 4, 3, 2, 1])
        #expect(snapshot.items.map(\.priority) == [
            .actNow, .actNow, .actNow, .next, .waiting, .ready,
        ])
        #expect(snapshot.recommendedItem?.row.number == 6)
        #expect(snapshot.actNowCount == 3)
    }

    @Test func staleRepositoryStateOverridesRowsAndAppearsOnlyOnce() {
        let staleRepository = GitHubRepositoryRef(owner: "apps3k-com", name: "stale")
        let healthyRepository = GitHubRepositoryRef(owner: "apps3k-com", name: "healthy")
        let rows = [
            makeRow(
                repository: staleRepository,
                number: 10,
                checkState: .failed,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            makeRow(
                repository: staleRepository,
                number: 11,
                updatedAt: Date(timeIntervalSince1970: 300)
            ),
            makeRow(repository: healthyRepository, number: 12),
        ]

        let snapshot = PRAttentionQueueBuilder.snapshot(
            rows: rows,
            freshnessByRepository: [staleRepository: .authorizationRequired]
        )

        #expect(snapshot.items.count == 2)
        #expect(snapshot.items.first?.row.number == 11)
        #expect(snapshot.items.first?.state == .staleAuthorization)
        #expect(snapshot.items.first?.priority == .actNow)
        #expect(snapshot.items.last?.row.repository == healthyRepository)
    }

    @Test func oneRepositoryFailureDoesNotHideOtherRepositoryResults() {
        let failingRepository = GitHubRepositoryRef(owner: "apps3k-com", name: "refresh-failed")
        let actionableRepository = GitHubRepositoryRef(owner: "apps3k-com", name: "failed-ci")
        let snapshot = PRAttentionQueueBuilder.snapshot(
            rows: [
                makeRow(repository: failingRepository, number: 20),
                makeRow(repository: actionableRepository, number: 21, checkState: .failed),
            ],
            freshnessByRepository: [failingRepository: .refreshFailed]
        )

        #expect(snapshot.items.map(\.row.number) == [21, 20])
        #expect(snapshot.items.map(\.state) == [.failedContinuousIntegration, .staleRefreshFailure])
        #expect(snapshot.items.map(\.priority) == [.actNow, .next])
    }

    @Test func rateLimitsAndActiveRefreshesRemainWaitingStates() {
        let rateLimited = GitHubRepositoryRef(owner: "apps3k-com", name: "rate-limited")
        let refreshing = GitHubRepositoryRef(owner: "apps3k-com", name: "refreshing")
        let snapshot = PRAttentionQueueBuilder.snapshot(
            rows: [
                makeRow(repository: rateLimited, number: 30, checkState: .failed),
                makeRow(repository: refreshing, number: 31, checkState: .failed),
            ],
            freshnessByRepository: [
                rateLimited: .rateLimited,
                refreshing: .refreshing,
            ]
        )

        #expect(snapshot.items.map(\.priority) == [.waiting, .waiting])
        #expect(snapshot.items.map(\.state) == [.refreshing, .staleRateLimit])
        #expect(snapshot.actNowCount == 0)
    }

    @Test func tiesUseRecentContextThenRepositoryAndPullRequestNumber() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let alpha = GitHubRepositoryRef(owner: "apps3k-com", name: "alpha")
        let beta = GitHubRepositoryRef(owner: "apps3k-com", name: "beta")
        let snapshot = PRAttentionQueueBuilder.snapshot(
            rows: [
                makeRow(repository: beta, number: 8, checkState: .failed, updatedAt: older),
                makeRow(repository: beta, number: 9, checkState: .failed, updatedAt: newer),
                makeRow(repository: alpha, number: 7, checkState: .failed, updatedAt: newer),
                makeRow(repository: alpha, number: 6, checkState: .failed, updatedAt: newer),
            ],
            freshnessByRepository: [:]
        )

        #expect(snapshot.items.map(\.row.number) == [6, 7, 9, 8])
    }

    @Test func unavailableRecoveryRouteIsExplainedWithoutChangingPriority() {
        let repository = GitHubRepositoryRef(owner: "apps3k-com", name: "authorization")
        let availability = AgentPRGuidanceActionAvailability(
            canOpenPullRequest: true,
            canRefresh: true,
            canOpenSettings: false
        )
        let item = PRAttentionQueueBuilder.snapshot(
            rows: [makeRow(repository: repository, number: 40)],
            freshnessByRepository: [repository: .authorizationRequired],
            actionAvailability: availability
        ).recommendedItem

        #expect(item?.priority == .actNow)
        guard case .unavailable(let reason) = item?.guidance.recommendedAction.availability else {
            Issue.record("Expected an unavailable Settings route")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func everyPriorityHasPlainLanguageCopy() {
        for priority in AttentionPriority.allCases {
            #expect(!priority.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!priority.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func makeRow(
        repository: GitHubRepositoryRef = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
        number: Int,
        isDraft: Bool = false,
        checkState: AgentPRCheckState = .green,
        reviewDecision: AgentPRReviewDecision = .approved,
        unresolvedFindingCount: Int = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 1_783_000_000)
    ) -> AgentPullRequest {
        AgentPullRequest(
            repository: repository,
            number: number,
            title: "Pull request \(number)",
            url: URL(string: "https://github.com/\(repository.id)/pull/\(number)")!,
            isDraft: isDraft,
            authorLogin: "developer",
            source: .likelyHuman,
            headRefName: "feature-\(number)",
            headSHA: "abcdef1234567890",
            baseRefName: "main",
            linkedIssues: [],
            review: AgentPRReviewSummary(
                decision: reviewDecision,
                latestReviews: [],
                threads: (0..<unresolvedFindingCount).map { index in
                    AgentPRReviewThread(
                        path: "Sources/File\(index).swift",
                        line: index + 1,
                        isResolved: false,
                        isOutdated: false,
                        url: nil
                    )
                }
            ),
            checks: checkSummary(for: checkState),
            updatedAt: updatedAt
        )
    }

    private func checkSummary(for state: AgentPRCheckState) -> AgentPRCheckSummary {
        let contextState: AgentPRStatusState?
        switch state {
        case .green:
            contextState = .success
        case .waiting:
            contextState = .inProgress
        case .failed:
            contextState = .failure
        case .unknown:
            contextState = nil
        }
        return AgentPRCheckSummary(
            contexts: contextState.map {
                [AgentPRStatusContext(name: "build", state: $0, detailsURL: nil)]
            } ?? []
        )
    }
}
