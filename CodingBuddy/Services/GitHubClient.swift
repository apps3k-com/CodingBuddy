//
//  GitHubClient.swift
//  CodingBuddy
//

import Foundation

/// Fetching interface consumed by `AgentPRMonitorStore`.
nonisolated protocol AgentPRMonitorFetching: Sendable {
    /// Fetches the latest read-only PR monitor snapshot for one repository.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot
}

/// Injectable HTTP transport for GitHub requests.
nonisolated protocol GitHubTransport: Sendable {
    /// Performs a URL request and returns HTTP response metadata.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed transport used outside tests.
nonisolated struct URLSessionGitHubTransport: GitHubTransport {
    /// Creates the default transport around `URLSession.shared`.
    init() {}

    /// Performs a GitHub request through Foundation URLSession.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

/// Typed GitHub failures that are safe to surface in the UI.
nonisolated enum GitHubClientError: LocalizedError, Equatable, Sendable {
    /// No token is stored, so no network request should be attempted.
    case noToken
    /// GitHub rejected the token.
    case authenticationFailed
    /// GitHub indicated a missing permission or scope.
    case missingScope(String?)
    /// The token cannot access the selected repository.
    case repositoryDenied(GitHubRepositoryRef)
    /// GitHub rate limit was reached.
    case rateLimited(resetAt: Date?)
    /// The network appears unavailable.
    case networkUnavailable
    /// GitHub returned an unexpected HTTP status.
    case server(statusCode: Int)
    /// GitHub returned non-HTTP or structurally invalid data.
    case invalidResponse
    /// GitHub returned data CodingBuddy could not decode.
    case decodingFailed
    /// GitHub returned an unclassified safe-to-surface error.
    case githubError
    /// CodingBuddy could not update the GitHub token in Keychain.
    case tokenStorageFailed

    /// Localized UI-safe error text.
    var errorDescription: String? {
        switch self {
        case .noToken:
            String(localized: "Add a GitHub token to monitor pull requests.")
        case .authenticationFailed:
            String(localized: "GitHub rejected the saved token. Replace it and try again.")
        case .missingScope(let scope):
            if let scope, !scope.isEmpty {
                String(
                    format: String(localized: "The GitHub token is missing required read permissions: %@"),
                    scope
                )
            } else {
                String(localized: "The GitHub token is missing required read permissions.")
            }
        case .repositoryDenied(let repository):
            String(format: String(localized: "The GitHub token cannot access %@."), repository.displayName)
        case .rateLimited(let resetAt):
            if let resetAt {
                String(
                    format: String(localized: "GitHub rate limit reached. Try again after %@."),
                    resetAt.formatted(date: .omitted, time: .shortened)
                )
            } else {
                String(localized: "GitHub rate limit reached. Try again later.")
            }
        case .networkUnavailable:
            String(localized: "GitHub is unreachable. Check your network connection and try again.")
        case .server(let statusCode):
            String(format: String(localized: "GitHub returned HTTP %lld."), Int64(statusCode))
        case .invalidResponse:
            String(localized: "GitHub returned an invalid response.")
        case .decodingFailed:
            String(localized: "CodingBuddy could not read the GitHub response.")
        case .githubError:
            String(localized: "GitHub returned an error. Check the token permissions and try again.")
        case .tokenStorageFailed:
            String(localized: "CodingBuddy could not update the saved GitHub token in Keychain.")
        }
    }
}

/// Native GitHub API client for the read-only Agent PR Monitor.
nonisolated struct GitHubClient: AgentPRMonitorFetching {
    /// Token source used to authorize GitHub calls.
    let tokenStore: any GitHubTokenStore
    /// Injectable HTTP transport.
    let transport: any GitHubTransport
    /// GitHub GraphQL endpoint.
    let graphQLEndpoint: URL
    /// GitHub REST API base URL.
    let restBaseURL: URL

    /// Creates a GitHub client with injectable token and transport dependencies.
    init(
        tokenStore: any GitHubTokenStore,
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        graphQLEndpoint: URL = URL(string: "https://api.github.com/graphql")!,
        restBaseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.tokenStore = tokenStore
        self.transport = transport
        self.graphQLEndpoint = graphQLEndpoint
        self.restBaseURL = restBaseURL
    }

    /// Fetches open pull requests for one repository through GitHub GraphQL.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot {
        guard let token = try tokenStore.loadToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw GitHubClientError.noToken
        }

        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(
            query: Self.pullRequestQuery,
            variables: GraphQLVariables(owner: repository.owner, repo: repository.name, first: 50)
        ))

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as GitHubClientError {
            throw error
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw GitHubClientError.networkUnavailable
        } catch {
            throw GitHubClientError.networkUnavailable
        }

        let rateLimit = Self.rateLimit(from: response)
        try Self.validate(response: response, data: data, repository: repository, rateLimit: rateLimit)

        do {
            let decoded = try JSONDecoder.github.decode(GraphQLResponse.self, from: data)
            if let firstError = decoded.errors?.first {
                throw Self.map(graphQLError: firstError, repository: repository, rateLimit: decoded.data?.rateLimit ?? rateLimit)
            }
            var latestRateLimit = decoded.data?.rateLimit ?? rateLimit
            var rows: [AgentPullRequest] = []
            for node in decoded.data?.repository.pullRequests.nodes ?? [] {
                let contexts = node.statusContexts
                if contexts.isEmpty, !node.normalizedHeadSHA.isEmpty {
                    let fallback = try await fetchRESTStatusContexts(
                        repository: repository,
                        headSHA: node.normalizedHeadSHA,
                        token: token
                    )
                    if let fallbackRateLimit = fallback.rateLimit {
                        latestRateLimit = fallbackRateLimit
                    }
                    rows.append(node.agentPullRequest(
                        repository: repository,
                        statusContexts: fallback.contexts,
                        hasTruncatedStatusContexts: fallback.isTruncated
                    ))
                } else {
                    rows.append(node.agentPullRequest(
                        repository: repository,
                        statusContexts: contexts,
                        hasTruncatedStatusContexts: node.hasTruncatedStatusContexts
                    ))
                }
            }
            return AgentPRMonitorSnapshot(rows: rows, rateLimit: latestRateLimit)
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.decodingFailed
        }
    }

    /// Fetches check-run and legacy commit-status contexts when GraphQL omitted them.
    private func fetchRESTStatusContexts(
        repository: GitHubRepositoryRef,
        headSHA: String,
        token: String
    ) async throws -> RESTStatusFallback {
        let checkRunsRequest = restRequest(
            pathComponents: ["repos", repository.owner, repository.name, "commits", headSHA, "check-runs"],
            token: token,
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )
        let (checkRunsData, checkRunsResponse) = try await perform(request: checkRunsRequest)
        let checkRunsRateLimit = Self.rateLimit(from: checkRunsResponse)
        try Self.validate(
            response: checkRunsResponse,
            data: checkRunsData,
            repository: repository,
            rateLimit: checkRunsRateLimit
        )
        let checkRuns = try decodeRESTCheckRuns(from: checkRunsData)

        let statusesRequest = restRequest(
            pathComponents: ["repos", repository.owner, repository.name, "commits", headSHA, "status"],
            token: token
        )
        let (statusesData, statusesResponse) = try await perform(request: statusesRequest)
        let statusesRateLimit = Self.rateLimit(from: statusesResponse)
        try Self.validate(
            response: statusesResponse,
            data: statusesData,
            repository: repository,
            rateLimit: statusesRateLimit
        )
        let statuses = try decodeRESTStatuses(from: statusesData)

        return RESTStatusFallback(
            contexts: checkRuns + statuses,
            rateLimit: statusesRateLimit ?? checkRunsRateLimit,
            isTruncated: Self.hasNextLink(checkRunsResponse)
        )
    }

    /// Creates a GitHub REST request that never embeds token values in model state.
    private func restRequest(
        pathComponents: [String],
        token: String,
        queryItems: [URLQueryItem] = []
    ) -> URLRequest {
        let pathURL = pathComponents.reduce(restBaseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        let url = components?.url ?? pathURL
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Performs a GitHub request and normalizes low-level network errors.
    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as GitHubClientError {
            throw error
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw GitHubClientError.networkUnavailable
        } catch {
            throw GitHubClientError.networkUnavailable
        }
    }

    /// Decodes REST check runs into normalized status contexts.
    private func decodeRESTCheckRuns(from data: Data) throws -> [AgentPRStatusContext] {
        do {
            return try JSONDecoder.github.decode(RESTCheckRunsResponse.self, from: data).checkRuns.map(\.statusContext)
        } catch {
            throw GitHubClientError.decodingFailed
        }
    }

    /// Decodes REST combined commit statuses into normalized status contexts.
    private func decodeRESTStatuses(from data: Data) throws -> [AgentPRStatusContext] {
        do {
            return try JSONDecoder.github.decode(RESTCommitStatusResponse.self, from: data).statuses.map(\.statusContext)
        } catch {
            throw GitHubClientError.decodingFailed
        }
    }

    /// Maps HTTP metadata into UI-safe typed errors before decoding.
    private static func validate(
        response: HTTPURLResponse,
        data: Data,
        repository: GitHubRepositoryRef,
        rateLimit: GitHubRateLimitState?
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubClientError.authenticationFailed
        case 403, 429:
            if response.statusCode == 429 || rateLimit?.remaining == 0 {
                throw GitHubClientError.rateLimited(resetAt: rateLimit?.resetAt)
            }
            if let permissions = response.value(forHTTPHeaderField: "X-Accepted-GitHub-Permissions") {
                throw GitHubClientError.missingScope(permissions)
            }
            if let message = try? JSONDecoder().decode(GitHubRESTError.self, from: data).message,
               message.localizedCaseInsensitiveContains("rate limit") {
                throw GitHubClientError.rateLimited(resetAt: rateLimit?.resetAt)
            }
            throw GitHubClientError.repositoryDenied(repository)
        default:
            throw GitHubClientError.server(statusCode: response.statusCode)
        }
    }

    /// Extracts rate-limit metadata from REST-style response headers.
    private static func rateLimit(from response: HTTPURLResponse) -> GitHubRateLimitState? {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        if remaining == nil && resetAt == nil { return nil }
        return GitHubRateLimitState(remaining: remaining, resetAt: resetAt)
    }

    /// Maps GraphQL error payloads into UI-safe client errors.
    private static func map(
        graphQLError: GraphQLError,
        repository: GitHubRepositoryRef,
        rateLimit: GitHubRateLimitState?
    ) -> GitHubClientError {
        let message = graphQLError.message
        if message.localizedCaseInsensitiveContains("rate limit") {
            return .rateLimited(resetAt: rateLimit?.resetAt)
        }
        if message.localizedCaseInsensitiveContains("resource not accessible") {
            return .missingScope(nil)
        }
        if message.localizedCaseInsensitiveContains("could not resolve")
            || message.localizedCaseInsensitiveContains("not accessible") {
            return .repositoryDenied(repository)
        }
        return .githubError
    }

    /// True when a REST response exposes another page in its Link header.
    private static func hasNextLink(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Link")?.contains(#"rel="next""#) == true
    }

    /// Primary GraphQL query for open pull requests.
    private static let pullRequestQuery = """
    query AgentPRMonitor($owner: String!, $repo: String!, $first: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: $first, states: OPEN, orderBy: { field: UPDATED_AT, direction: DESC }) {
          nodes {
            number
            title
            url
            isDraft
            updatedAt
            author { login }
            headRefName
            headRefOid
            baseRefName
            closingIssuesReferences(first: 5) {
              nodes { number title url state }
            }
            reviewDecision
            latestReviews(first: 10) {
              nodes { author { login } state submittedAt url }
            }
            reviewThreads(first: 50) {
              pageInfo { hasNextPage }
              nodes {
                isResolved
                isOutdated
                path
                line
                comments(first: 1) {
                  nodes { url }
                }
              }
            }
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    contexts(first: 50) {
                      pageInfo { hasNextPage }
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      rateLimit { remaining resetAt }
    }
    """
}

