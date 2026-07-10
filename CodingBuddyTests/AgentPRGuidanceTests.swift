//
//  AgentPRGuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct AgentPRGuidanceTests {
    @Test func readyPullRequestNeedsNoAction() {
        let guidance = guidance(for: makeRow())

        #expect(guidance.id.hasSuffix(".ready"))
        #expect(guidance.recommendedAction.id == AgentPRGuidanceCatalog.noActionID)
        #expect(isNoAction(guidance.recommendedAction.availability))
        #expect(guidance.glossaryTerms == [.pr, .ci])
    }

    @Test func waitingForContinuousIntegrationNeedsNoAction() {
        let row = makeRow(checkState: .waiting)
        let guidance = guidance(for: row)

        #expect(row.readiness.state == .waiting)
        #expect(guidance.id.hasSuffix(".waiting-for-ci"))
        #expect(guidance.recommendedAction.id == AgentPRGuidanceCatalog.noActionID)
        #expect(isNoAction(guidance.recommendedAction.availability))
        #expect(guidance.glossaryTerms == [.pr, .ci])
    }

    @Test func waitingForReviewNeedsNoAction() {
        let row = makeRow(reviewDecision: .reviewRequired)
        let guidance = guidance(for: row)

        #expect(row.readiness.state == .waiting)
        #expect(guidance.id.hasSuffix(".waiting-for-review"))
        #expect(guidance.recommendedAction.id == AgentPRGuidanceCatalog.noActionID)
        #expect(isNoAction(guidance.recommendedAction.availability))
        #expect(guidance.glossaryTerms == [.pr])
    }

    @Test func failedContinuousIntegrationRoutesToPullRequest() {
        let row = makeRow(checkState: .failed)
        let guidance = guidance(for: row)

        #expect(row.readiness.state == .attentionNeeded)
        #expect(guidance.id.hasSuffix(".failed-ci"))
        expectAvailableRoute(guidance, .openPullRequest)
        #expect(guidance.glossaryTerms == [.pr, .ci])
    }

    @Test func requestedChangesRouteToPullRequest() {
        let row = makeRow(reviewDecision: .changesRequested)
        let guidance = guidance(for: row)

        #expect(row.readiness.state == .attentionNeeded)
        #expect(guidance.id.hasSuffix(".changes-requested"))
        expectAvailableRoute(guidance, .openPullRequest)
        #expect(guidance.glossaryTerms == [.pr])
    }

    @Test func unresolvedFindingsRouteToPullRequest() {
        let row = makeRow(unresolvedFindingCount: 2)
        let guidance = guidance(for: row)

        #expect(row.review.unresolvedFindingCount == 2)
        #expect(row.readiness.state == .attentionNeeded)
        #expect(guidance.id.hasSuffix(".unresolved-findings"))
        expectAvailableRoute(guidance, .openPullRequest)
        #expect(guidance.glossaryTerms == [.pr])
    }

    @Test func draftRoutesToPullRequestBeforeOtherRowSignals() {
        let row = makeRow(isDraft: true, checkState: .failed, reviewDecision: .changesRequested)
        let guidance = guidance(for: row)

        #expect(row.readiness.state == .blocked)
        #expect(guidance.id.hasSuffix(".draft"))
        expectAvailableRoute(guidance, .openPullRequest)
        #expect(guidance.glossaryTerms == [.pr])
    }

    @Test func staleAuthorizationOverridesFailedRowAndRoutesToSettings() {
        let row = makeRow(checkState: .failed)
        let guidance = guidance(for: row, freshness: .authorizationRequired)

        #expect(guidance.id.hasSuffix(".stale-authorization"))
        expectAvailableRoute(guidance, .openSettings)
    }

    @Test func staleRateLimitOverridesFailedRowWithHonestWaiting() {
        let row = makeRow(checkState: .failed)
        let guidance = guidance(for: row, freshness: .rateLimited)

        #expect(guidance.id.hasSuffix(".stale-rate-limit"))
        #expect(guidance.recommendedAction.id == AgentPRGuidanceCatalog.waitForGitHubActionID)
        #expect(isNoAction(guidance.recommendedAction.availability))
    }

    @Test func staleRefreshFailureOverridesReadyRowAndRoutesToRefresh() {
        let guidance = guidance(for: makeRow(), freshness: .refreshFailed)

        #expect(guidance.id.hasSuffix(".stale-refresh-failure"))
        expectAvailableRoute(guidance, .refresh)
    }

    @Test func runningRefreshOverridesReadyRowWithoutStartingAnotherRequest() {
        let guidance = guidance(for: makeRow(), freshness: .refreshing)

        #expect(guidance.id.hasSuffix(".refreshing"))
        #expect(guidance.recommendedAction.id == AgentPRGuidanceCatalog.waitForRefreshActionID)
        #expect(isNoAction(guidance.recommendedAction.availability))
        #expect(guidance.recommendedAction.title.localizedCaseInsensitiveContains("wait"))
    }

    @Test func repositoryStateMapsToFreshnessWithoutRetainingProviderErrors() {
        let providerDetail = "provider-secret-scope"
        let authorizationState = AgentPRMonitorState.refreshFailed(.missingScope(providerDetail))
        let guidance = guidance(
            for: makeRow(checkState: .failed),
            freshness: AgentPRMonitorView.guidanceFreshness(for: authorizationState)
        )

        #expect(AgentPRMonitorView.guidanceFreshness(for: .loaded) == .fresh)
        #expect(AgentPRMonitorView.guidanceFreshness(for: .loading) == .refreshing)
        #expect(AgentPRMonitorView.guidanceFreshness(for: .needsToken) == .authorizationRequired)
        #expect(AgentPRMonitorView.guidanceFreshness(for: authorizationState) == .authorizationRequired)
        #expect(AgentPRMonitorView.guidanceFreshness(for: .rateLimited(nil)) == .rateLimited)
        #expect(AgentPRMonitorView.guidanceFreshness(
            for: .refreshFailed(.rateLimited(resetAt: nil))
        ) == .rateLimited)
        #expect(AgentPRMonitorView.guidanceFreshness(
            for: .refreshFailed(.networkUnavailable)
        ) == .refreshFailed)
        #expect(!allText(in: guidance).contains(providerDetail))
    }

    @Test func guidanceIdentityIsDeterministicAndInstanceSpecific() {
        let firstRow = makeRow(number: 100)
        let secondRow = makeRow(number: 101)
        let first = guidance(for: firstRow)
        let repeated = guidance(for: firstRow)
        let second = guidance(for: secondRow)

        #expect(first == repeated)
        #expect(first.id != second.id)
        #expect(first.id.contains(firstRow.id))
        #expect(second.id.contains(secondRow.id))
    }

    @Test func routeAndEvidenceIdentifiersAreNamespacedAndStable() {
        #expect(AgentPRGuidanceRoute.allCases.map(\.rawValue) == [
            "agent-pr-monitor.route.open-pr",
            "agent-pr-monitor.route.refresh",
            "agent-pr-monitor.route.open-settings",
        ])
        #expect(AgentPRGuidanceEvidenceID.allCases.map(\.rawValue) == [
            "agent-pr-monitor.evidence.repository",
            "agent-pr-monitor.evidence.pr-number",
            "agent-pr-monitor.evidence.readiness",
            "agent-pr-monitor.evidence.ci-state",
            "agent-pr-monitor.evidence.review-state",
            "agent-pr-monitor.evidence.unresolved-findings",
            "agent-pr-monitor.evidence.head-sha",
        ])
    }

    @Test func unavailableRoutesExplainWhyInsteadOfProducingAvailableNoOps() {
        let unavailable = AgentPRGuidanceActionAvailability(
            canOpenPullRequest: false,
            canRefresh: false,
            canOpenSettings: false
        )
        let openPullRequest = AgentPRGuidanceCatalog.guidance(
            for: makeRow(checkState: .failed),
            freshness: .fresh,
            actionAvailability: unavailable
        ).recommendedAction
        let refresh = AgentPRGuidanceCatalog.guidance(
            for: makeRow(),
            freshness: .refreshFailed,
            actionAvailability: unavailable
        ).recommendedAction
        let openSettings = AgentPRGuidanceCatalog.guidance(
            for: makeRow(),
            freshness: .authorizationRequired,
            actionAvailability: unavailable
        ).recommendedAction

        #expect(openPullRequest.id == AgentPRGuidanceRoute.openPullRequest.rawValue)
        #expect(refresh.id == AgentPRGuidanceRoute.refresh.rawValue)
        #expect(openSettings.id == AgentPRGuidanceRoute.openSettings.rawValue)
        #expect(hasUnavailableReason(openPullRequest.availability))
        #expect(hasUnavailableReason(refresh.availability))
        #expect(hasUnavailableReason(openSettings.availability))
    }

    @Test func evidenceOrderIsFixedAndExcludesProviderRichFields() {
        let row = makeRow(
            number: 100,
            title: "private title token",
            headSHA: "ABCDEF1234567890",
            unresolvedFindingCount: 1
        )
        let guidance = guidance(for: row)
        let evidence = guidance.technicalEvidence
        let evidenceText = evidence
            .flatMap { [$0.id, $0.label, $0.sanitizedValue] }
            .joined(separator: " ")

        #expect(evidence.map(\.id) == AgentPRGuidanceEvidenceID.allCases.map(\.rawValue))
        #expect(evidence.map(\.sanitizedValue) == [
            row.repository.displayName,
            "#100",
            row.readiness.state.displayName,
            row.checks.state.displayName,
            row.review.state.displayName,
            "1",
            "ABCDEF1",
        ])
        for forbiddenValue in [
            row.title,
            row.headRefName,
            row.baseRefName,
            row.url.absoluteString,
            row.authorLogin ?? "",
            row.linkedIssues[0].title,
            row.linkedIssues[0].url.absoluteString,
            row.review.threads[0].path ?? "",
            row.review.threads[0].url?.absoluteString ?? "",
        ] where !forbiddenValue.isEmpty {
            #expect(!evidenceText.contains(forbiddenValue))
        }
    }

    @Test func malformedRepositoryAndHeadValuesAreSanitized() {
        let repository = GitHubRepositoryRef(owner: "safe-owner\n", name: "safe-repo\t")
        let row = makeRow(repository: repository, headSHA: "github_pat_provider-secret")
        let evidence = guidance(for: row).technicalEvidence

        #expect(evidence[0].sanitizedValue == "safe-owner/safe-repo")
        #expect(!evidence[0].sanitizedValue.contains("\n"))
        #expect(!evidence[0].sanitizedValue.contains("\t"))
        #expect(!evidence[6].sanitizedValue.contains("provider-secret"))
        #expect(evidence[6].sanitizedValue.count > 0)
    }

    @Test func waitingStatesDoNotCreateFalseUrgency() {
        let waitingGuidance = [
            guidance(for: makeRow(checkState: .waiting)),
            guidance(for: makeRow(reviewDecision: .reviewRequired)),
            guidance(for: makeRow(), freshness: .refreshing),
            guidance(for: makeRow(), freshness: .rateLimited),
        ]
        let falseUrgencyTerms = ["urgent", "urgently", "immediately", "right away", "as soon as possible"]

        for guidance in waitingGuidance {
            #expect(isNoAction(guidance.recommendedAction.availability))
            let text = allText(in: guidance).lowercased()
            for term in falseUrgencyTerms {
                #expect(!text.contains(term))
            }
        }
    }

    private func guidance(
        for row: AgentPullRequest,
        freshness: AgentPRGuidanceFreshness = .fresh
    ) -> Guidance {
        AgentPRGuidanceCatalog.guidance(
            for: row,
            freshness: freshness,
            actionAvailability: .allAvailable
        )
    }

    private func expectAvailableRoute(_ guidance: Guidance, _ route: AgentPRGuidanceRoute) {
        #expect(guidance.recommendedAction.id == route.rawValue)
        #expect(guidance.recommendedAction.availability == .available)
    }

    private func isNoAction(_ availability: ActionAvailability) -> Bool {
        guard case .notNeeded(let reason) = availability else { return false }
        return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasUnavailableReason(_ availability: ActionAvailability) -> Bool {
        guard case .unavailable(let reason) = availability else { return false }
        return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func allText(in guidance: Guidance) -> String {
        let action = guidance.recommendedAction
        let unavailableReason: String
        switch action.availability {
        case .available:
            unavailableReason = ""
        case .notNeeded(let reason), .unavailable(let reason):
            unavailableReason = reason
        }
        return [
            guidance.explanation,
            guidance.relevance,
            guidance.consequence,
            action.title,
            action.expectedResult,
            unavailableReason,
        ]
        .joined(separator: " ")
    }

    private func makeRow(
        repository: GitHubRepositoryRef = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
        number: Int = 100,
        title: String = "feat: provider-rich title",
        isDraft: Bool = false,
        headSHA: String = "abcdef1234567890",
        checkState: AgentPRCheckState = .green,
        reviewDecision: AgentPRReviewDecision = .approved,
        unresolvedFindingCount: Int = 0
    ) -> AgentPullRequest {
        AgentPullRequest(
            repository: repository,
            number: number,
            title: title,
            url: URL(string: "https://github.com/apps3k-com/CodingBuddy/pull/\(number)?private=value")!,
            isDraft: isDraft,
            authorLogin: "provider-author",
            source: .likelyAgent,
            headRefName: "bvk/private-provider-branch",
            headSHA: headSHA,
            baseRefName: "private-base-branch",
            linkedIssues: [
                AgentPRLinkedIssue(
                    number: 98,
                    title: "private linked issue title",
                    url: URL(string: "https://github.com/apps3k-com/CodingBuddy/issues/98?private=value")!,
                    state: .open
                ),
            ],
            review: AgentPRReviewSummary(
                decision: reviewDecision,
                latestReviews: [],
                threads: (0..<unresolvedFindingCount).map { index in
                    AgentPRReviewThread(
                        path: "Sources/PrivateProvider\(index).swift",
                        line: index + 1,
                        isResolved: false,
                        isOutdated: false,
                        url: URL(
                            string: "https://github.com/apps3k-com/CodingBuddy/pull/\(number)#private-review-\(index)"
                        )!
                    )
                }
            ),
            checks: checkSummary(for: checkState),
            updatedAt: Date(timeIntervalSince1970: 1_783_000_000)
        )
    }

    private func checkSummary(for state: AgentPRCheckState) -> AgentPRCheckSummary {
        let statusState: AgentPRStatusState?
        switch state {
        case .green:
            statusState = .success
        case .waiting:
            statusState = .inProgress
        case .failed:
            statusState = .failure
        case .unknown:
            statusState = nil
        }
        return AgentPRCheckSummary(
            contexts: statusState.map {
                [
                    AgentPRStatusContext(
                        name: "private-provider-check",
                        state: $0,
                        detailsURL: URL(string: "https://github.com/apps3k-com/CodingBuddy/actions/private")
                    ),
                ]
            } ?? []
        )
    }
}
