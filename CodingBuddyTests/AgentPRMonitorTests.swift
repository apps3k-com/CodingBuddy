//
//  AgentPRMonitorTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

@MainActor
@Suite(.serialized)
struct AgentPRMonitorTests {
    private let repository = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy")

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

    @Test func clientDoesNotCallTransportWithoutToken() async {
        let tokenStore = MemoryGitHubTokenStore(token: nil)
        let transport = RecordingGitHubTransport()
        let client = GitHubClient(tokenStore: tokenStore, transport: transport)

        await #expect(throws: GitHubClientError.noToken) {
            try await client.fetchOpenPullRequests(repository: repository)
        }
        #expect(transport.requests.isEmpty)
    }

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
        failingStore.saveToken("github_pat_secret")

        #expect(failingStore.state == .refreshFailed(.tokenStorageFailed))
        #expect(!(GitHubClientError.tokenStorageFailed.errorDescription ?? "").contains("github_pat_secret"))
    }

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

    private func waitForRefresh(in store: AgentPRMonitorStore) async throws {
        for _ in 0..<100 {
            if !store.isRefreshing {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

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

    private static let graphQLUnknownErrorResponse = """
    {
      "errors": [
        { "message": "upstream echoed github_pat_secret in a provider error" }
      ]
    }
    """
}

private final class MemoryGitHubTokenStore: GitHubTokenStore, @unchecked Sendable {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func loadToken() throws -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
    }
}

private struct FailingGitHubTokenStore: GitHubTokenStore {
    func loadToken() throws -> String? {
        nil
    }

    func saveToken(_ token: String) throws {
        throw Failure()
    }

    func deleteToken() throws {
        throw Failure()
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? {
            "keychain failed for github_pat_secret"
        }
    }
}

private final class RecordingGitHubTransport: GitHubTransport, @unchecked Sendable {
    enum Result {
        case response(Data, statusCode: Int, headers: [String: String])
        case failure(Error)
    }

    private var results: [Result]
    private var recordedRequests: [URLRequest] = []
    private let lock = NSLock()

    init(result: Result = .failure(URLError(.cancelled))) {
        results = [result]
    }

    init(results: [Result]) {
        self.results = results
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

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

private final class MemoryAgentPRMonitorDefaults: AgentPRMonitorDefaultsStoring {
    private var values: [String: String] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName]
    }

    func setAgentPRMonitorString(_ value: String, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

private final class StubAgentPRMonitorClient: AgentPRMonitorFetching, @unchecked Sendable {
    private var results: [Result<AgentPRMonitorSnapshot, GitHubClientError>]
    private let lock = NSLock()

    init(results: [Result<AgentPRMonitorSnapshot, GitHubClientError>]) {
        self.results = results
    }

    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot {
        try lock.withLock {
            if results.isEmpty {
                throw GitHubClientError.networkUnavailable
            }
            return try results.removeFirst().get()
        }
    }
}
