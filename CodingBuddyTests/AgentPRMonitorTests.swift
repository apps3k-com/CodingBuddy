//
//  AgentPRMonitorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
@Suite(.serialized)
/// Regression coverage for the Agent PR Monitor client, store, models, and test doubles.
struct AgentPRMonitorTests {
    /// Repository fixture shared by client and store tests.
    private let repository = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy")

    /// Verifies pending checks are treated as waiting rather than failed.
    @Test func checkSummaryTreatsPendingAsWaitingNotFailure() {
        let summary = AgentPRCheckSummary(
            contexts: [
                AgentPRStatusContext(name: "build-and-test", state: .inProgress, detailsURL: nil),
                AgentPRStatusContext(name: "CodeRabbit", state: .success, detailsURL: nil),
            ]
        )

        #expect(summary.state == .waiting)
        #expect(summary.failingContextNames.isEmpty)
    }

    /// Verifies failed check summaries preserve the failing context names.
    @Test func checkSummaryCapturesFailingContextNames() {
        let summary = AgentPRCheckSummary(
            contexts: [
                AgentPRStatusContext(name: "build-and-test", state: .failure, detailsURL: nil),
                AgentPRStatusContext(name: "lint", state: .timedOut, detailsURL: nil),
            ]
        )

        #expect(summary.state == .failed)
        #expect(summary.failingContextNames == ["build-and-test", "lint"])
    }

    /// Verifies resolved and outdated review threads do not count as active findings.
    @Test func reviewSummaryIgnoresResolvedAndOutdatedThreads() {
        let summary = AgentPRReviewSummary(
            decision: .reviewRequired,
            latestReviews: [
                AgentPRReview(authorLogin: "coderabbitai", state: .commented, submittedAt: nil, url: nil),
            ],
            threads: [
                AgentPRReviewThread(path: "A.swift", line: 10, isResolved: true, isOutdated: false, url: nil),
                AgentPRReviewThread(path: "B.swift", line: 20, isResolved: false, isOutdated: true, url: nil),
                AgentPRReviewThread(path: "C.swift", line: 30, isResolved: false, isOutdated: false, url: nil),
            ]
        )

        #expect(summary.state == .reviewRequired)
        #expect(summary.unresolvedFindingCount == 1)
        #expect(summary.findingsState == .unresolvedFindings(count: 1))
    }

    /// Verifies truncated review or check data keeps merge readiness conservative.
    @Test func truncatedReviewAndCheckSummariesNeverAppearReady() {
        let checks = AgentPRCheckSummary(
            contexts: [
                AgentPRStatusContext(name: "build-and-test", state: .success, detailsURL: nil),
            ],
            isTruncated: true
        )
        let review = AgentPRReviewSummary(
            decision: .approved,
            latestReviews: [
                AgentPRReview(authorLogin: "apps3000", state: .approved, submittedAt: nil, url: nil),
            ],
            threads: [],
            hasTruncatedThreads: true
        )
        let readiness = AgentPRMergeReadiness(isDraft: false, checks: checks, review: review)

        #expect(checks.state == .unknown)
        #expect(review.findingsState == .reviewPending)
        #expect(readiness.state == .waiting)
    }

    /// Verifies ready state requires green checks, approved review, no findings, and non-draft status.
    @Test func mergeReadinessRequiresGreenChecksApprovedReviewNoFindingsAndNonDraftPR() {
        let ready = AgentPRMergeReadiness(
            isDraft: false,
            checks: AgentPRCheckSummary(contexts: [
                AgentPRStatusContext(name: "build-and-test", state: .success, detailsURL: nil),
            ]),
            review: AgentPRReviewSummary(decision: .approved, latestReviews: [], threads: [])
        )

        let draft = AgentPRMergeReadiness(
            isDraft: true,
            checks: ready.checks,
            review: ready.review
        )

        #expect(ready.state == .ready)
        #expect(draft.state == .blocked)
    }

