//
//  GitHubClient.swift
//  CodingBuddy
//

import Foundation

/// Fetching interface consumed by `AgentPRMonitorStore`.
nonisolated protocol AgentPRMonitorFetching: Sendable {
    /// Fetches the latest read-only PR monitor snapshot for one repository.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot

    /// Fetches GitHub repositories visible to the saved token for picker setup.
    func fetchAccessibleRepositories() async throws -> GitHubRepositoryList
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
    /// CodingBuddy could not read the saved GitHub token from Keychain.
    case tokenLoadFailed

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
        case .tokenLoadFailed:
            String(localized: "The saved GitHub token could not be read.")
        }
    }
}

extension GitHubClientError {
    /// Whether changing the GitHub token in Settings can resolve the failure.
    nonisolated var isGitHubAuthorizationRecoverable: Bool {
        switch self {
        case .noToken, .authenticationFailed, .missingScope(_), .repositoryDenied(_), .tokenStorageFailed,
             .tokenLoadFailed:
            true
        case .rateLimited(_), .networkUnavailable, .server(_), .invalidResponse, .decodingFailed, .githubError:
            false
        }
    }
}

/// Native GitHub API client for the read-only Agent PR Monitor.
nonisolated struct GitHubClient: AgentPRMonitorFetching {
    /// Shared actor that returns a current read credential and rotates App tokens.
    let credentialCoordinator: GitHubCredentialCoordinator
    /// Injectable HTTP transport.
    let transport: any GitHubTransport
    /// GitHub GraphQL endpoint.
    let graphQLEndpoint: URL
    /// GitHub REST API base URL.
    let restBaseURL: URL
    /// Number of pull requests requested per GraphQL page.
    private static let pullRequestPageSize = 50
    /// Number of repositories requested per REST page.
    private static let repositoryPageSize = 100
    /// Maximum number of legacy commit statuses requested per REST page.
    private static let statusPageSize = 100
    /// Maximum number of repository pages read for one picker load.
    let repositoryPageLimit: Int
    /// Maximum number of legacy commit-status pages read for one pull request.
    let statusPageLimit: Int
    /// Maximum GraphQL pages accepted for one repository's open pull requests.
    let pullRequestPageLimit: Int
    /// Maximum pull request nodes accepted across one repository refresh.
    let maximumPullRequestNodes: Int
    /// Maximum aggregate GraphQL response bytes accepted across one repository refresh.
    let maximumPullRequestBytes: Int

    /// Creates a GitHub client with injectable token and transport dependencies.
    init(
        tokenStore: any GitHubTokenStore,
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        graphQLEndpoint: URL = URL(string: "https://api.github.com/graphql")!,
        restBaseURL: URL = URL(string: "https://api.github.com")!,
        repositoryPageLimit: Int = 10,
        statusPageLimit: Int = 10,
        pullRequestPageLimit: Int = 100,
        maximumPullRequestNodes: Int = 5_000,
        maximumPullRequestBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.credentialCoordinator = GitHubCredentialCoordinator(tokenStore: tokenStore)
        self.transport = transport
        self.graphQLEndpoint = graphQLEndpoint
        self.restBaseURL = restBaseURL
        self.repositoryPageLimit = max(1, repositoryPageLimit)
        self.statusPageLimit = max(1, statusPageLimit)
        self.pullRequestPageLimit = max(1, pullRequestPageLimit)
        self.maximumPullRequestNodes = max(1, maximumPullRequestNodes)
        self.maximumPullRequestBytes = max(1_024, maximumPullRequestBytes)
    }

    /// Creates a GitHub client that shares one credential lifecycle with other app stores.
    init(
        credentialCoordinator: GitHubCredentialCoordinator,
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        graphQLEndpoint: URL = URL(string: "https://api.github.com/graphql")!,
        restBaseURL: URL = URL(string: "https://api.github.com")!,
        repositoryPageLimit: Int = 10,
        statusPageLimit: Int = 10,
        pullRequestPageLimit: Int = 100,
        maximumPullRequestNodes: Int = 5_000,
        maximumPullRequestBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.credentialCoordinator = credentialCoordinator
        self.transport = transport
        self.graphQLEndpoint = graphQLEndpoint
        self.restBaseURL = restBaseURL
        self.repositoryPageLimit = max(1, repositoryPageLimit)
        self.statusPageLimit = max(1, statusPageLimit)
        self.pullRequestPageLimit = max(1, pullRequestPageLimit)
        self.maximumPullRequestNodes = max(1, maximumPullRequestNodes)
        self.maximumPullRequestBytes = max(1_024, maximumPullRequestBytes)
    }

    /// Fetches open pull requests for one repository through GitHub GraphQL.
    func fetchOpenPullRequests(repository: GitHubRepositoryRef) async throws -> AgentPRMonitorSnapshot {
        let token = try await loadToken()

        var after: String?
        var latestRateLimit: GitHubRateLimitState?
        var rows: [AgentPullRequest] = []
        var pageCount = 0
        var nodeCount = 0
        var responseBytes = 0
        var seenCursors = Set<String>()
        var seenPullRequestNumbers = Set<Int>()
        repeat {
            pageCount += 1
            guard pageCount <= pullRequestPageLimit else {
                throw GitHubClientError.decodingFailed
            }
            let page = try await fetchGraphQLPage(repository: repository, token: token, after: after)
            latestRateLimit = page.rateLimit ?? latestRateLimit
            let pageNodes = page.repository.pullRequests.nodes
            guard pageNodes.count <= maximumPullRequestNodes,
                  nodeCount <= maximumPullRequestNodes - pageNodes.count,
                  page.responseBytes <= maximumPullRequestBytes,
                  responseBytes <= maximumPullRequestBytes - page.responseBytes else {
                throw GitHubClientError.decodingFailed
            }
            nodeCount += pageNodes.count
            responseBytes += page.responseBytes

            for node in pageNodes {
                guard seenPullRequestNumbers.insert(node.number).inserted else {
                    throw GitHubClientError.decodingFailed
                }
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

            if page.repository.pullRequests.pageInfo?.hasNextPage == true {
                guard let nextCursor = page.repository.pullRequests.pageInfo?.endCursor,
                      !nextCursor.isEmpty,
                      seenCursors.insert(nextCursor).inserted else {
                    throw GitHubClientError.decodingFailed
                }
                after = nextCursor
            } else {
                after = nil
            }
        } while after != nil

        return AgentPRMonitorSnapshot(rows: rows, rateLimit: latestRateLimit)
    }

    /// Fetches repositories visible to the saved token through GitHub REST.
    func fetchAccessibleRepositories() async throws -> GitHubRepositoryList {
        let token = try await loadToken()

        var page = 1
        var repositories: [GitHubRepositorySummary] = []
        var latestRateLimit: GitHubRateLimitState?
        var hitPageLimitWithNextPage = false
        var shouldContinue: Bool
        repeat {
            let request = restRequest(
                pathComponents: ["user", "repos"],
                token: token,
                queryItems: [
                    URLQueryItem(name: "visibility", value: "all"),
                    URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                    URLQueryItem(name: "sort", value: "full_name"),
                    URLQueryItem(name: "per_page", value: "\(Self.repositoryPageSize)"),
                    URLQueryItem(name: "page", value: "\(page)"),
                ]
            )
            let (data, response) = try await perform(request: request)
            let rateLimit = Self.rateLimit(from: response)
            latestRateLimit = rateLimit ?? latestRateLimit
            try Self.validateRepositoryList(response: response, data: data, rateLimit: rateLimit)
            repositories.append(contentsOf: try decodeRESTRepositories(from: data))

            let hasNextPage = Self.hasNextLink(response)
            hitPageLimitWithNextPage = hasNextPage && page >= repositoryPageLimit
            shouldContinue = hasNextPage && !hitPageLimitWithNextPage
            page += 1
        } while shouldContinue

        return GitHubRepositoryList(
            repositories: repositories,
            rateLimit: latestRateLimit,
            isTruncated: hitPageLimitWithNextPage
        )
    }

    /// Loads and normalizes the saved GitHub token before network requests.
    private func loadToken() async throws -> String {
        do {
            let credential = try await credentialCoordinator.credential(for: .readOnly)
            let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw GitHubClientError.noToken }
            return token
        } catch GitHubCredentialCoordinatorError.missingCredential {
            throw GitHubClientError.noToken
        } catch GitHubCredentialCoordinatorError.credentialStorageFailed {
            throw GitHubClientError.tokenLoadFailed
        } catch GitHubCredentialCoordinatorError.missingConfiguration {
            throw GitHubClientError.authenticationFailed
        } catch let error as GitHubOAuthDeviceFlowError {
            switch error {
            case .networkUnavailable:
                throw GitHubClientError.networkUnavailable
            case .missingConfiguration, .responseTooLarge, .invalidResponse,
                 .invalidApplication, .accessDenied, .expired,
                 .reauthenticationRequired, .server:
                throw GitHubClientError.authenticationFailed
            }
        } catch let error as GitHubClientError {
            throw error
        } catch {
            throw GitHubClientError.tokenLoadFailed
        }
    }

    /// Fetches one page of open pull requests through GitHub GraphQL.
    private func fetchGraphQLPage(
        repository: GitHubRepositoryRef,
        token: String,
        after: String?
    ) async throws -> (repository: RepositoryData, rateLimit: GitHubRateLimitState?, responseBytes: Int) {
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(
            query: Self.pullRequestQuery,
            variables: GraphQLVariables(
                owner: repository.owner,
                repo: repository.name,
                first: Self.pullRequestPageSize,
                after: after
            )
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
        guard data.count <= maximumPullRequestBytes else {
            throw GitHubClientError.decodingFailed
        }
        try Self.validate(response: response, data: data, repository: repository, rateLimit: rateLimit)

        do {
            let decoded = try JSONDecoder.github.decode(GraphQLResponse.self, from: data)
            if let firstError = decoded.errors?.first {
                throw Self.map(graphQLError: firstError, repository: repository, rateLimit: decoded.data?.rateLimit ?? rateLimit)
            }
            guard let repositoryData = decoded.data?.repository else {
                throw GitHubClientError.repositoryDenied(repository)
            }
            return (repositoryData, decoded.data?.rateLimit ?? rateLimit, data.count)
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
        let checkRunsPage = try decodeRESTCheckRuns(from: checkRunsData)
        let hasTruncatedCheckRuns = Self.hasNextLink(checkRunsResponse)
            || checkRunsPage.totalCount.map { $0 != checkRunsPage.contexts.count } == true

        var statusPage = 1
        var statuses: [AgentPRStatusContext] = []
        var seenStatusContexts = Set<String>()
        var declaredStatusCount: Int?
        var declaredCombinedState: AgentPRStatusState?
        var statusesRateLimit: GitHubRateLimitState?
        var hasTruncatedStatuses = false
        repeat {
            let statusesRequest = restRequest(
                pathComponents: ["repos", repository.owner, repository.name, "commits", headSHA, "status"],
                token: token,
                queryItems: [
                    URLQueryItem(name: "per_page", value: "\(Self.statusPageSize)"),
                    URLQueryItem(name: "page", value: "\(statusPage)"),
                ]
            )
            let (statusesData, statusesResponse) = try await perform(request: statusesRequest)
            let pageRateLimit = Self.rateLimit(from: statusesResponse)
            statusesRateLimit = pageRateLimit ?? statusesRateLimit
            try Self.validate(
                response: statusesResponse,
                data: statusesData,
                repository: repository,
                rateLimit: pageRateLimit
            )
            let decodedPage = try decodeRESTStatuses(from: statusesData)
            let statusCountBeforePage = statuses.count
            for status in decodedPage.statuses {
                guard let canonicalContext = status.canonicalContext else {
                    hasTruncatedStatuses = true
                    statuses.append(status.statusContext)
                    continue
                }
                guard seenStatusContexts.insert(canonicalContext).inserted else {
                    hasTruncatedStatuses = true
                    continue
                }
                statuses.append(status.statusContext)
            }

            if let rawCombinedState = decodedPage.state {
                let pageCombinedState = AgentPRStatusState(statusContextState: rawCombinedState)
                if pageCombinedState == .unknown {
                    hasTruncatedStatuses = true
                }
                if let declaredCombinedState, declaredCombinedState != pageCombinedState {
                    hasTruncatedStatuses = true
                }
                declaredCombinedState = declaredCombinedState ?? pageCombinedState
            }

            if let totalCount = decodedPage.totalCount {
                if let declaredStatusCount, declaredStatusCount != totalCount {
                    hasTruncatedStatuses = true
                }
                declaredStatusCount = totalCount
            }

            let hasMoreByCount = declaredStatusCount.map { statuses.count < $0 } == true
            let hasMore = Self.hasNextLink(statusesResponse) || hasMoreByCount
            guard hasMore else { break }
            let madeProgress = statuses.count > statusCountBeforePage
            guard statusPage < statusPageLimit, madeProgress else {
                hasTruncatedStatuses = true
                break
            }
            statusPage += 1
        } while true

        if let declaredStatusCount, statuses.count != declaredStatusCount {
            hasTruncatedStatuses = true
        }
        if let declaredCombinedState,
           Self.combinedStatusState(for: statuses) != declaredCombinedState {
            hasTruncatedStatuses = true
        }

        return RESTStatusFallback(
            contexts: checkRunsPage.contexts + statuses,
            rateLimit: statusesRateLimit ?? checkRunsRateLimit,
            isTruncated: hasTruncatedCheckRuns || hasTruncatedStatuses
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
    private func decodeRESTCheckRuns(
        from data: Data
    ) throws -> (contexts: [AgentPRStatusContext], totalCount: Int?) {
        do {
            let response = try JSONDecoder.github.decode(RESTCheckRunsResponse.self, from: data)
            return (response.checkRuns.map(\.statusContext), response.totalCount)
        } catch {
            throw GitHubClientError.decodingFailed
        }
    }

    /// Decodes one REST combined commit-status page with its coverage metadata.
    private func decodeRESTStatuses(from data: Data) throws -> RESTCommitStatusResponse {
        do {
            return try JSONDecoder.github.decode(RESTCommitStatusResponse.self, from: data)
        } catch {
            throw GitHubClientError.decodingFailed
        }
    }

    /// Rebuilds GitHub's combined legacy-status state from the unique fetched contexts.
    private static func combinedStatusState(
        for contexts: [AgentPRStatusContext]
    ) -> AgentPRStatusState {
        guard !contexts.isEmpty else { return .pending }
        if contexts.contains(where: { $0.state.isFailure }) { return .failure }
        if contexts.contains(where: { $0.state.isWaiting }) { return .pending }
        if contexts.allSatisfy({ $0.state == .success }) { return .success }
        return .unknown
    }

    /// Decodes REST repository entries into picker summaries.
    private func decodeRESTRepositories(from data: Data) throws -> [GitHubRepositorySummary] {
        do {
            return try JSONDecoder.github.decode([RESTRepositoryNode].self, from: data).compactMap(\.repositorySummary)
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
        try mapRESTStatus(
            response: response,
            data: data,
            rateLimit: rateLimit,
            fallbackError: .repositoryDenied(repository)
        )
    }

    /// Maps HTTP metadata for repository-list requests into UI-safe typed errors.
    private static func validateRepositoryList(
        response: HTTPURLResponse,
        data: Data,
        rateLimit: GitHubRateLimitState?
    ) throws {
        try mapRESTStatus(
            response: response,
            data: data,
            rateLimit: rateLimit,
            fallbackError: .githubError
        )
    }

    /// Shared REST status mapping for GitHub responses with endpoint-specific fallback errors.
    private static func mapRESTStatus(
        response: HTTPURLResponse,
        data: Data,
        rateLimit: GitHubRateLimitState?,
        fallbackError: GitHubClientError
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
            throw fallbackError
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
    query AgentPRMonitor($owner: String!, $repo: String!, $first: Int!, $after: String) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: $first, after: $after, states: OPEN, orderBy: { field: UPDATED_AT, direction: DESC }) {
          pageInfo { hasNextPage endCursor }
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
            latestReviews(first: 100) {
              pageInfo { hasNextPage }
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
    /// Cursor for the next open pull request page.
    let after: String?
}

/// Minimal REST-style error body.
private nonisolated struct GitHubRESTError: Decodable {
    /// Human-readable GitHub error message.
    let message: String
}

/// REST repository response node used by the repository picker.
private nonisolated struct RESTRepositoryNode: Decodable {
    /// Repository name without owner.
    let name: String
    /// Optional repository description.
    let description: String?
    /// Privacy flag returned by GitHub.
    let isPrivate: Bool
    /// Archive flag returned by GitHub.
    let archived: Bool
    /// Last push timestamp.
    let pushedAt: Date?
    /// Owner payload.
    let owner: RESTRepositoryOwner

    /// App-facing picker summary when the response contains a valid owner/name pair.
    var repositorySummary: GitHubRepositorySummary? {
        guard !owner.login.isEmpty, !name.isEmpty else { return nil }
        let ref = GitHubRepositoryRef(owner: owner.login, name: name)
        return GitHubRepositorySummary(
            ref: ref,
            description: description,
            isPrivate: isPrivate,
            isArchived: archived,
            pushedAt: pushedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        /// Maps the repository name without transformation.
        case name
        /// Maps the optional repository description without transformation.
        case description
        /// Maps GitHub's reserved `private` field to the Swift privacy property.
        case isPrivate = "private"
        /// Maps the repository archive flag without transformation.
        case archived
        /// Maps GitHub's snake-case push timestamp.
        case pushedAt = "pushed_at"
        /// Maps the nested owner payload without transformation.
        case owner
    }
}

/// REST repository owner payload.
private nonisolated struct RESTRepositoryOwner: Decodable {
    /// Owner or organization login.
    let login: String
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
    let repository: RepositoryData?
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
    /// Pagination metadata for the open pull request list.
    let pageInfo: PageInfo?
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
            hasTruncatedLatestReviews: latestReviews.pageInfo?.hasNextPage == true,
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
    /// Pagination metadata when more latest reviews exist.
    let pageInfo: PageInfo?
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
    /// Whether another page exists after the fetched connection page.
    let hasNextPage: Bool
    /// Cursor for the next page, if available.
    let endCursor: String?
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
        /// Maps GraphQL's concrete-type discriminator.
        case typename = "__typename"
        /// Maps a check run's display name.
        case name
        /// Maps a check run's execution status.
        case status
        /// Maps a check run's terminal conclusion.
        case conclusion
        /// Maps a check run's provider details URL.
        case detailsUrl
        /// Maps a legacy status context's name.
        case context
        /// Maps a legacy status context's state.
        case state
        /// Maps a legacy status context's provider URL.
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
    /// Total check-run count declared by GitHub across all pages.
    let totalCount: Int?
    /// Check runs attached to the commit.
    let checkRuns: [RESTCheckRun]

    private enum CodingKeys: String, CodingKey {
        /// Maps GitHub's snake-case total count.
        case totalCount = "total_count"
        /// Maps GitHub's snake-case check-run collection.
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
        /// Maps the check-run name without transformation.
        case name
        /// Maps the check-run execution status without transformation.
        case status
        /// Maps the check-run terminal conclusion without transformation.
        case conclusion
        /// Maps GitHub's snake-case provider details URL.
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
    /// Global combined state declared by GitHub for this page's commit snapshot.
    let state: String?
    /// Total legacy statuses GitHub reports for the commit.
    let totalCount: Int?
    /// Legacy status contexts attached to the commit.
    let statuses: [RESTCommitStatus]

    private enum CodingKeys: String, CodingKey {
        /// Maps the combined state without transformation.
        case state
        /// Maps GitHub's snake-case total count.
        case totalCount = "total_count"
        /// Maps the status page without transformation.
        case statuses
    }
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
        /// Maps the legacy status context name without transformation.
        case context
        /// Maps the legacy status state without transformation.
        case state
        /// Maps GitHub's snake-case provider target URL.
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

    /// Case-insensitive identity used to detect pagination shifts and duplicate contexts.
    var canonicalContext: String? {
        guard let context else { return nil }
        let normalized = context.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
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