private nonisolated extension JSONDecoder {
    /// Decoder configured for GitHub ISO-8601 timestamps.
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Encodable GraphQL request body.
private nonisolated struct GraphQLRequest: Encodable {
    /// GraphQL query text.
    let query: String
    /// Typed GraphQL variables.
    let variables: GraphQLVariables
}

/// Variables for the Agent PR Monitor GraphQL request.
private nonisolated struct GraphQLVariables: Encodable {
    /// Repository owner or organization login.
    let owner: String
    /// Repository name.
    let repo: String
    /// Number of open pull requests to request.
    let first: Int
}

/// Minimal REST-style error body.
private nonisolated struct GitHubRESTError: Decodable {
    /// Human-readable GitHub error message.
    let message: String
}

/// Top-level GraphQL response body.
private nonisolated struct GraphQLResponse: Decodable {
    /// Successful response data when GitHub returned it.
    let data: GraphQLData?
    /// GraphQL error payloads when the query failed.
    let errors: [GraphQLError]?
}

/// GraphQL error payload.
private nonisolated struct GraphQLError: Decodable {
    /// Human-readable GitHub error message.
    let message: String
}

/// Successful Agent PR Monitor GraphQL data.
private nonisolated struct GraphQLData: Decodable {
    /// Repository data for the requested owner/name pair.
    let repository: RepositoryData
    /// GraphQL rate-limit state.
    let rateLimit: GitHubRateLimitState?
}

/// GraphQL repository object.
private nonisolated struct RepositoryData: Decodable {
    /// Open pull request connection.
    let pullRequests: PullRequestConnection
}

/// GraphQL pull request connection.
private nonisolated struct PullRequestConnection: Decodable {
    /// Open pull requests in requested order.
    let nodes: [PullRequestNode]
}

/// GraphQL pull request node mapped into the app row model.
private nonisolated struct PullRequestNode: Decodable {
    /// Pull request number.
    let number: Int
    /// Pull request title.
    let title: String
    /// Pull request URL.
    let url: URL
    /// Draft state.
    let isDraft: Bool
    /// Updated timestamp.
    let updatedAt: Date
    /// Author data.
    let author: LoginNode?
    /// Head branch name.
    let headRefName: String?
    /// Head commit SHA.
    let headRefOid: String?
    /// Base branch name.
    let baseRefName: String?
    /// Closing issue references.
    let closingIssuesReferences: IssueConnection
    /// Review decision string.
    let reviewDecision: String?
    /// Latest review connection.
    let latestReviews: ReviewConnection
    /// Review thread connection.
    let reviewThreads: ThreadConnection
    /// Commit connection containing status rollup.
    let commits: CommitConnection

    /// Converts the raw GraphQL node into an app-facing row model.
    func agentPullRequest(
        repository: GitHubRepositoryRef,
        statusContexts contexts: [AgentPRStatusContext],
        hasTruncatedStatusContexts: Bool
    ) -> AgentPullRequest {
        let review = AgentPRReviewSummary(
            decision: AgentPRReviewDecision(graphQLValue: reviewDecision),
            latestReviews: latestReviews.nodes.map(\.agentReview),
            threads: reviewThreads.nodes.map(\.agentThread),
            hasTruncatedThreads: reviewThreads.pageInfo?.hasNextPage == true
        )
        return AgentPullRequest(
            repository: repository,
            number: number,
            title: title,
            url: url,
            isDraft: isDraft,
            authorLogin: author?.login,
            source: AgentPRAuthorSource(authorLogin: author?.login, branch: headRefName),
            headRefName: headRefName ?? "",
            headSHA: headRefOid ?? "",
            baseRefName: baseRefName ?? "",
            linkedIssues: closingIssuesReferences.nodes.map(\.agentIssue),
            review: review,
            checks: AgentPRCheckSummary(contexts: contexts, isTruncated: hasTruncatedStatusContexts),
            updatedAt: updatedAt
        )
    }

    /// GraphQL-provided status contexts, if GitHub exposed a rollup.
    var statusContexts: [AgentPRStatusContext] {
        commits.nodes.last?.commit.statusCheckRollup?.contexts.nodes.map(\.statusContext) ?? []
    }

    /// Head SHA used for REST fallback when status contexts are missing.
    var normalizedHeadSHA: String {
        headRefOid ?? commits.nodes.last?.commit.oid ?? ""
    }

    /// Whether GitHub indicated status contexts were truncated.
    var hasTruncatedStatusContexts: Bool {
        commits.nodes.last?.commit.statusCheckRollup?.contexts.pageInfo?.hasNextPage == true
    }
}

/// GraphQL node with an author login.
private nonisolated struct LoginNode: Decodable {
    /// GitHub login.
    let login: String
}

/// GraphQL issue connection.
private nonisolated struct IssueConnection: Decodable {
    /// Linked issue nodes.
    let nodes: [IssueNode]
}

/// GraphQL issue node.
private nonisolated struct IssueNode: Decodable {
    /// Issue number.
    let number: Int
    /// Issue title.
    let title: String
    /// Issue URL.
    let url: URL
    /// Raw issue state.
    let state: String

    /// App-facing linked issue.
    var agentIssue: AgentPRLinkedIssue {
        AgentPRLinkedIssue(
            number: number,
            title: title,
            url: url,
            state: AgentPRLinkedIssueState(graphQLValue: state)
        )
    }
}

/// GraphQL review connection.
private nonisolated struct ReviewConnection: Decodable {
    /// Latest review nodes.
    let nodes: [ReviewNode]
}

/// GraphQL review node.
private nonisolated struct ReviewNode: Decodable {
    /// Review author.
    let author: LoginNode?
    /// Raw review state.
    let state: String?
    /// Submission timestamp.
    let submittedAt: Date?
    /// Browser URL.
    let url: URL?

    /// App-facing review entry.
    var agentReview: AgentPRReview {
        AgentPRReview(
            authorLogin: author?.login,
            state: AgentPRReviewState(graphQLValue: state),
            submittedAt: submittedAt,
            url: url
        )
    }
}

/// GraphQL review thread connection.
private nonisolated struct ThreadConnection: Decodable {
    /// Review thread nodes.
    let nodes: [ThreadNode]
    /// Pagination metadata when GitHub exposed it.
    let pageInfo: PageInfo?
}

/// GraphQL review thread node.
private nonisolated struct ThreadNode: Decodable {
    /// Whether the thread is resolved.
    let isResolved: Bool
    /// Whether the thread is outdated.
    let isOutdated: Bool
    /// Repository path.
    let path: String?
    /// Line number.
    let line: Int?
    /// Comment connection containing the first browser URL.
    let comments: CommentConnection

    /// App-facing review thread.
    var agentThread: AgentPRReviewThread {
        AgentPRReviewThread(
            path: path,
            line: line,
            isResolved: isResolved,
            isOutdated: isOutdated,
            url: comments.nodes.first?.url
        )
    }
}

/// GraphQL comment connection.
private nonisolated struct CommentConnection: Decodable {
    /// Comment nodes.
    let nodes: [CommentNode]
}

/// GraphQL comment node.
private nonisolated struct CommentNode: Decodable {
    /// Browser URL for review thread follow-up.
    let url: URL?
}

/// GraphQL commit connection.
private nonisolated struct CommitConnection: Decodable {
    /// Commit nodes.
    let nodes: [CommitNode]
}

/// GraphQL commit node wrapper.
private nonisolated struct CommitNode: Decodable {
    /// Commit data.
    let commit: CommitData
}

/// GraphQL commit data.
private nonisolated struct CommitData: Decodable {
    /// Commit object ID.
    let oid: String?
    /// Status/check rollup for the commit.
    let statusCheckRollup: StatusCheckRollup?
}

/// GraphQL status-check rollup.
private nonisolated struct StatusCheckRollup: Decodable {
    /// Check/status contexts.
    let contexts: StatusContextConnection
}

/// GraphQL status context connection.
private nonisolated struct StatusContextConnection: Decodable {
    /// Polymorphic status context nodes.
    let nodes: [StatusContextNode]
    /// Pagination metadata when GitHub exposed it.
    let pageInfo: PageInfo?
}

/// Minimal GitHub GraphQL pagination metadata.
private nonisolated struct PageInfo: Decodable {
    /// Whether another page exists past the fetched v1 cap.
    let hasNextPage: Bool
}

/// Polymorphic GraphQL status context node.
private nonisolated struct StatusContextNode: Decodable {
    /// GraphQL concrete type name.
    let typename: String
    /// Check run name.
    let name: String?
    /// Check run status.
    let status: String?
    /// Check run conclusion.
    let conclusion: String?
    /// Check run details URL.
    let detailsUrl: URL?
    /// Legacy status context name.
    let context: String?
    /// Legacy status state.
    let state: String?
    /// Legacy status target URL.
    let targetUrl: URL?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name
        case status
        case conclusion
        case detailsUrl
        case context
        case state
        case targetUrl
    }

    /// App-facing normalized status context.
    var statusContext: AgentPRStatusContext {
        if typename == "StatusContext" {
            return AgentPRStatusContext(
                name: context ?? String(localized: "Unknown"),
                state: AgentPRStatusState(statusContextState: state),
                detailsURL: targetUrl
            )
        }
        return AgentPRStatusContext(
            name: name ?? String(localized: "Unknown"),
            state: AgentPRStatusState(checkRunStatus: status, conclusion: conclusion),
            detailsURL: detailsUrl
        )
    }
}