    /// Verifies the client fails locally and avoids network calls without a token.
    @Test func clientDoesNotCallTransportWithoutToken() async {
        let tokenStore = MemoryGitHubTokenStore(token: nil)
        let transport = RecordingGitHubTransport()
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.noToken) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.isEmpty)
    }

    /// Verifies REST-style rate-limit headers map to a typed rate-limit error.
    @Test func clientMapsRateLimitHeadersToTypedError() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "ghp_secret-token")
        let resetAt = Date(timeIntervalSince1970: 1_783_000_000)
        let transport = RecordingGitHubTransport(
            result: .response(
                Data(#"{"message":"rate limited"}"#.utf8),
                statusCode: 403,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "\(Int(resetAt.timeIntervalSince1970))",
                ]
            )
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.rateLimited(resetAt: resetAt)) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret-token")
    }

    /// Verifies the primary GraphQL request body and ready snapshot decoding.
    @Test func clientSendsTypedGraphQLVariablesAndDecodesSnapshot() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(Data(Self.graphQLReadyResponse.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let requestBody = try #require(transport.requests.first?.httpBody)
        let requestJSON = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let variables = try #require(requestJSON["variables"] as? [String: Any])
        #expect(variables["owner"] as? String == "apps3k-com")
        #expect(variables["repo"] as? String == "CodingBuddy")
        #expect(variables["first"] as? Int == 50)
        #expect(snapshot.rows.map(\.number) == [54])
        #expect(snapshot.rows.first?.source == .likelyAgent)
        #expect(snapshot.rows.first?.linkedIssues.map(\.number) == [54])
        #expect(snapshot.rows.first?.checks.state == .green)
        #expect(snapshot.rows.first?.readiness.state == .ready)
    }

    /// Verifies open pull request pagination follows GraphQL cursors past the first page.
    @Test func clientPaginatesOpenPullRequestsPastFirstPage() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(
                Data(Self.graphQLPageResponse(number: 54, hasNextPage: true, endCursor: "cursor-1").utf8),
                statusCode: 200,
                headers: [:]
            ),
            .response(
                Data(Self.graphQLPageResponse(number: 55, hasNextPage: false, endCursor: nil).utf8),
                statusCode: 200,
                headers: [:]
            ),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let secondBody = try #require(transport.requests.last?.httpBody)
        let secondJSON = try #require(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let secondVariables = try #require(secondJSON["variables"] as? [String: Any])
        #expect(snapshot.rows.map(\.number) == [54, 55])
        #expect(transport.requests.count == 2)
        #expect(secondVariables["after"] as? String == "cursor-1")
    }

    /// Verifies truncated GraphQL review and check connections never appear merge-ready.
    @Test func clientTreatsTruncatedGraphQLConnectionsAsNotReady() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(Data(Self.graphQLTruncatedResponse.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.checks.state == .unknown)
        #expect(row.review.findingsState == .reviewPending)
        #expect(row.readiness.state == .waiting)
        #expect(transport.requests.count == 1)
    }

    /// Verifies REST fallback fills missing GraphQL status rollups for visible rows.
    @Test func clientFallsBackToRESTWhenGraphQLStatusRollupIsMissing() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restCheckRunsResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restStatusesResponse.utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.headSHA == "abc123")
        #expect(row.checks.contexts.map(\.name) == ["build-and-test", "cubic"])
        #expect(row.checks.state == .failed)
        #expect(transport.requests.count == 3)
        #expect(transport.requests[1].url?.path == "/repos/apps3k-com/CodingBuddy/commits/abc123/check-runs")
        #expect(transport.requests[2].url?.path == "/repos/apps3k-com/CodingBuddy/commits/abc123/status")
    }

    /// Verifies GitHub transport failures map to safe, typed UI errors.
    @Test func clientMapsAuthenticationScopeRepositoryAndOfflineFailures() async {
        let invalidTokenTransport = RecordingGitHubTransport(
            result: .response(Data(#"{"message":"Bad credentials"}"#.utf8), statusCode: 401, headers: [:])
        )
        let invalidTokenClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: invalidTokenTransport
        )
        await #expect(throws: GitHubClientError.authenticationFailed) {
            try await invalidTokenClient.fetchOpenPullRequests(repository: repository)
        }

        let missingScopeTransport = RecordingGitHubTransport(
            result: .response(
                Data(#"{"message":"Resource not accessible by personal access token"}"#.utf8),
                statusCode: 403,
                headers: ["X-Accepted-GitHub-Permissions": "checks=read; pull_requests=read"]
            )
        )
        let missingScopeClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: missingScopeTransport
        )
        await #expect(throws: GitHubClientError.missingScope("checks=read; pull_requests=read")) {
            try await missingScopeClient.fetchOpenPullRequests(repository: repository)
        }

        let deniedTransport = RecordingGitHubTransport(
            result: .response(
                Data(#"{"message":"Resource not accessible by personal access token"}"#.utf8),
                statusCode: 403,
                headers: [:]
            )
        )
        let deniedClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: deniedTransport
        )
        await #expect(throws: GitHubClientError.repositoryDenied(repository)) {
            try await deniedClient.fetchOpenPullRequests(repository: repository)
        }

        let offlineClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: RecordingGitHubTransport(result: .failure(URLError(.notConnectedToInternet)))
        )
        await #expect(throws: GitHubClientError.networkUnavailable) {
            try await offlineClient.fetchOpenPullRequests(repository: repository)
        }
    }

    /// Verifies unknown GraphQL errors do not leak token contents into UI text.
    @Test func clientMapsUnknownGraphQLErrorToLocalizedSafeError() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(Data(Self.graphQLUnknownErrorResponse.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.githubError) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(!(GitHubClientError.githubError.errorDescription ?? "").contains("github_pat_secret"))
    }

    /// Verifies nullable GraphQL repository data maps to a repository access error.
    @Test func clientMapsNullRepositoryGraphQLResponseToAccessError() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(Data(Self.graphQLNullRepositoryResponse.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.repositoryDenied(repository)) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
    }

    /// Verifies the store shows token setup state without touching the network.
    @Test func storeRefreshWithoutTokenShowsSetupStateAndKeepsTransportUnused() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: nil)
        let transport = RecordingGitHubTransport()
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitForRefresh(in: store)

        #expect(store.state == .needsToken)
        #expect(store.rows.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    /// Verifies refresh failures keep the last successful snapshot visible.
    @Test func storeRefreshFailureKeepsLastSnapshot() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "ghp_secret-token")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 55)], rateLimit: nil)),
            .failure(.networkUnavailable),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitForRefresh(in: store)
        store.refresh()
        try await waitForRefresh(in: store)

        #expect(store.state == .refreshFailed(.networkUnavailable))
        #expect(store.rows.map(\.number) == [55])
        #expect(!store.debugDescription.contains("ghp_secret-token"))
    }

    /// Verifies switching repositories cancels stale refresh work and clears previous data.
    @Test func storeSelectingRepositoryCancelsInFlightRefreshAndClearsStaleData() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let staleSnapshot = AgentPRMonitorSnapshot(
            rows: [samplePullRequest(number: 58)],
            rateLimit: GitHubRateLimitState(remaining: 1, resetAt: Date(timeIntervalSince1970: 1_783_000_000))
        )
        let client = DelayedAgentPRMonitorClient(snapshot: staleSnapshot, delayNanoseconds: 200_000_000)
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )
        let otherRepository = GitHubRepositoryRef(owner: "apps3k-com", name: "Other")

        store.selectRepository(repository)
        store.refresh()
        try await waitUntilRefreshStarted(in: store)
        store.selectRepository(otherRepository)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(store.selectedRepository == otherRepository)
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(store.state == .idle)
        #expect(!store.isRefreshing)
    }

    /// Verifies token save success refreshes selected repositories and failures stay token-safe.
    @Test func storeSaveTokenRefreshesSelectedRepositoryAndDoesNotLeakStorageFailures() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: nil)
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 56)], rateLimit: nil)),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.saveToken("github_pat_secret")
        try await waitForRefresh(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.number) == [56])
        #expect(!store.debugDescription.contains("github_pat_secret"))

        let failingStore = AgentPRMonitorStore(
            tokenStore: FailingGitHubTokenStore(),
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )
        failingStore.selectRepository(repository)
        let didSave = failingStore.saveToken("github_pat_secret")

        #expect(!didSave)
        #expect(failingStore.state == .refreshFailed(.tokenStorageFailed))
        #expect(!(GitHubClientError.tokenStorageFailed.errorDescription ?? "").contains("github_pat_secret"))
    }

    /// Verifies a token saved in Settings refreshes the selected repository.
    @Test func storeSettingsTokenSaveRefreshesSelectedRepository() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 60)], rateLimit: nil)),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.handleGitHubAuthorizationChange(.saved)
        try await waitForRefresh(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.number) == [60])
    }

    /// Verifies removing the token in Settings clears monitor-only data.
    @Test func storeSettingsTokenRemovalClearsPrivateRowsAndRefreshMetadata() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(
                rows: [samplePullRequest(number: 61)],
                rateLimit: GitHubRateLimitState(remaining: 10, resetAt: nil)
            )),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitForRefresh(in: store)
        store.handleGitHubAuthorizationChange(.removed)

        #expect(store.state == .needsToken)
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(!store.isRefreshing)
    }

    /// Verifies deleting the token clears private row data and refresh metadata.
    @Test func storeDeleteTokenClearsPrivateRowsAndRefreshState() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(
                rows: [samplePullRequest(number: 57)],
                rateLimit: GitHubRateLimitState(remaining: 10, resetAt: nil)
            )),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitForRefresh(in: store)
        store.deleteToken()

        #expect(store.state == .needsToken)
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(!store.isRefreshing)
    }

    /// Verifies failed token deletion still stops any visible refresh state.
    @Test func storeFailedTokenDeleteStopsInFlightRefreshState() async throws {
        let staleSnapshot = AgentPRMonitorSnapshot(
            rows: [samplePullRequest(number: 59)],
            rateLimit: GitHubRateLimitState(remaining: 1, resetAt: nil)
        )
        let client = DelayedAgentPRMonitorClient(snapshot: staleSnapshot, delayNanoseconds: 200_000_000)
        let store = AgentPRMonitorStore(
            tokenStore: FailingGitHubTokenStore(),
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitUntilRefreshStarted(in: store)
        store.deleteToken()
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(store.state == .refreshFailed(.tokenStorageFailed))
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(!store.isRefreshing)
    }

    /// Builds a ready pull request fixture with a deterministic number.
    private func samplePullRequest(number: Int) -> AgentPullRequest {
        AgentPullRequest(
            repository: repository,
            number: number,
            title: "docs: document native Agent PR Monitor architecture design",
            url: URL(string: "https://github.com/apps3k-com/CodingBuddy/pull/\(number)")!,
            isDraft: false,
            authorLogin: "apps3000",
            source: .likelyAgent,
            headRefName: "bvk/agent-pr-monitor-design",
            headSHA: "605f0a3",
            baseRefName: "main",
            linkedIssues: [
                AgentPRLinkedIssue(
                    number: 45,
                    title: "Stage 2: design native Agent PR Monitor",
                    url: URL(string: "https://github.com/apps3k-com/CodingBuddy/issues/45")!,
                    state: .open
                ),
            ],
            review: AgentPRReviewSummary(decision: .approved, latestReviews: [], threads: []),
            checks: AgentPRCheckSummary(contexts: [
                AgentPRStatusContext(name: "build-and-test", state: .success, detailsURL: nil),
            ]),
            updatedAt: Date(timeIntervalSince1970: 1_783_000_000)
        )
    }

    /// Waits for a refresh to finish and records a test issue on timeout.
    private func waitForRefresh(in store: AgentPRMonitorStore) async throws {
        var sawRefresh = store.isRefreshing
        var sawRefreshState = store.state != .idle
        for _ in 0..<100 {
            sawRefresh = sawRefresh || store.isRefreshing
            sawRefreshState = sawRefreshState || store.state != .idle
            if !store.isRefreshing && (sawRefresh || sawRefreshState) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for AgentPRMonitorStore refresh to finish")
    }

    /// Waits until a refresh starts before a cancellation-focused assertion.
    private func waitUntilRefreshStarted(in store: AgentPRMonitorStore) async throws {
        for _ in 0..<100 {
            if store.isRefreshing {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for AgentPRMonitorStore refresh to start")
    }

    /// Builds a paginated GraphQL response fixture for open pull request pages.
    private static func graphQLPageResponse(number: Int, hasNextPage: Bool, endCursor: String?) -> String {
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        let next = hasNextPage ? "true" : "false"
        return """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "pageInfo": { "hasNextPage": \(next), "endCursor": \(cursor) },
                "nodes": [
                  {
                    "number": \(number),
                    "title": "feat: add native Agent PR Monitor for coding-agent pull requests",
                    "url": "https://github.com/apps3k-com/CodingBuddy/pull/\(number)",
                    "isDraft": false,
                    "updatedAt": "2026-06-28T10:20:00Z",
                    "author": { "login": "apps3000" },
                    "headRefName": "bvk/agent-pr-monitor-v1",
                    "headRefOid": "abc123",
                    "baseRefName": "main",
                    "closingIssuesReferences": { "nodes": [] },
                    "reviewDecision": "APPROVED",
                    "latestReviews": { "nodes": [] },
                    "reviewThreads": { "nodes": [] },
                    "commits": {
                      "nodes": [
                        {
                          "commit": {
                            "oid": "abc123",
                            "statusCheckRollup": {
                              "contexts": {
                                "nodes": [
                                  {
                                    "__typename": "CheckRun",
                                    "name": "build-and-test",
                                    "status": "COMPLETED",
                                    "conclusion": "SUCCESS",
                                    "detailsUrl": "https://github.com/apps3k-com/CodingBuddy/actions/runs/1"
                                  }
                                ]
                              }
                            }
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            },
            "rateLimit": { "remaining": 4999, "resetAt": "2026-06-28T11:00:00Z" }
          }
        }
        """
    }

    /// GraphQL fixture for one fully ready pull request.
    private static let graphQLReadyResponse = """
    {
      "data": {
        "repository": {
          "pullRequests": {
            "nodes": [
              {
                "number": 54,
                "title": "feat: add native Agent PR Monitor for coding-agent pull requests",
                "url": "https://github.com/apps3k-com/CodingBuddy/pull/54",
                "isDraft": false,
                "updatedAt": "2026-06-28T10:20:00Z",
                "author": { "login": "coderabbitai[bot]" },
                "headRefName": "bvk/agent-pr-monitor-v1",
                "headRefOid": "abc123",
                "baseRefName": "main",
                "closingIssuesReferences": {
                  "nodes": [
                    {
                      "number": 54,
                      "title": "Stage 2: implement native Agent PR Monitor v1",
                      "url": "https://github.com/apps3k-com/CodingBuddy/issues/54",
                      "state": "OPEN"
                    }
                  ]
                },
                "reviewDecision": "APPROVED",
                "latestReviews": {
                  "nodes": [
                    {
                      "author": { "login": "apps3000" },
                      "state": "APPROVED",
                      "submittedAt": "2026-06-28T10:21:00Z",
                      "url": "https://github.com/apps3k-com/CodingBuddy/pull/54#pullrequestreview-1"
                    }
                  ]
                },
                "reviewThreads": { "nodes": [] },
                "commits": {
                  "nodes": [
                    {
                      "commit": {
                        "oid": "abc123",
                        "statusCheckRollup": {
                          "contexts": {
                            "nodes": [
                              {
                                "__typename": "CheckRun",
                                "name": "build-and-test",
                                "status": "COMPLETED",
                                "conclusion": "SUCCESS",
                                "detailsUrl": "https://github.com/apps3k-com/CodingBuddy/actions/runs/1"
                              }
                            ]
                          }
                        }
                      }
                    }
                  ]
                }
              }
            ]
          }
        },
        "rateLimit": { "remaining": 4999, "resetAt": "2026-06-28T11:00:00Z" }
      }
    }
    """

    /// GraphQL fixture with truncated review-thread and status-check connections.
    private static let graphQLTruncatedResponse = """
    {
      "data": {
        "repository": {
          "pullRequests": {
            "nodes": [
              {
                "number": 54,
                "title": "feat: add native Agent PR Monitor for coding-agent pull requests",
                "url": "https://github.com/apps3k-com/CodingBuddy/pull/54",
                "isDraft": false,
                "updatedAt": "2026-06-28T10:20:00Z",
                "author": { "login": "apps3000" },
                "headRefName": "bvk/agent-pr-monitor-v1",
                "headRefOid": "abc123",
                "baseRefName": "main",
                "closingIssuesReferences": { "nodes": [] },
                "reviewDecision": "APPROVED",
                "latestReviews": { "nodes": [] },
                "reviewThreads": {
                  "nodes": [],
                  "pageInfo": { "hasNextPage": true }
                },
                "commits": {
                  "nodes": [
                    {
                      "commit": {
                        "oid": "abc123",
                        "statusCheckRollup": {
                          "contexts": {
                            "nodes": [
                              {
                                "__typename": "CheckRun",
                                "name": "build-and-test",
                                "status": "COMPLETED",
                                "conclusion": "SUCCESS",
                                "detailsUrl": "https://github.com/apps3k-com/CodingBuddy/actions/runs/1"
                              }
                            ],
                            "pageInfo": { "hasNextPage": true }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            ]
          }
        },
        "rateLimit": { "remaining": 4998, "resetAt": "2026-06-28T11:00:00Z" }
      }
    }
    """

    /// GraphQL fixture requiring REST status fallback.
    private static let graphQLMissingStatusResponse = """
    {
      "data": {
        "repository": {
          "pullRequests": {
            "nodes": [
              {
                "number": 54,
                "title": "feat: add native Agent PR Monitor for coding-agent pull requests",
                "url": "https://github.com/apps3k-com/CodingBuddy/pull/54",
                "isDraft": false,
                "updatedAt": "2026-06-28T10:20:00Z",
                "author": { "login": "apps3000" },
                "headRefName": "bvk/agent-pr-monitor-v1",
                "headRefOid": "abc123",
                "baseRefName": "main",
                "closingIssuesReferences": { "nodes": [] },
                "reviewDecision": "APPROVED",
                "latestReviews": { "nodes": [] },
                "reviewThreads": { "nodes": [] },
                "commits": {
                  "nodes": [
                    {
                      "commit": {
                        "oid": "abc123",
                        "statusCheckRollup": null
                      }
                    }
                  ]
                }
              }
            ]
          }
        },
        "rateLimit": { "remaining": 4998, "resetAt": "2026-06-28T11:00:00Z" }
      }
    }
    """

    /// REST check-runs fixture used by fallback tests.
    private static let restCheckRunsResponse = """
    {
      "check_runs": [
        {
          "name": "build-and-test",
          "status": "COMPLETED",
          "conclusion": "SUCCESS",
          "details_url": "https://github.com/apps3k-com/CodingBuddy/actions/runs/1"
        }
      ]
    }
    """

    /// REST combined-status fixture used by fallback tests.
    private static let restStatusesResponse = """
    {
      "statuses": [
        {
          "context": "cubic",
          "state": "FAILURE",
          "target_url": "https://github.com/apps3k-com/CodingBuddy/statuses/cubic"
        }
      ]
    }
    """

    /// GraphQL fixture with an unsafe provider error string.
    private static let graphQLUnknownErrorResponse = """
    {
      "errors": [
        { "message": "upstream echoed github_pat_secret in a provider error" }
      ]
    }
    """

    /// GraphQL fixture with nullable repository data and an access-style error.
    private static let graphQLNullRepositoryResponse = """
    {
      "data": {
        "repository": null,
        "rateLimit": { "remaining": 4998, "resetAt": "2026-06-28T11:00:00Z" }
      },
      "errors": [
        { "message": "Could not resolve to a Repository with the name 'CodingBuddy'." }
      ]
    }
    """
}

/// In-memory token store test double.
private final class MemoryGitHubTokenStore: GitHubTokenStore, @unchecked Sendable {
    /// Current token value returned by `loadToken()`.
    private var token: String?

    /// Creates the store with an optional initial token.
    init(token: String?) {
        self.token = token
    }

    /// Returns the current in-memory token.
    func loadToken() throws -> String? {
        token
    }

    /// Replaces the current in-memory token.
    func saveToken(_ token: String) throws {
        self.token = token
    }

    /// Removes the current in-memory token.
    func deleteToken() throws {
        token = nil
    }
}

/// Token store test double that fails every persistence operation.
private struct FailingGitHubTokenStore: GitHubTokenStore {
    /// Returns no token so tests can focus on save/delete failures.
    func loadToken() throws -> String? {
        nil
    }

    /// Always throws a token-like failure string to verify leak protection.
    func saveToken(_ token: String) throws {
        throw Failure()
    }

    /// Always throws a token-like failure string to verify leak protection.
    func deleteToken() throws {
        throw Failure()
    }

    /// Synthetic Keychain-like failure used by the failing token store.
    private struct Failure: LocalizedError {
        /// Error text intentionally contains a fake token to exercise sanitization.
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
}

/// HTTP transport test double that records requests and returns queued responses.
private final class RecordingGitHubTransport: GitHubTransport, @unchecked Sendable {
    /// Queued transport result.
    enum Result {
        /// HTTP response data, status, and headers.
        case response(Data, statusCode: Int, headers: [String: String])
        /// Transport-level failure.
        case failure(Error)
    }

    /// Pending transport results.
    private var results: [Result]
    /// Requests received by the transport.
    private var recordedRequests: [URLRequest] = []
    /// Lock protecting result and request arrays.
    private let lock = NSLock()

    /// Creates a transport with one queued result.
    init(result: Result = .failure(URLError(.cancelled))) {
        results = [result]
    }

    /// Creates a transport with several queued results.
    init(results: [Result]) {
        self.results = results
    }

    /// Requests recorded so far.
    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// Returns the next queued response and records the request.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = lock.withLock {
            recordedRequests.append(request)
            if results.isEmpty {
                return Result.failure(URLError(.cancelled))
            }
            return results.removeFirst()
        }

        switch result {
        case .response(let data, let statusCode, let headers):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

/// In-memory defaults test double for repository persistence.
private final class MemoryAgentPRMonitorDefaults: AgentPRMonitorDefaultsStoring {
    /// Stored key-value pairs.
    private var values: [String: String] = [:]

    /// Returns the stored string for a key.
    func string(forKey defaultName: String) -> String? {
        values[defaultName]
    }

    /// Stores a string for a key.
    func setAgentPRMonitorString(_ value: String, forKey defaultName: String) {
        values[defaultName] = value
    }

    /// Removes a stored key.
    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

/// Agent PR Monitor client test double with queued results.
private final class StubAgentPRMonitorClient: AgentPRMonitorFetching, @unchecked Sendable {
    /// Pending fetch results.
    private var results: [Result<AgentPRMonitorSnapshot, GitHubClientError>]
    /// Lock protecting the queued results.
    private let lock = NSLock()

    /// Creates a stub with deterministic queued results.
    init(results: [Result<AgentPRMonitorSnapshot, GitHubClientError>]) {
        self.results = results
    }

    /// Returns the next queued snapshot or error.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot {
        try lock.withLock {
            if results.isEmpty {
                throw GitHubClientError.networkUnavailable
            }
            return try results.removeFirst().get()
        }
    }
}

/// Agent PR Monitor client test double that suspends before returning.
private final class DelayedAgentPRMonitorClient: AgentPRMonitorFetching, @unchecked Sendable {
    /// Snapshot returned after the delay.
    private let snapshot: AgentPRMonitorSnapshot
    /// Delay used to keep the refresh task in flight.
    private let delayNanoseconds: UInt64

    /// Creates a delayed client with one fixed snapshot.
    init(snapshot: AgentPRMonitorSnapshot, delayNanoseconds: UInt64) {
        self.snapshot = snapshot
        self.delayNanoseconds = delayNanoseconds
    }

    /// Waits for the configured delay, honors cancellation, then returns the snapshot.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        return snapshot
    }
}
