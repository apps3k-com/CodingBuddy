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

    /// Verifies a missing provider decision cannot become approved from truncated latest reviews.
    @Test func truncatedLatestReviewsWithoutDecisionStayPending() {
        let review = AgentPRReviewSummary(
            decision: .none,
            latestReviews: [
                AgentPRReview(authorLogin: "apps3000", state: .approved, submittedAt: nil, url: nil),
            ],
            threads: [],
            hasTruncatedLatestReviews: true
        )

        #expect(review.state == .unknown)
        #expect(review.findingsState == .reviewPending)
    }

    /// Verifies an approved provider decision cannot hide unseen latest reviews.
    @Test func truncatedLatestReviewsOverrideApprovedDecision() {
        let review = AgentPRReviewSummary(
            decision: .approved,
            latestReviews: [
                AgentPRReview(authorLogin: "apps3000", state: .approved, submittedAt: nil, url: nil),
            ],
            threads: [],
            hasTruncatedLatestReviews: true
        )

        #expect(review.state == .unknown)
        #expect(review.findingsState == .reviewPending)
    }

    /// Verifies pull request search covers the owning repository.
    @Test func pullRequestSearchMatchesRepositoryName() {
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let row = samplePullRequest(number: 12, repository: website)

        #expect(row.matches(searchText: "Website"))
        #expect(row.matches(searchText: "apps3k-com/Website"))
        #expect(row.url.absoluteString == "https://github.com/apps3k-com/Website/pull/12")
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

    /// Verifies token load failures stay local, typed, and recoverable through Settings.
    @Test func clientMapsTokenLoadFailureWithoutCallingTransport() async {
        let transport = RecordingGitHubTransport()
        let client = GitHubClient(tokenStore: LoadFailingGitHubTokenStore(), transport: transport)

        await #expect(throws: GitHubClientError.tokenLoadFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.isEmpty)
        #expect(GitHubClientError.tokenLoadFailed.isGitHubAuthorizationRecoverable)
        #expect(!(GitHubClientError.tokenLoadFailed.errorDescription ?? "").contains("github_pat_secret"))
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

    /// Verifies the monitor rotates an expired App credential through the shared coordinator.
    @Test func clientUsesRotatedCredentialForMonitorRequest() async throws {
        let oldCredential = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: .distantPast,
            refreshTokenExpiresAt: .distantFuture
        )
        let credentialStore = MonitorCredentialStore(credential: oldCredential)
        let oauthTransport = MonitorOAuthRefreshTransport()
        let oauthClient = GitHubOAuthDeviceFlowClient(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1TestClient",
                deviceCodeEndpoint: URL(string: "https://github.com/login/device/code")!,
                accessTokenEndpoint: URL(string: "https://github.com/login/oauth/access_token")!
            ),
            transport: oauthTransport
        )
        let coordinator = GitHubCredentialCoordinator(
            tokenStore: credentialStore,
            oauthClient: oauthClient
        )
        let apiTransport = RecordingGitHubTransport(
            result: .response(Data(Self.graphQLReadyResponse.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(
            credentialCoordinator: coordinator,
            transport: apiTransport
        )

        _ = try await client.fetchOpenPullRequests(repository: repository)

        #expect(oauthTransport.requestCount == 1)
        #expect(credentialStore.credential?.accessToken == "new-access")
        #expect(apiTransport.requests.count == 1)
        #expect(apiTransport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
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

    /// Verifies a multi-page cursor cycle fails instead of refreshing forever.
    @Test func clientRejectsOpenPullRequestCursorCycles() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLPageResponse(number: 54, hasNextPage: true, endCursor: "A").utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.graphQLPageResponse(number: 55, hasNextPage: true, endCursor: "B").utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.graphQLPageResponse(number: 56, hasNextPage: true, endCursor: "A").utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.decodingFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 3)
    }

    /// Verifies the same pull request cannot appear on shifted pagination pages.
    @Test func clientRejectsDuplicatePullRequestsAcrossPages() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLPageResponse(number: 54, hasNextPage: true, endCursor: "A").utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.graphQLPageResponse(number: 54, hasNextPage: false, endCursor: nil).utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.decodingFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 2)
    }

    /// Verifies aggregate node budgets fail closed before publishing a partial queue.
    @Test func clientEnforcesOpenPullRequestNodeBudget() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLPageResponse(number: 54, hasNextPage: true, endCursor: "A").utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.graphQLPageResponse(number: 55, hasNextPage: false, endCursor: nil).utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(
            tokenStore: tokenStore,
            transport: transport,
            maximumPullRequestNodes: 1
        )

        await #expect(throws: GitHubClientError.decodingFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 2)
    }

    /// Verifies page exhaustion stops before an additional GraphQL request.
    @Test func clientEnforcesOpenPullRequestPageBudget() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(
                Data(Self.graphQLPageResponse(number: 54, hasNextPage: true, endCursor: "A").utf8),
                statusCode: 200,
                headers: [:]
            )
        )
        let client = GitHubClient(
            tokenStore: tokenStore,
            transport: transport,
            pullRequestPageLimit: 1
        )

        await #expect(throws: GitHubClientError.decodingFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 1)
    }

    /// Verifies an oversized GraphQL page is rejected before JSON decoding.
    @Test func clientEnforcesOpenPullRequestByteBudget() async {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let data = Data(Self.graphQLPageResponse(number: 54, hasNextPage: false, endCursor: nil).utf8)
        let transport = RecordingGitHubTransport(
            result: .response(data, statusCode: 200, headers: [:])
        )
        let client = GitHubClient(
            tokenStore: tokenStore,
            transport: transport,
            maximumPullRequestBytes: max(1_024, data.count - 1)
        )

        await #expect(throws: GitHubClientError.decodingFailed) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.count == 1)
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

    /// Verifies GraphQL review coverage prevents approval when the decision is absent.
    @Test func clientTreatsTruncatedLatestReviewsWithoutDecisionAsNotReady() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(
                Data(Self.graphQLTruncatedLatestReviewsWithoutDecisionResponse.utf8),
                statusCode: 200,
                headers: [:]
            )
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        let requestBody = try #require(transport.requests.first?.httpBody)
        let requestJSON = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let query = try #require(requestJSON["query"] as? String)
        #expect(query.contains("latestReviews(first: 100)"))
        #expect(row.review.decision == .none)
        #expect(row.review.hasTruncatedLatestReviews)
        #expect(row.review.state == .unknown)
        #expect(row.review.findingsState == .reviewPending)
        #expect(row.readiness.state == .waiting)
    }

    /// Verifies decoded approved decisions remain pending when latest reviews are incomplete.
    @Test func clientTreatsApprovedDecisionWithTruncatedLatestReviewsAsNotReady() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let response = Self.graphQLTruncatedLatestReviewsWithoutDecisionResponse.replacingOccurrences(
            of: #""reviewDecision": null"#,
            with: #""reviewDecision": "APPROVED""#
        )
        let transport = RecordingGitHubTransport(
            result: .response(Data(response.utf8), statusCode: 200, headers: [:])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.review.decision == .approved)
        #expect(row.review.hasTruncatedLatestReviews)
        #expect(row.review.state == .unknown)
        #expect(row.review.findingsState == .reviewPending)
        #expect(row.readiness.state == .waiting)
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

    /// Verifies combined-status total_count fetches a later page containing a failure.
    @Test func clientPaginatesRESTStatusesWhenTotalCountExceedsFirstPage() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restCheckRunsResponse.utf8), statusCode: 200, headers: [:]),
            .response(
                Data(Self.restStatusesPage(totalCount: 2, context: "cubic", state: "SUCCESS").utf8),
                statusCode: 200,
                headers: [:]
            ),
            .response(
                Data(Self.restStatusesPage(totalCount: 2, context: "security", state: "FAILURE").utf8),
                statusCode: 200,
                headers: [:]
            ),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        let statusRequests = transport.requests.filter { $0.url?.path.hasSuffix("/status") == true }
        let requestedPages = statusRequests.compactMap { request -> String? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            return components.queryItems?.first { $0.name == "page" }?.value
        }
        #expect(statusRequests.allSatisfy { request in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return false
            }
            return components.queryItems?.first { $0.name == "per_page" }?.value == "100"
        })
        #expect(requestedPages == ["1", "2"])
        #expect(row.checks.contexts.map(\.name) == ["build-and-test", "cubic", "security"])
        #expect(row.checks.state == .failed)
        #expect(row.readiness.state == .attentionNeeded)
    }

    /// Verifies a shifted page that repeats a context cannot numerically satisfy total_count.
    @Test func clientFailsClosedWhenRESTStatusPaginationRepeatsContext() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restCheckRunsResponse.utf8), statusCode: 200, headers: [:]),
            .response(
                Data(Self.restStatusesPage(
                    totalCount: 2,
                    context: "cubic",
                    state: "SUCCESS",
                    combinedState: "SUCCESS"
                ).utf8),
                statusCode: 200,
                headers: [:]
            ),
            .response(
                Data(Self.restStatusesPage(
                    totalCount: 2,
                    context: "CUBIC",
                    state: "SUCCESS",
                    combinedState: "SUCCESS"
                ).utf8),
                statusCode: 200,
                headers: [:]
            ),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.checks.contexts.map(\.name) == ["build-and-test", "cubic"])
        #expect(row.checks.isTruncated)
        #expect(row.checks.state == .unknown)
        #expect(row.readiness.state == .waiting)
        #expect(transport.requests.count == 4)
    }

    /// Verifies GitHub's global combined state cannot disagree with the fetched contexts.
    @Test func clientFailsClosedWhenRESTCombinedStateDisagreesWithContexts() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restCheckRunsResponse.utf8), statusCode: 200, headers: [:]),
            .response(
                Data(Self.restStatusesPage(
                    totalCount: 1,
                    context: "cubic",
                    state: "SUCCESS",
                    combinedState: "FAILURE"
                ).utf8),
                statusCode: 200,
                headers: [:]
            ),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.checks.isTruncated)
        #expect(row.checks.state == .unknown)
        #expect(row.readiness.state == .waiting)
    }

    /// Verifies an unfetched Link page makes visible green REST statuses unknown.
    @Test func clientFailsClosedWhenRESTStatusPageLimitLeavesNextLink() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let nextLink = #"<https://api.github.com/repos/apps3k-com/CodingBuddy/commits/abc123/status?per_page=100&page=2>; rel="next""#
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restCheckRunsResponse.utf8), statusCode: 200, headers: [:]),
            .response(
                Data(Self.restStatusesPage(totalCount: nil, context: "cubic", state: "SUCCESS").utf8),
                statusCode: 200,
                headers: ["Link": nextLink]
            ),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport, statusPageLimit: 1)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.checks.contexts.map(\.name) == ["build-and-test", "cubic"])
        #expect(row.checks.isTruncated)
        #expect(row.checks.state == .unknown)
        #expect(row.readiness.state == .waiting)
        #expect(transport.requests.count == 3)
    }

    /// Verifies check-run total_count prevents a false green result when Link is absent.
    @Test func clientFailsClosedWhenRESTCheckRunCountExceedsFetchedPage() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let truncatedChecks = Self.restCheckRunsResponse.replacingOccurrences(
            of: #""total_count": 1"#,
            with: #""total_count": 2"#
        )
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.graphQLMissingStatusResponse.utf8), statusCode: 200, headers: [:]),
            .response(Data(truncatedChecks.utf8), statusCode: 200, headers: [:]),
            .response(Data(Self.restEmptyStatusesResponse.utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let snapshot = try await client.fetchOpenPullRequests(repository: repository)

        let row = try #require(snapshot.rows.first)
        #expect(row.checks.contexts.map(\.name) == ["build-and-test"])
        #expect(row.checks.isTruncated)
        #expect(row.checks.state == .unknown)
        #expect(row.readiness.state == .waiting)
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
        #expect(GitHubClientError.repositoryDenied(repository).isGitHubAuthorizationRecoverable)
    }

    /// Verifies repository picker REST requests and response decoding.
    @Test func clientListsAccessibleRepositoriesAndSendsRepositoryListRequest() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let transport = RecordingGitHubTransport(
            result: .response(Data(Self.restRepositoryListResponse.utf8), statusCode: 200, headers: [
                "X-RateLimit-Remaining": "42",
            ])
        )
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        let list = try await client.fetchAccessibleRepositories()

        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        #expect(url.path == "/user/repos")
        #expect(queryItems.first { $0.name == "visibility" }?.value == "all")
        #expect(queryItems.first { $0.name == "affiliation" }?.value == "owner,collaborator,organization_member")
        #expect(queryItems.first { $0.name == "sort" }?.value == "full_name")
        #expect(queryItems.first { $0.name == "per_page" }?.value == "100")
        #expect(queryItems.first { $0.name == "page" }?.value == "1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_secret")
        #expect(list.repositories.map(\.displayName) == ["apps3k-com/CodingBuddy", "apps3k-com/Website"])
        #expect(list.repositories.first?.description == "Native macOS environment helper")
        #expect(list.repositories.first?.isPrivate == true)
        #expect(list.repositories.first?.matches(searchText: "codingbuddy") == true)
        #expect(list.repositories.first?.matches(searchText: "apps3k-com/CodingBuddy") == true)
        #expect(list.rateLimit?.remaining == 42)
        #expect(!list.isTruncated)
    }

    /// Verifies repository picker pagination stops at the configured cap.
    @Test func clientCapsRepositoryListPagination() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let nextLink = #"<https://api.github.com/user/repos?page=3>; rel="next""#
        let transport = RecordingGitHubTransport(results: [
            .response(Data(Self.restRepositoryPage(owner: "apps3k-com", name: "One").utf8), statusCode: 200, headers: [
                "Link": nextLink,
            ]),
            .response(Data(Self.restRepositoryPage(owner: "apps3k-com", name: "Two").utf8), statusCode: 200, headers: [
                "Link": nextLink,
            ]),
            .response(Data(Self.restRepositoryPage(owner: "apps3k-com", name: "Three").utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubClient(tokenStore: tokenStore, transport: transport, repositoryPageLimit: 2)

        let list = try await client.fetchAccessibleRepositories()

        let requestedPages = transport.requests.compactMap { request -> String? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            return components.queryItems?.first { $0.name == "page" }?.value
        }
        #expect(list.repositories.map(\.displayName) == ["apps3k-com/One", "apps3k-com/Two"])
        #expect(requestedPages == ["1", "2"])
        #expect(list.isTruncated)
    }

    /// Verifies repository picker token, scope, and rate-limit failures stay typed.
    @Test func clientMapsRepositoryListFailures() async {
        let noTokenClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: nil),
            transport: RecordingGitHubTransport()
        )
        await #expect(throws: GitHubClientError.noToken) {
            try await noTokenClient.fetchAccessibleRepositories()
        }

        let missingScopeClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: RecordingGitHubTransport(result: .response(
                Data(#"{"message":"Resource not accessible by personal access token"}"#.utf8),
                statusCode: 403,
                headers: ["X-Accepted-GitHub-Permissions": "metadata=read"]
            ))
        )
        await #expect(throws: GitHubClientError.missingScope("metadata=read")) {
            try await missingScopeClient.fetchAccessibleRepositories()
        }

        let resetAt = Date(timeIntervalSince1970: 1_783_000_000)
        let rateLimitedClient = GitHubClient(
            tokenStore: MemoryGitHubTokenStore(token: "github_pat_secret"),
            transport: RecordingGitHubTransport(result: .response(
                Data(#"{"message":"rate limit exceeded"}"#.utf8),
                statusCode: 429,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "\(Int(resetAt.timeIntervalSince1970))",
                ]
            ))
        )
        await #expect(throws: GitHubClientError.rateLimited(resetAt: resetAt)) {
            try await rateLimitedClient.fetchAccessibleRepositories()
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
        try await waitUntilRefreshStopped(in: store)

        #expect(store.selectedRepository == otherRepository)
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(store.state == .idle)
        #expect(!store.isRefreshing)
    }

    /// Verifies repository choices load through the injected client and selected values persist.
    @Test func storeLoadsRepositoryChoicesAndPersistsSelection() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let defaults = MemoryAgentPRMonitorDefaults()
        let rateLimit = GitHubRateLimitState(remaining: 77, resetAt: Date(timeIntervalSince1970: 1_783_000_000))
        let repositoryChoices = [
            GitHubRepositorySummary(
                ref: repository,
                description: "Native macOS environment helper",
                isPrivate: true,
                isArchived: false,
                pushedAt: nil
            ),
            GitHubRepositorySummary(
                ref: GitHubRepositoryRef(owner: "apps3k-com", name: "Website"),
                description: nil,
                isPrivate: false,
                isArchived: false,
                pushedAt: nil
            ),
        ]
        let client = StubAgentPRMonitorClient(
            results: [],
            repositoryResults: [
                .success(GitHubRepositoryList(
                    repositories: repositoryChoices,
                    rateLimit: rateLimit,
                    isTruncated: true
                )),
            ]
        )
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: defaults
        )

        store.loadRepositoryChoices()
        try await waitForRepositoryChoices(in: store)
        store.selectRepository(repositoryChoices[1].ref)
        let restoredStore = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: StubAgentPRMonitorClient(results: []),
            defaults: defaults
        )

        #expect(store.repositoryPickerState == .loaded)
        #expect(store.repositoryChoices == repositoryChoices)
        #expect(store.repositoryPickerRateLimit == rateLimit)
        #expect(store.repositoryChoicesAreTruncated)
        #expect(store.selectedRepository == repositoryChoices[1].ref)
        #expect(restoredStore.selectedRepository == repositoryChoices[1].ref)
    }

    /// Verifies multi-repository watchlists migrate old selections and persist edits.
    @Test func storeMigratesSelectedRepositoryToWatchedRepositoriesAndPersistsEdits() {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let defaults = MemoryAgentPRMonitorDefaults()
        defaults.setAgentPRMonitorString(repository.displayName, forKey: AgentPRMonitorStore.repositoryKey)
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let docs = GitHubRepositoryRef(owner: "apps3k-com", name: "Docs")
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: StubAgentPRMonitorClient(results: []),
            defaults: defaults
        )

        store.addWatchedRepository(website)
        store.addWatchedRepository(repository)
        store.addWatchedRepository(docs)
        store.removeWatchedRepository(website)
        let restoredStore = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: StubAgentPRMonitorClient(results: []),
            defaults: defaults
        )

        #expect(store.watchedRepositories == [repository, docs])
        #expect(restoredStore.watchedRepositories == [repository, docs])
        #expect(defaults.string(forKey: AgentPRMonitorStore.repositoryKey) == nil)
        #expect(defaults.string(forKey: AgentPRMonitorStore.watchedRepositoriesKey) == "apps3k-com/CodingBuddy\napps3k-com/Docs")
    }

    /// Verifies persisted and newly added GitHub case variants resolve to one watchlist identity.
    @Test func storeDeduplicatesAndRemovesRepositoriesCaseInsensitively() {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let defaults = MemoryAgentPRMonitorDefaults()
        defaults.setAgentPRMonitorString(
            "Apps3K-Com/CodingBuddy\napps3k-com/codingbuddy",
            forKey: AgentPRMonitorStore.watchedRepositoriesKey
        )
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: StubAgentPRMonitorClient(results: []),
            defaults: defaults
        )
        let lowercase = GitHubRepositoryRef(owner: "apps3k-com", name: "codingbuddy")

        store.addWatchedRepository(lowercase)

        #expect(store.watchedRepositories.count == 1)
        #expect(store.watchedRepositories.first?.displayName == "Apps3K-Com/CodingBuddy")

        store.removeWatchedRepository(lowercase)

        #expect(store.watchedRepositories.isEmpty)
        #expect(defaults.string(forKey: AgentPRMonitorStore.watchedRepositoriesKey) == nil)
    }

    /// Verifies adding the first repository after clearing setup leaves the monitor refreshable.
    @Test func storeAddingFirstRepositoryAfterClearResetsSetupState() {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: StubAgentPRMonitorClient(results: []),
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.clearRepository()
        store.addWatchedRepository(website)

        #expect(store.state == .idle)
        #expect(store.selectedRepository == website)
        #expect(store.repositoryRefreshStates[website] == .idle)
    }

    /// Verifies refreshes aggregate successful repositories while keeping per-repository failures visible.
    @Test func storeRefreshAggregatesWatchedRepositoriesAndKeepsPartialFailuresScoped() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 66)], rateLimit: nil)),
            .failure(.repositoryDenied(website)),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.addWatchedRepository(repository)
        store.addWatchedRepository(website)
        store.refresh()
        try await waitForRefresh(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.id) == ["apps3k-com/CodingBuddy#66"])
        #expect(store.repositoryRefreshStates[repository] == .loaded)
        #expect(store.repositoryRefreshStates[website] == .refreshFailed(.repositoryDenied(website)))
        guard case .partial(let completedAt, let incompleteRepositories) = store.queueCoverage else {
            Issue.record("Expected partial queue coverage after one repository failed")
            return
        }
        #expect(completedAt != nil)
        #expect(incompleteRepositories == [website])
    }

    /// Verifies partial refresh failures keep that repository's last visible rows.
    @Test func storeRefreshFailureKeepsCachedRowsForFailedWatchedRepository() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 66)], rateLimit: nil)),
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 12, repository: website)], rateLimit: nil)),
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 67)], rateLimit: nil)),
            .failure(.repositoryDenied(website)),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.addWatchedRepository(repository)
        store.addWatchedRepository(website)
        store.refresh()
        try await waitForRefresh(in: store)
        store.refresh()
        try await waitForRefresh(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.id) == ["apps3k-com/CodingBuddy#67", "apps3k-com/Website#12"])
        #expect(store.repositoryRefreshStates[repository] == .loaded)
        #expect(store.repositoryRefreshStates[website] == .refreshFailed(.repositoryDenied(website)))
    }

    /// Verifies successful refreshes show rows from every watched repository.
    @Test func storeRefreshAggregatesRowsAcrossWatchedRepositories() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let client = StubAgentPRMonitorClient(results: [
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 66)], rateLimit: nil)),
            .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 12, repository: website)], rateLimit: nil)),
        ])
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.addWatchedRepository(repository)
        store.addWatchedRepository(website)
        store.refresh()
        try await waitForRefresh(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.id) == ["apps3k-com/CodingBuddy#66", "apps3k-com/Website#12"])
        #expect(store.repositoryRefreshStates[repository] == .loaded)
        #expect(store.repositoryRefreshStates[website] == .loaded)
        guard case .complete(let completedAt) = store.queueCoverage else {
            Issue.record("Expected complete queue coverage after every repository loaded")
            return
        }
        #expect(completedAt <= Date())
    }

    /// Verifies removing a repository while refreshing resets loading states for remaining entries.
    @Test func storeRemovingRepositoryDuringRefreshReconcilesRemainingLoadingStates() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let website = GitHubRepositoryRef(owner: "apps3k-com", name: "Website")
        let delayedSnapshot = AgentPRMonitorSnapshot(rows: [], rateLimit: nil)
        let client = DelayedAgentPRMonitorClient(snapshot: delayedSnapshot, delayNanoseconds: 200_000_000)
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.addWatchedRepository(repository)
        store.addWatchedRepository(website)
        store.refresh()
        try await waitUntilRefreshStarted(in: store)
        store.removeWatchedRepository(repository)
        try await waitUntilRefreshStopped(in: store)

        #expect(store.watchedRepositories == [website])
        #expect(store.repositoryRefreshStates[website] == .idle)
        #expect(store.state == .empty)
        #expect(!store.isRefreshing)
    }

    /// Verifies repository picker failures do not clear the visible pull request snapshot.
    @Test func storeRepositoryChoiceFailureKeepsCurrentSnapshotVisible() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let client = StubAgentPRMonitorClient(
            results: [
                .success(AgentPRMonitorSnapshot(rows: [samplePullRequest(number: 62)], rateLimit: nil)),
            ],
            repositoryResults: [
                .failure(.authenticationFailed),
            ]
        )
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.selectRepository(repository)
        store.refresh()
        try await waitForRefresh(in: store)
        store.loadRepositoryChoices(force: true)
        try await waitForRepositoryChoices(in: store)

        #expect(store.state == .loaded)
        #expect(store.rows.map(\.number) == [62])
        #expect(store.repositoryPickerState == .failed(.authenticationFailed))
    }

    /// Verifies a failed repository reload preserves cached picker choices.
    @Test func storeRepositoryChoiceReloadFailureKeepsCachedChoices() async throws {
        let tokenStore = MemoryGitHubTokenStore(token: "github_pat_secret")
        let cachedChoices = [
            GitHubRepositorySummary(
                ref: repository,
                description: "Native macOS environment helper",
                isPrivate: true,
                isArchived: false,
                pushedAt: nil
            ),
        ]
        let client = StubAgentPRMonitorClient(
            results: [],
            repositoryResults: [
                .success(GitHubRepositoryList(
                    repositories: cachedChoices,
                    rateLimit: nil,
                    isTruncated: false
                )),
                .failure(.networkUnavailable),
            ]
        )
        let store = AgentPRMonitorStore(
            tokenStore: tokenStore,
            client: client,
            defaults: MemoryAgentPRMonitorDefaults()
        )

        store.loadRepositoryChoices()
        try await waitForRepositoryChoices(in: store)
        store.loadRepositoryChoices(force: true)
        try await waitForRepositoryChoices(in: store)

        #expect(store.repositoryPickerState == .failed(.networkUnavailable))
        #expect(store.repositoryChoices == cachedChoices)
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
        #expect(store.repositoryRefreshStates[repository] == .refreshFailed(.networkUnavailable))
        store.handleGitHubAuthorizationChange(.removed)

        #expect(store.state == .needsToken)
        #expect(store.rows.isEmpty)
        #expect(store.rateLimit == nil)
        #expect(!store.isRefreshing)
        #expect(store.repositoryRefreshStates.isEmpty)

        let queue = PRAttentionQueueBuilder.snapshot(
            rows: store.rows,
            repositories: store.watchedRepositories,
            freshnessByRepository: [:],
            defaultFreshness: AgentPRMonitorView.guidanceFreshness(for: store.state),
            actionAvailability: .allAvailable
        )
        #expect(!queue.items.isEmpty)
        #expect(queue.items.allSatisfy {
            $0.guidance.recommendedAction.id == AgentPRGuidanceRoute.openSettings.rawValue
        })
    }

    /// Builds a ready pull request fixture with a deterministic number.
    private func samplePullRequest(
        number: Int,
        repository: GitHubRepositoryRef? = nil
    ) -> AgentPullRequest {
        let repository = repository ?? self.repository
        return AgentPullRequest(
            repository: repository,
            number: number,
            title: "docs: document native Agent PR Monitor architecture design",
            url: URL(string: "https://github.com/\(repository.displayName)/pull/\(number)")!,
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

    /// Waits until an in-flight refresh is no longer visible to the store.
    private func waitUntilRefreshStopped(in store: AgentPRMonitorStore) async throws {
        for _ in 0..<100 {
            if !store.isRefreshing {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for AgentPRMonitorStore refresh to stop")
    }

    /// Waits for repository choices to finish loading.
    private func waitForRepositoryChoices(in store: AgentPRMonitorStore) async throws {
        for _ in 0..<100 {
            switch store.repositoryPickerState {
            case .loaded, .empty, .failed:
                return
            case .idle, .loading:
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for AgentPRMonitorStore repository choices to finish")
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

    /// REST repository-list fixture with two visible repositories.
    private static let restRepositoryListResponse = """
    [
      {
        "name": "CodingBuddy",
        "full_name": "apps3k-com/CodingBuddy",
        "private": true,
        "archived": false,
        "pushed_at": "2026-06-30T10:00:00Z",
        "description": "Native macOS environment helper",
        "owner": { "login": "apps3k-com" }
      },
      {
        "name": "Website",
        "full_name": "apps3k-com/Website",
        "private": false,
        "archived": false,
        "pushed_at": "2026-06-29T10:00:00Z",
        "description": null,
        "owner": { "login": "apps3k-com" }
      }
    ]
    """

    /// Builds one REST repository-list page with a single repository.
    private static func restRepositoryPage(owner: String, name: String) -> String {
        """
        [
          {
            "name": "\(name)",
            "full_name": "\(owner)/\(name)",
            "private": false,
            "archived": false,
            "pushed_at": "2026-06-30T10:00:00Z",
            "description": null,
            "owner": { "login": "\(owner)" }
          }
        ]
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

    /// GraphQL fixture with no review decision and an incomplete latest-review page.
    private static let graphQLTruncatedLatestReviewsWithoutDecisionResponse = """
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
                "reviewDecision": null,
                "latestReviews": {
                  "nodes": [
                    {
                      "author": { "login": "apps3000" },
                      "state": "APPROVED",
                      "submittedAt": "2026-06-28T10:21:00Z",
                      "url": "https://github.com/apps3k-com/CodingBuddy/pull/54#pullrequestreview-1"
                    }
                  ],
                  "pageInfo": { "hasNextPage": true }
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
      "total_count": 1,
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

    /// Empty REST combined-status fixture used when only check-run coverage is under test.
    private static let restEmptyStatusesResponse = """
    {
      "total_count": 0,
      "statuses": []
    }
    """

    /// REST combined-status fixture used by fallback tests.
    private static let restStatusesResponse = """
    {
      "total_count": 1,
      "statuses": [
        {
          "context": "cubic",
          "state": "FAILURE",
          "target_url": "https://github.com/apps3k-com/CodingBuddy/statuses/cubic"
        }
      ]
    }
    """

    /// Builds one REST combined-status page with optional total coverage metadata.
    private static func restStatusesPage(
        totalCount: Int?,
        context: String,
        state: String,
        combinedState: String? = nil
    ) -> String {
        let totalCountField = totalCount.map { "\"total_count\": \($0)," } ?? ""
        let combinedStateField = combinedState.map { "\"state\": \"\($0)\"," } ?? ""
        return """
        {
          \(totalCountField)
          \(combinedStateField)
          "statuses": [
            {
              "context": "\(context)",
              "state": "\(state)",
              "target_url": "https://github.com/apps3k-com/CodingBuddy/statuses/\(context)"
            }
          ]
        }
        """
    }

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

/// Token store test double that fails while loading the token.
private struct LoadFailingGitHubTokenStore: GitHubTokenStore {
    /// Always throws a token-like failure string to verify leak protection.
    func loadToken() throws -> String? {
        throw Failure()
    }

    /// Saves are unused for this test double.
    func saveToken(_ token: String) throws {}

    /// Deletes are unused for this test double.
    func deleteToken() throws {}

    /// Synthetic Keychain-like load failure used by the failing token store.
    private struct Failure: LocalizedError {
        /// Error text intentionally contains a fake token to exercise sanitization.
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
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

/// Complete credential store used to prove monitor-side rotating-token integration.
private nonisolated final class MonitorCredentialStore: GitHubTokenStore, @unchecked Sendable {
    /// Lock protecting the complete credential bundle.
    private let lock = NSLock()
    /// Current in-memory credential.
    private var storedCredential: GitHubCredential?

    /// Creates the store with one complete credential.
    init(credential: GitHubCredential?) {
        storedCredential = credential
    }

    /// Current credential for assertions.
    var credential: GitHubCredential? {
        lock.withLock { storedCredential }
    }

    /// Returns the access token for legacy protocol consumers.
    func loadToken() throws -> String? {
        lock.withLock { storedCredential?.accessToken }
    }

    /// Replaces the credential with a read-only PAT.
    func saveToken(_ token: String) throws {
        lock.withLock { storedCredential = .personalAccessToken(token) }
    }

    /// Removes the credential.
    func deleteToken() throws {
        lock.withLock { storedCredential = nil }
    }

    /// Returns the complete credential bundle.
    func loadCredential() throws -> GitHubCredential? {
        lock.withLock { storedCredential }
    }

    /// Persists the complete rotated credential bundle.
    func saveCredential(_ credential: GitHubCredential) throws {
        lock.withLock { storedCredential = credential }
    }
}

/// OAuth transport returning one deterministic rotated credential for monitor tests.
private nonisolated final class MonitorOAuthRefreshTransport: GitHubTransport, @unchecked Sendable {
    /// Lock protecting the request count.
    private let lock = NSLock()
    /// Number of OAuth refresh calls.
    private var count = 0

    /// Current OAuth request count.
    var requestCount: Int {
        lock.withLock { count }
    }

    /// Returns one successful no-secret refresh-token response.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        let data = Data(#"{"access_token":"new-access","token_type":"bearer","expires_in":28800,"refresh_token":"new-refresh","refresh_token_expires_in":15552000}"#.utf8)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)]
            )!
        )
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
    /// Pending repository-list results.
    private var repositoryResults: [Result<GitHubRepositoryList, GitHubClientError>]
    /// Lock protecting the queued results.
    private let lock = NSLock()

    /// Creates a stub with deterministic queued results.
    init(
        results: [Result<AgentPRMonitorSnapshot, GitHubClientError>],
        repositoryResults: [Result<GitHubRepositoryList, GitHubClientError>] = []
    ) {
        self.results = results
        self.repositoryResults = repositoryResults
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

    /// Returns the next queued repository list or error.
    func fetchAccessibleRepositories() async throws -> GitHubRepositoryList {
        try lock.withLock {
            if repositoryResults.isEmpty {
                throw GitHubClientError.networkUnavailable
            }
            return try repositoryResults.removeFirst().get()
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

    /// Repository listing is not used by cancellation-focused delayed tests.
    func fetchAccessibleRepositories() async throws -> GitHubRepositoryList {
        throw GitHubClientError.networkUnavailable
    }
}