/// REST status fallback payload.
private nonisolated struct RESTStatusFallback: Sendable {
    /// Normalized check and status contexts.
    let contexts: [AgentPRStatusContext]
    /// Latest REST rate-limit state, if GitHub provided it.
    let rateLimit: GitHubRateLimitState?
    /// Whether REST pagination indicates more check runs exist.
    let isTruncated: Bool
}

/// REST check-runs response.
private nonisolated struct RESTCheckRunsResponse: Decodable {
    /// Check runs attached to the commit.
    let checkRuns: [RESTCheckRun]

    private enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

/// REST check run entry.
private nonisolated struct RESTCheckRun: Decodable {
    /// Check-run name.
    let name: String?
    /// Check-run status.
    let status: String?
    /// Check-run conclusion.
    let conclusion: String?
    /// Provider details URL.
    let detailsURL: URL?

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case conclusion
        case detailsURL = "details_url"
    }

    /// App-facing normalized status context.
    var statusContext: AgentPRStatusContext {
        AgentPRStatusContext(
            name: name ?? String(localized: "Unknown"),
            state: AgentPRStatusState(checkRunStatus: status, conclusion: conclusion),
            detailsURL: detailsURL
        )
    }
}

/// REST combined commit-status response.
private nonisolated struct RESTCommitStatusResponse: Decodable {
    /// Legacy status contexts attached to the commit.
    let statuses: [RESTCommitStatus]
}

/// REST legacy status context entry.
private nonisolated struct RESTCommitStatus: Decodable {
    /// Context name.
    let context: String?
    /// Commit status state.
    let state: String?
    /// Provider details URL.
    let targetURL: URL?

    private enum CodingKeys: String, CodingKey {
        case context
        case state
        case targetURL = "target_url"
    }

    /// App-facing normalized status context.
    var statusContext: AgentPRStatusContext {
        AgentPRStatusContext(
            name: context ?? String(localized: "Unknown"),
            state: AgentPRStatusState(statusContextState: state),
            detailsURL: targetURL
        )
    }
}

private nonisolated extension AgentPRAuthorSource {
    /// Conservative source classifier for v1.
    init(authorLogin: String?, branch: String?) {
        let login = authorLogin?.lowercased() ?? ""
        let branch = branch?.lowercased() ?? ""
        if login.hasSuffix("[bot]") || login.contains("bot") || branch.contains("codex") || branch.contains("agent") {
            self = .likelyAgent
        } else if !login.isEmpty {
            self = .likelyHuman
        } else {
            self = .unknown
        }
    }
}

private nonisolated extension AgentPRLinkedIssueState {
    /// Normalizes GraphQL issue state.
    init(graphQLValue: String) {
        switch graphQLValue.uppercased() {
        case "OPEN":
            self = .open
        case "CLOSED":
            self = .closed
        default:
            self = .unknown
        }
    }
}

private nonisolated extension AgentPRReviewDecision {
    /// Normalizes GraphQL review decision.
    init(graphQLValue: String?) {
        switch graphQLValue?.uppercased() {
        case "APPROVED":
            self = .approved
        case "CHANGES_REQUESTED":
            self = .changesRequested
        case "REVIEW_REQUIRED":
            self = .reviewRequired
        case nil:
            self = .none
        default:
            self = .unknown
        }
    }
}

private nonisolated extension AgentPRReviewState {
    /// Normalizes GraphQL review state.
    init(graphQLValue: String?) {
        switch graphQLValue?.uppercased() {
        case "APPROVED":
            self = .approved
        case "CHANGES_REQUESTED":
            self = .changesRequested
        case "COMMENTED":
            self = .commented
        case "DISMISSED":
            self = .dismissed
        default:
            self = .unknown
        }
    }
}

private nonisolated extension AgentPRStatusState {
    /// Normalizes check-run status and conclusion fields.
    init(checkRunStatus: String?, conclusion: String?) {
        switch checkRunStatus?.uppercased() {
        case "QUEUED", "REQUESTED", "WAITING":
            self = .queued
        case "IN_PROGRESS":
            self = .inProgress
        case "COMPLETED":
            switch conclusion?.uppercased() {
            case "SUCCESS":
                self = .success
            case "NEUTRAL":
                self = .neutral
            case "SKIPPED":
                self = .skipped
            case "FAILURE", "STARTUP_FAILURE":
                self = .failure
            case "CANCELLED":
                self = .cancelled
            case "TIMED_OUT":
                self = .timedOut
            case "ACTION_REQUIRED":
                self = .actionRequired
            default:
                self = .unknown
            }
        default:
            self = .unknown
        }
    }

    /// Normalizes legacy commit status state.
    init(statusContextState: String?) {
        switch statusContextState?.uppercased() {
        case "SUCCESS":
            self = .success
        case "PENDING":
            self = .pending
        case "FAILURE", "ERROR":
            self = .failure
        default:
            self = .unknown
        }
    }
}
