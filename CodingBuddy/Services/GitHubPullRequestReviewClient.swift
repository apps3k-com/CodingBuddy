//
//  GitHubPullRequestReviewClient.swift
//  CodingBuddy
//

import Foundation

/// Read and mutation interface consumed by the pull request Review Desk.
nonisolated protocol GitHubPullRequestReviewServing: Sendable {
    /// Loads a fully paginated and internally consistent pull request snapshot.
    func fetchSnapshot(
        target: PullRequestReviewTarget,
        token: String
    ) async throws -> PullRequestReviewSnapshot

    /// Loads a fresh snapshot and creates a mutation-bound preflight proof.
    func prepareMutation(
        target: PullRequestReviewTarget,
        token: String,
        intent: PullRequestMutationIntent
    ) async throws -> (snapshot: PullRequestReviewSnapshot, preflight: PullRequestMutationPreflight)
}

/// Native GraphQL client for complete pull request review snapshots and guarded mutations.
nonisolated struct GitHubPullRequestReviewClient: GitHubPullRequestReviewServing {
    /// Injectable HTTP transport shared with the existing GitHub clients.
    let transport: any GitHubTransport
    /// GitHub GraphQL endpoint.
    let graphQLEndpoint: URL
    /// Maximum pages accepted for any one GraphQL connection.
    let pageLimit: Int
    /// Number of nodes requested per GraphQL page.
    let pageSize: Int
    /// Maximum accepted response size.
    let maximumResponseBytes: Int
    /// Maximum GraphQL reads across one complete nested snapshot.
    let maximumSnapshotRequests: Int
    /// Maximum pessimistically reserved nodes across one snapshot.
    let maximumSnapshotNodes: Int
    /// Maximum aggregate response bytes across one snapshot.
    let maximumSnapshotBytes: Int
    /// Clock used for deterministic snapshot capture times.
    private let now: @Sendable () -> Date
    /// Mutation correlation identifier source.
    private let makeMutationID: @Sendable () -> String
    /// Unpredictable one-use preflight identity source.
    private let makePreflightID: @Sendable () -> String
    /// Shared ledger preventing cross-action or repeated preflight use.
    private let preflightLedger: PullRequestPreflightLedger
    /// Budget inherited by every nested read spawned for one snapshot.
    @TaskLocal private static var activeSnapshotBudget: PullRequestSnapshotBudget?

    /// Creates a Review Desk client with injectable transport and determinism hooks.
    init(
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        graphQLEndpoint: URL = URL(string: "https://api.github.com/graphql")!,
        pageLimit: Int = 100,
        pageSize: Int = 50,
        maximumResponseBytes: Int = 10 * 1_024 * 1_024,
        maximumSnapshotRequests: Int = 256,
        maximumSnapshotNodes: Int = 25_600,
        maximumSnapshotBytes: Int = 64 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        makeMutationID: @escaping @Sendable () -> String = { UUID().uuidString },
        makePreflightID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.graphQLEndpoint = graphQLEndpoint
        self.pageLimit = max(1, pageLimit)
        self.pageSize = min(max(1, pageSize), 100)
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
        self.maximumSnapshotRequests = max(1, maximumSnapshotRequests)
        self.maximumSnapshotNodes = max(1, maximumSnapshotNodes)
        self.maximumSnapshotBytes = max(1_024, maximumSnapshotBytes)
        self.now = now
        self.makeMutationID = makeMutationID
        self.makePreflightID = makePreflightID
        self.preflightLedger = PullRequestPreflightLedger()
    }

    /// Loads every required connection and rejects drift observed during the read.
    func fetchSnapshot(
        target: PullRequestReviewTarget,
        token: String
    ) async throws -> PullRequestReviewSnapshot {
        let budget = PullRequestSnapshotBudget(
            maximumRequests: maximumSnapshotRequests,
            maximumNodes: maximumSnapshotNodes,
            maximumBytes: maximumSnapshotBytes
        )
        return try await Self.$activeSnapshotBudget.withValue(budget) {
            try await fetchSnapshotWithinBudget(target: target, token: token)
        }
    }

    /// Loads one snapshot while all nested reads share the active aggregate budget.
    private func fetchSnapshotWithinBudget(
        target: PullRequestReviewTarget,
        token: String
    ) async throws -> PullRequestReviewSnapshot {
        let token = try validatedToken(token)
        try validate(target: target)

        let initial = try await fetchBase(target: target, token: token)
        let comments = try await fetchConversationComments(pullRequestID: initial.id, token: token)
        let approvals = try await fetchApprovals(pullRequestID: initial.id, token: token)
        let threadMetadata = try await fetchThreadMetadata(pullRequestID: initial.id, token: token)
        var threads: [PullRequestReviewThread] = []
        for metadata in threadMetadata {
            let replies = try await fetchThreadComments(threadID: metadata.id, token: token)
            guard !replies.isEmpty else { throw GitHubPullRequestReviewError.invalidResponse }
            threads.append(metadata.reviewThread(comments: replies))
        }
        let checks = try await fetchChecks(
            pullRequestID: initial.id,
            pullRequestNumber: target.number,
            token: token
        )
        try Self.validateGlobalIdentifiers(
            pullRequestID: initial.id,
            checks: checks,
            approvals: approvals,
            comments: comments,
            threads: threads
        )
        let final = try await fetchBase(target: target, token: token)
        guard final == initial else { throw GitHubPullRequestReviewError.driftDetected }

        return PullRequestReviewSnapshot(
            target: target,
            pullRequestID: initial.id,
            title: initial.title,
            url: initial.url,
            headOID: initial.headRefOid,
            baseOID: initial.baseRefOid,
            headRefName: initial.headRefName,
            baseRefName: initial.baseRefName,
            isDraft: initial.isDraft,
            isMerged: initial.isMerged,
            reviewDecision: try normalizedReviewDecision(initial.reviewDecision),
            mergeState: try normalizedMergeState(initial.mergeStateStatus),
            checks: checks.sorted(by: Self.checkOrder),
            approvals: approvals.sorted(by: Self.approvalOrder),
            conversationComments: comments.sorted(by: Self.conversationOrder),
            reviewThreads: threads.sorted(by: Self.threadOrder),
            mergePolicy: initial.mergePolicy,
            mergeMethods: initial.mergeMethods,
            coverage: .complete,
            principalID: initial.principalID,
            capturedAt: now()
        )
    }

    /// Loads a fresh complete snapshot and binds it into a preflight proof.
    func prepareMutation(
        target: PullRequestReviewTarget,
        token: String,
        intent: PullRequestMutationIntent
    ) async throws -> (snapshot: PullRequestReviewSnapshot, preflight: PullRequestMutationPreflight) {
        let snapshot = try await fetchSnapshot(target: target, token: token)
        let preflight = try PullRequestMutationPreflight(
            snapshot: snapshot,
            intent: intent,
            nonce: makePreflightID()
        )
        guard await preflightLedger.issue(preflight.nonce) else {
            throw GitHubPullRequestReviewError.invalidMutation
        }
        return (snapshot, preflight)
    }

    /// Revokes an issued proof that the user declined before it can authorize a write.
    func discard(preflight: PullRequestMutationPreflight) async {
        await preflightLedger.discard(preflight.nonce)
    }

    /// Adds one reply to an existing unresolved review thread after a fresh drift check.
    func reply(
        to threadID: String,
        body: String,
        credential: GitHubCredential,
        preflight: PullRequestMutationPreflight
    ) async throws -> PullRequestMutationReceipt {
        let token = try requireWriteCredential(credential)
        guard !threadID.isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 65_536 else {
            throw GitHubPullRequestReviewError.invalidMutation
        }
        try await consume(preflight: preflight, for: .reply(threadID: threadID, body: body))
        let snapshot = try await validateFresh(preflight: preflight, token: token)
        guard snapshot.reviewThreads.contains(where: {
            $0.id == threadID && !$0.isResolved
        }) else {
            throw GitHubPullRequestReviewError.invalidMutation
        }
        let clientMutationID = makeMutationID()
        let variables = ReplyVariables(input: ReplyInput(
            pullRequestReviewThreadID: threadID,
            body: body,
            clientMutationID: clientMutationID
        ))
        let response: ReplyMutationData = try await mutation(
            query: Self.replyMutation,
            variables: variables,
            token: token
        )
        guard let payload = response.addPullRequestReviewThreadReply,
              !payload.comment.id.isEmpty else {
            throw GitHubPullRequestReviewError.mutationRejected
        }
        return PullRequestMutationReceipt(
            resourceID: payload.comment.id,
            clientMutationID: payload.clientMutationID
        )
    }

    /// Resolves one currently unresolved review thread after a fresh drift check.
    func resolve(
        threadID: String,
        credential: GitHubCredential,
        preflight: PullRequestMutationPreflight
    ) async throws -> PullRequestMutationReceipt {
        let token = try requireWriteCredential(credential)
        guard !threadID.isEmpty else { throw GitHubPullRequestReviewError.invalidMutation }
        try await consume(preflight: preflight, for: .resolve(threadID: threadID))
        let snapshot = try await validateFresh(preflight: preflight, token: token)
        guard snapshot.reviewThreads.contains(where: {
            $0.id == threadID && !$0.isResolved
        }) else {
            throw GitHubPullRequestReviewError.invalidMutation
        }
        let clientMutationID = makeMutationID()
        let variables = ResolveVariables(input: ResolveInput(
            threadID: threadID,
            clientMutationID: clientMutationID
        ))
        let response: ResolveMutationData = try await mutation(
            query: Self.resolveMutation,
            variables: variables,
            token: token
        )
        guard let payload = response.resolveReviewThread,
              payload.thread.id == threadID,
              payload.thread.isResolved else {
            throw GitHubPullRequestReviewError.mutationRejected
        }
        return PullRequestMutationReceipt(
            resourceID: payload.thread.id,
            clientMutationID: payload.clientMutationID
        )
    }

    /// Marks a draft pull request ready for review after a fresh drift check.
    func markReady(
        credential: GitHubCredential,
        preflight: PullRequestMutationPreflight
    ) async throws -> PullRequestMutationReceipt {
        let token = try requireWriteCredential(credential)
        try await consume(preflight: preflight, for: .markReady)
        let snapshot = try await validateFresh(preflight: preflight, token: token)
        guard snapshot.isDraft else { throw GitHubPullRequestReviewError.invalidMutation }
        let clientMutationID = makeMutationID()
        let variables = ReadyVariables(input: ReadyInput(
            pullRequestID: snapshot.pullRequestID,
            clientMutationID: clientMutationID
        ))
        let response: ReadyMutationData = try await mutation(
            query: Self.readyMutation,
            variables: variables,
            token: token
        )
        guard let payload = response.markPullRequestReadyForReview,
              payload.pullRequest.id == snapshot.pullRequestID,
              payload.pullRequest.isDraft == false else {
            throw GitHubPullRequestReviewError.mutationRejected
        }
        return PullRequestMutationReceipt(
            resourceID: payload.pullRequest.id,
            clientMutationID: payload.clientMutationID
        )
    }

    /// Merges a pull request only when conservative readiness gates and the head guard pass.
    func merge(
        method: PullRequestMergeMethod,
        credential: GitHubCredential,
        preflight: PullRequestMutationPreflight
    ) async throws -> PullRequestMutationReceipt {
        let token = try requireWriteCredential(credential)
        try await consume(preflight: preflight, for: .merge(method: method))
        let snapshot = try await validateFresh(preflight: preflight, token: token)
        guard snapshot.isMergeEligible,
              snapshot.mergeMethods.allows(method) else {
            throw GitHubPullRequestReviewError.mergeNotReady
        }
        let clientMutationID = makeMutationID()
        let variables = MergeVariables(input: MergeInput(
            pullRequestID: snapshot.pullRequestID,
            expectedHeadOid: preflight.expectedHeadOID,
            mergeMethod: method.rawValue,
            clientMutationID: clientMutationID
        ))
        let response: MergeMutationData = try await mutation(
            query: Self.mergeMutation,
            variables: variables,
            token: token
        )
        guard let payload = response.mergePullRequest,
              payload.pullRequest.id == snapshot.pullRequestID,
              payload.pullRequest.merged == true else {
            throw GitHubPullRequestReviewError.mutationRejected
        }
        return PullRequestMutationReceipt(
            resourceID: payload.pullRequest.id,
            clientMutationID: payload.clientMutationID
        )
    }

    /// Reloads complete state and compares both the bound digest and explicit head guard.
    private func validateFresh(
        preflight: PullRequestMutationPreflight,
        token: String
    ) async throws -> PullRequestReviewSnapshot {
        guard !preflight.snapshotDigest.isEmpty,
              !preflight.expectedHeadOID.isEmpty,
              !preflight.pullRequestID.isEmpty else {
            throw GitHubPullRequestReviewError.incompleteSnapshot
        }
        let snapshot = try await fetchSnapshot(target: preflight.target, token: token)
        guard snapshot.coverage == .complete else {
            throw GitHubPullRequestReviewError.incompleteSnapshot
        }
        guard snapshot.pullRequestID == preflight.pullRequestID,
              snapshot.principalID == preflight.principalID,
              snapshot.headOID == preflight.expectedHeadOID,
              snapshot.digest == preflight.snapshotDigest else {
            throw GitHubPullRequestReviewError.driftDetected
        }
        return snapshot
    }

    /// Consumes a matching issued preflight before any read or write network request.
    private func consume(
        preflight: PullRequestMutationPreflight,
        for expectedIntent: PullRequestMutationIntent
    ) async throws {
        guard preflight.intent == expectedIntent,
              await preflightLedger.consume(preflight.nonce) else {
            throw GitHubPullRequestReviewError.invalidMutation
        }
    }

    /// Derives write authority and token from the same credential value.
    private func requireWriteCredential(_ credential: GitHubCredential) throws -> String {
        guard credential.source == .githubAppDeviceFlow else {
            throw GitHubPullRequestReviewError.writesNotAllowed
        }
        return try validatedToken(credential.accessToken)
    }

    /// Validates and normalizes a token without including it in stored model state.
    private func validatedToken(_ token: String) throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 8_192 else {
            throw GitHubPullRequestReviewError.noToken
        }
        return token
    }

    /// Validates repository and pull request address components before network use.
    private func validate(target: PullRequestReviewTarget) throws {
        let owner = target.repository.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = target.repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !name.isEmpty, target.number > 0 else {
            throw GitHubPullRequestReviewError.invalidTarget
        }
    }

    /// Fetches the immutable metadata used to detect drift across a multi-request snapshot.
    private func fetchBase(
        target: PullRequestReviewTarget,
        token: String
    ) async throws -> RawPullRequestBase {
        let variables = BaseVariables(
            owner: target.repository.owner,
            repo: target.repository.name,
            number: target.number
        )
        let response: BaseData = try await query(
            query: Self.baseQuery,
            variables: variables,
            token: token
        )
        guard let viewer = response.viewer,
              !viewer.id.isEmpty,
              let repository = response.repository,
              let pullRequest = repository.pullRequest,
              !pullRequest.id.isEmpty,
              !pullRequest.headRefOid.isEmpty,
              !pullRequest.baseRefOid.isEmpty,
              !pullRequest.headRefName.isEmpty,
              !pullRequest.baseRefName.isEmpty else {
            throw GitHubPullRequestReviewError.pullRequestUnavailable
        }
        _ = try normalizedReviewDecision(pullRequest.reviewDecision)
        _ = try normalizedMergeState(pullRequest.mergeStateStatus)
        return pullRequest.withRepositoryMetadata(
            principalID: viewer.id,
            mergeMethods: repository.mergeMethods
        )
    }

    /// Fetches every top-level conversation comment with strict cursor and identity checks.
    private func fetchConversationComments(
        pullRequestID: String,
        token: String
    ) async throws -> [PullRequestConversationComment] {
        var tracker = PaginationTracker(pageLimit: pageLimit)
        var result: [PullRequestConversationComment] = []
        var after: String?
        repeat {
            try tracker.beginPage()
            let variables = ConnectionVariables(id: pullRequestID, first: pageSize, after: after)
            let response: ConversationData = try await query(
                query: Self.conversationQuery,
                variables: variables,
                token: token
            )
            guard let connection = response.node?.comments else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            result.append(contentsOf: connection.nodes.map(\.conversationComment))
            after = try tracker.consume(
                ids: connection.nodes.map(\.id),
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo
            )
        } while after != nil
        return result
    }

    /// Fetches every submitted approval review with strict cursor and identity checks.
    private func fetchApprovals(
        pullRequestID: String,
        token: String
    ) async throws -> [PullRequestApproval] {
        var tracker = PaginationTracker(pageLimit: pageLimit)
        var result: [PullRequestApproval] = []
        var after: String?
        repeat {
            try tracker.beginPage()
            let variables = ConnectionVariables(id: pullRequestID, first: pageSize, after: after)
            let response: ApprovalData = try await query(
                query: Self.approvalQuery,
                variables: variables,
                token: token
            )
            guard let connection = response.node?.reviews else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            result.append(contentsOf: connection.nodes.map(\.approval))
            after = try tracker.consume(
                ids: connection.nodes.map(\.id),
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo
            )
        } while after != nil
        return result
    }

    /// Fetches metadata for every review thread before loading each nested comment connection.
    private func fetchThreadMetadata(
        pullRequestID: String,
        token: String
    ) async throws -> [RawThreadNode] {
        var tracker = PaginationTracker(pageLimit: pageLimit)
        var result: [RawThreadNode] = []
        var after: String?
        repeat {
            try tracker.beginPage()
            let variables = ConnectionVariables(id: pullRequestID, first: pageSize, after: after)
            let response: ThreadData = try await query(
                query: Self.threadQuery,
                variables: variables,
                token: token
            )
            guard let connection = response.node?.reviewThreads else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            result.append(contentsOf: connection.nodes)
            after = try tracker.consume(
                ids: connection.nodes.map(\.id),
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo
            )
        } while after != nil
        return result
    }

    /// Fetches every comment and reply for one review thread.
    private func fetchThreadComments(
        threadID: String,
        token: String
    ) async throws -> [PullRequestReviewThreadComment] {
        var tracker = PaginationTracker(pageLimit: pageLimit)
        var result: [PullRequestReviewThreadComment] = []
        var after: String?
        repeat {
            try tracker.beginPage()
            let variables = ConnectionVariables(id: threadID, first: pageSize, after: after)
            let response: ThreadCommentData = try await query(
                query: Self.threadCommentQuery,
                variables: variables,
                token: token
            )
            guard let connection = response.node?.comments else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            result.append(contentsOf: connection.nodes.map(\.threadComment))
            after = try tracker.consume(
                ids: connection.nodes.map(\.id),
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo
            )
        } while after != nil
        return result.sorted(by: Self.threadCommentOrder)
    }

    /// Fetches every check run and status context for the current pull request head.
    private func fetchChecks(
        pullRequestID: String,
        pullRequestNumber: Int,
        token: String
    ) async throws -> [PullRequestCheck] {
        var tracker = PaginationTracker(pageLimit: pageLimit)
        var result: [PullRequestCheck] = []
        var after: String?
        var sawRollup = false
        repeat {
            try tracker.beginPage()
            let variables = CheckVariables(
                id: pullRequestID,
                number: pullRequestNumber,
                first: pageSize,
                after: after
            )
            let response: CheckData = try await query(
                query: Self.checkQuery,
                variables: variables,
                token: token
            )
            guard let pullRequest = response.node else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            guard let connection = pullRequest.statusCheckRollup?.contexts else {
                if sawRollup || after != nil { throw GitHubPullRequestReviewError.incompletePagination }
                return []
            }
            sawRollup = true
            let mapped = try connection.nodes.map { try $0.check }
            result.append(contentsOf: mapped)
            after = try tracker.consume(
                ids: mapped.map(\.id),
                totalCount: connection.totalCount,
                pageInfo: connection.pageInfo
            )
        } while after != nil
        return result
    }

    /// Performs a typed GraphQL read and rejects any partial error payload.
    private func query<Variables: Encodable & Sendable, ResponseData: Decodable>(
        query: String,
        variables: Variables,
        token: String
    ) async throws -> ResponseData {
        try Self.activeSnapshotBudget?.reserveRequest(estimatedNodes: pageSize)
        let request = try makeRequest(query: query, variables: variables, token: token)
        let (data, response) = try await performRead(request)
        try Self.activeSnapshotBudget?.consume(bytes: data.count)
        try validateHTTP(response: response)
        return try decodeGraphQL(data: data)
    }

    /// Performs exactly one GraphQL write request and never retries ambiguous failures.
    private func mutation<Variables: Encodable & Sendable, ResponseData: Decodable>(
        query: String,
        variables: Variables,
        token: String
    ) async throws -> ResponseData {
        let token = try validatedToken(token)
        let request = try makeRequest(query: query, variables: variables, token: token)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw GitHubPullRequestReviewError.ambiguousWrite
        }
        guard data.count <= maximumResponseBytes else {
            throw GitHubPullRequestReviewError.ambiguousWrite
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw GitHubPullRequestReviewError.authenticationFailed
        case 403:
            throw GitHubPullRequestReviewError.missingPermission
        case 429:
            throw GitHubPullRequestReviewError.rateLimited
        case 500...599:
            throw GitHubPullRequestReviewError.ambiguousWrite
        default:
            throw GitHubPullRequestReviewError.mutationRejected
        }
        do {
            return try decodeGraphQL(data: data)
        } catch {
            throw GitHubPullRequestReviewError.ambiguousWrite
        }
    }

    /// Creates one authenticated JSON GraphQL request.
    private func makeRequest<Variables: Encodable>(
        query: String,
        variables: Variables,
        token: String
    ) throws -> URLRequest {
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(TypedGraphQLRequest(query: query, variables: variables))
        return request
    }

    /// Performs one read request and maps transport failures conservatively.
    private func performRead(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            guard data.count <= maximumResponseBytes else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            return (data, response)
        } catch let error as GitHubPullRequestReviewError {
            throw error
        } catch {
            throw GitHubPullRequestReviewError.networkUnavailable
        }
    }

    /// Maps HTTP status codes without parsing or exposing provider error messages.
    private func validateHTTP(response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubPullRequestReviewError.authenticationFailed
        case 403:
            throw GitHubPullRequestReviewError.missingPermission
        case 404:
            throw GitHubPullRequestReviewError.pullRequestUnavailable
        case 429:
            throw GitHubPullRequestReviewError.rateLimited
        default:
            throw GitHubPullRequestReviewError.server(statusCode: response.statusCode)
        }
    }

    /// Decodes a GraphQL envelope and rejects error-bearing or partial responses.
    private func decodeGraphQL<ResponseData: Decodable>(data: Data) throws -> ResponseData {
        let envelope: GraphQLEnvelope<ResponseData>
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(GraphQLEnvelope<ResponseData>.self, from: data)
        } catch {
            throw GitHubPullRequestReviewError.invalidResponse
        }
        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "FORBIDDEN" || $0.type == "INSUFFICIENT_SCOPES" }) {
                throw GitHubPullRequestReviewError.missingPermission
            }
            throw GitHubPullRequestReviewError.invalidResponse
        }
        guard let payload = envelope.data else {
            throw GitHubPullRequestReviewError.invalidResponse
        }
        return payload
    }

    /// Normalizes GitHub review-decision values and rejects future unknown values.
    private func normalizedReviewDecision(_ value: String?) throws -> PullRequestReviewDecision {
        switch value {
        case nil:
            return .none
        case "APPROVED":
            return .approved
        case "CHANGES_REQUESTED":
            return .changesRequested
        case "REVIEW_REQUIRED":
            return .reviewRequired
        default:
            throw GitHubPullRequestReviewError.unknownState
        }
    }

    /// Normalizes GitHub merge-state values and rejects `UNKNOWN` or future values.
    private func normalizedMergeState(_ value: String) throws -> PullRequestMergeState {
        switch value {
        case "BEHIND":
            return .behind
        case "BLOCKED":
            return .blocked
        case "CLEAN":
            return .clean
        case "DIRTY":
            return .dirty
        case "HAS_HOOKS":
            return .hasHooks
        case "UNSTABLE":
            return .unstable
        default:
            throw GitHubPullRequestReviewError.unknownState
        }
    }

    /// Stable ordering for check digests and UI presentation.
    private static func checkOrder(_ lhs: PullRequestCheck, _ rhs: PullRequestCheck) -> Bool {
        (lhs.name < rhs.name)
            || (lhs.name == rhs.name && lhs.id < rhs.id)
    }

    /// Rejects identities repeated across otherwise independent GraphQL connections.
    private static func validateGlobalIdentifiers(
        pullRequestID: String,
        checks: [PullRequestCheck],
        approvals: [PullRequestApproval],
        comments: [PullRequestConversationComment],
        threads: [PullRequestReviewThread]
    ) throws {
        var seen = Set<String>()
        let identifiers = [pullRequestID]
            + checks.map(\.id)
            + approvals.map(\.id)
            + comments.map(\.id)
            + threads.flatMap { [$0.id] + $0.comments.map(\.id) }
        for identifier in identifiers {
            guard !identifier.isEmpty else {
                throw GitHubPullRequestReviewError.invalidResponse
            }
            guard seen.insert(identifier).inserted else {
                throw GitHubPullRequestReviewError.duplicateIdentifier(identifier)
            }
        }
    }

    /// Stable ordering for approval digests and UI presentation.
    private static func approvalOrder(_ lhs: PullRequestApproval, _ rhs: PullRequestApproval) -> Bool {
        (lhs.submittedAt ?? .distantPast, lhs.id) < (rhs.submittedAt ?? .distantPast, rhs.id)
    }

    /// Stable ordering for top-level conversation comments.
    private static func conversationOrder(
        _ lhs: PullRequestConversationComment,
        _ rhs: PullRequestConversationComment
    ) -> Bool {
        (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }

    /// Stable ordering for review threads.
    private static func threadOrder(_ lhs: PullRequestReviewThread, _ rhs: PullRequestReviewThread) -> Bool {
        (lhs.path ?? "", lhs.line ?? Int.min, lhs.id) < (rhs.path ?? "", rhs.line ?? Int.min, rhs.id)
    }

    /// Stable ordering for comments within a review thread.
    private static func threadCommentOrder(
        _ lhs: PullRequestReviewThreadComment,
        _ rhs: PullRequestReviewThreadComment
    ) -> Bool {
        (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }
}

/// Actor-owned one-use registry shared by copies of one Review Desk client.
private actor PullRequestPreflightLedger {
    /// Issued nonces that have not yet authorized an action.
    private var issuedNonces = Set<String>()

    /// Registers a unique preflight nonce.
    func issue(_ nonce: String) -> Bool {
        !nonce.isEmpty && issuedNonces.insert(nonce).inserted
    }

    /// Removes and accepts a nonce exactly once.
    func consume(_ nonce: String) -> Bool {
        issuedNonces.remove(nonce) != nil
    }

    /// Revokes an unused nonce after its confirmation is dismissed.
    func discard(_ nonce: String) {
        issuedNonces.remove(nonce)
    }
}

/// Lock-protected aggregate work budget inherited by one complete snapshot task tree.
private nonisolated final class PullRequestSnapshotBudget: @unchecked Sendable {
    /// Lock protecting all counters.
    private let lock = NSLock()
    /// Configured hard limits.
    private let maximumRequests: Int
    private let maximumNodes: Int
    private let maximumBytes: Int
    /// Work consumed so far.
    private var requests = 0
    private var nodes = 0
    private var bytes = 0

    /// Creates a fresh zero-consumption snapshot budget.
    init(maximumRequests: Int, maximumNodes: Int, maximumBytes: Int) {
        self.maximumRequests = maximumRequests
        self.maximumNodes = maximumNodes
        self.maximumBytes = maximumBytes
    }

    /// Reserves one request and its worst-case page node capacity before network I/O.
    func reserveRequest(estimatedNodes: Int) throws {
        try lock.withLock {
            guard requests < maximumRequests,
                  estimatedNodes >= 0,
                  nodes <= maximumNodes - estimatedNodes else {
                throw GitHubPullRequestReviewError.snapshotBudgetExceeded
            }
            requests += 1
            nodes += estimatedNodes
        }
    }

    /// Adds actual response bytes after transport completion.
    func consume(bytes additionalBytes: Int) throws {
        try lock.withLock {
            guard additionalBytes >= 0,
                  bytes <= maximumBytes - additionalBytes else {
                throw GitHubPullRequestReviewError.snapshotBudgetExceeded
            }
            bytes += additionalBytes
        }
    }
}

private extension GitHubPullRequestReviewClient {
    /// Query for immutable pull request metadata used at both ends of a snapshot read.
    static let baseQuery = """
    query ReviewDeskBase($owner: String!, $repo: String!, $number: Int!) {
      viewer { id }
      repository(owner: $owner, name: $repo) {
        mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
        pullRequest(number: $number) {
          id title url updatedAt isDraft merged reviewDecision mergeStateStatus
          headRefOid baseRefOid headRefName baseRefName
          baseRef {
            branchProtectionRule {
              requiresApprovingReviews requiredApprovingReviewCount
              requiresStatusChecks requiresStrictStatusChecks
              requiresConversationResolution isAdminEnforced
              bypassPullRequestAllowances(first: 1) { totalCount }
            }
          }
        }
      }
    }
    """

    /// Query for one page of top-level pull request comments.
    static let conversationQuery = """
    query ReviewDeskComments($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on PullRequest {
        comments(first: $first, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id author { login } body createdAt updatedAt url }
        }
      } }
    }
    """

    /// Query for one page of submitted approval reviews.
    static let approvalQuery = """
    query ReviewDeskApprovals($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on PullRequest {
        reviews(first: $first, after: $after, states: [APPROVED]) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id author { login } submittedAt url }
        }
      } }
    }
    """

    /// Query for one page of review-thread metadata.
    static let threadQuery = """
    query ReviewDeskThreads($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on PullRequest {
        reviewThreads(first: $first, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id isResolved isOutdated path line originalLine }
        }
      } }
    }
    """

    /// Query for one page of comments in a single review thread.
    static let threadCommentQuery = """
    query ReviewDeskThreadComments($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on PullRequestReviewThread {
        comments(first: $first, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id author { login } body createdAt updatedAt url }
        }
      } }
    }
    """

    /// Query for one page of all check and status contexts on the current head.
    static let checkQuery = """
    query ReviewDeskChecks($id: ID!, $number: Int!, $first: Int!, $after: String) {
      node(id: $id) { ... on PullRequest {
        statusCheckRollup { contexts(first: $first, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun {
              id name status conclusion detailsUrl
              isRequired(pullRequestNumber: $number)
            }
            ... on StatusContext {
              id context state targetUrl
              isRequired(pullRequestNumber: $number)
            }
          }
        } }
      } }
    }
    """

    /// Mutation that adds a reply to one review thread.
    static let replyMutation = """
    mutation ReviewDeskReply($input: AddPullRequestReviewThreadReplyInput!) {
      addPullRequestReviewThreadReply(input: $input) {
        clientMutationId comment { id }
      }
    }
    """

    /// Mutation that resolves one review thread.
    static let resolveMutation = """
    mutation ReviewDeskResolve($input: ResolveReviewThreadInput!) {
      resolveReviewThread(input: $input) {
        clientMutationId thread { id isResolved }
      }
    }
    """

    /// Mutation that marks one pull request ready for review.
    static let readyMutation = """
    mutation ReviewDeskReady($input: MarkPullRequestReadyForReviewInput!) {
      markPullRequestReadyForReview(input: $input) {
        clientMutationId pullRequest { id isDraft }
      }
    }
    """

    /// Mutation that merges one pull request with an explicit expected-head guard.
    static let mergeMutation = """
    mutation ReviewDeskMerge($input: MergePullRequestInput!) {
      mergePullRequest(input: $input) {
        clientMutationId pullRequest { id merged }
      }
    }
    """
}

/// Generic encodable GraphQL request envelope.
private nonisolated struct TypedGraphQLRequest<Variables: Encodable>: Encodable {
    /// GraphQL operation text.
    let query: String
    /// Typed operation variables.
    let variables: Variables
}

/// Generic decodable GraphQL response envelope.
private nonisolated struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    /// Successful operation data.
    let data: Payload?
    /// Provider errors; any entry makes the response unusable.
    let errors: [ReviewGraphQLError]?
}

/// Minimal GraphQL error metadata used for safe classification.
private nonisolated struct ReviewGraphQLError: Decodable {
    /// Stable provider error type when available.
    let type: String?
}

/// Variables for the pull request base query.
private nonisolated struct BaseVariables: Encodable, Sendable {
    /// Repository owner.
    let owner: String
    /// Repository name.
    let repo: String
    /// Pull request number.
    let number: Int
}

/// Variables shared by node-based connection queries.
private nonisolated struct ConnectionVariables: Encodable, Sendable {
    /// GraphQL node identity.
    let id: String
    /// Requested page size.
    let first: Int
    /// Cursor from the preceding page.
    let after: String?
}

/// Variables for the status-check connection query.
private nonisolated struct CheckVariables: Encodable, Sendable {
    /// Pull request GraphQL identity.
    let id: String
    /// Pull request number used by GitHub's required-context resolver.
    let number: Int
    /// Requested page size.
    let first: Int
    /// Cursor from the preceding page.
    let after: String?
}

/// Successful base-query data.
private nonisolated struct BaseData: Decodable {
    /// Authenticated viewer used to bind preflights to one GitHub principal.
    let viewer: BaseViewer?
    /// Repository payload when visible.
    let repository: BaseRepository?
}

/// Minimal authenticated principal payload.
private nonisolated struct BaseViewer: Decodable {
    /// Stable GitHub node identity.
    let id: String
}

/// Repository payload containing the addressed pull request.
private nonisolated struct BaseRepository: Decodable {
    /// Whether merge commits are enabled for the repository.
    let mergeCommitAllowed: Bool?
    /// Whether squash merges are enabled for the repository.
    let squashMergeAllowed: Bool?
    /// Whether rebase merges are enabled for the repository.
    let rebaseMergeAllowed: Bool?
    /// Pull request payload when visible.
    let pullRequest: RawPullRequestBase?

    /// Fail-closed repository merge-method settings.
    var mergeMethods: PullRequestMergeMethods {
        PullRequestMergeMethods(
            mergeCommitAllowed: mergeCommitAllowed,
            squashMergeAllowed: squashMergeAllowed,
            rebaseMergeAllowed: rebaseMergeAllowed
        )
    }
}

/// Immutable pull request fields compared before and after pagination.
private nonisolated struct RawPullRequestBase: Decodable, Equatable {
    /// Principal attached locally after decoding the sibling viewer payload.
    var principalID: String = ""
    /// Repository merge methods attached after decoding sibling repository fields.
    var mergeMethods: PullRequestMergeMethods = .unverified
    /// GraphQL identity.
    let id: String
    /// Pull request title.
    let title: String
    /// Browser URL.
    let url: URL
    /// Last provider update timestamp.
    let updatedAt: Date
    /// Draft state.
    let isDraft: Bool
    /// Merged state.
    let isMerged: Bool
    /// Nullable review decision enum.
    let reviewDecision: String?
    /// Merge-state enum.
    let mergeStateStatus: String
    /// Current head OID.
    let headRefOid: String
    /// Current base OID.
    let baseRefOid: String
    /// Head branch name.
    let headRefName: String
    /// Base branch name.
    let baseRefName: String
    /// Base ref and its classic branch-protection rule when visible.
    let baseRef: RawBaseRef?

    /// Fail-closed merge policy decoded from the protected base ref.
    var mergePolicy: PullRequestMergePolicy {
        guard let rule = baseRef?.branchProtectionRule else { return .unverified }
        return PullRequestMergePolicy(
            requiresApprovingReviews: rule.requiresApprovingReviews,
            requiredApprovingReviewCount: rule.requiredApprovingReviewCount,
            requiresStatusChecks: rule.requiresStatusChecks,
            requiresStrictStatusChecks: rule.requiresStrictStatusChecks,
            requiresConversationResolution: rule.requiresConversationResolution,
            isAdminEnforced: rule.isAdminEnforced,
            bypassAllowanceCount: rule.bypassPullRequestAllowances.totalCount
        )
    }

    /// Returns an otherwise identical base record bound to viewer and repository settings.
    func withRepositoryMetadata(
        principalID: String,
        mergeMethods: PullRequestMergeMethods
    ) -> RawPullRequestBase {
        var copy = self
        copy.principalID = principalID
        copy.mergeMethods = mergeMethods
        return copy
    }

    /// Provider keys exclude the locally attached principal.
    private enum CodingKeys: String, CodingKey {
        /// Stable pull request node identity.
        case id
        /// Provider title used for inspection and snapshot drift.
        case title
        /// Canonical pull request browser URL.
        case url
        /// Provider update timestamp.
        case updatedAt
        /// Current draft state.
        case isDraft
        /// Current merged state.
        case isMerged = "merged"
        /// Current repository review decision.
        case reviewDecision
        /// Current provider merge-state status.
        case mergeStateStatus
        /// Current head commit object ID.
        case headRefOid
        /// Current base commit object ID.
        case baseRefOid
        /// Current head branch name.
        case headRefName
        /// Current base branch name.
        case baseRefName
        /// Current base ref carrying classic branch-protection metadata.
        case baseRef
    }

    /// Decodes current GitHub metadata while keeping older deterministic fixtures valid.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        isMerged = try container.decodeIfPresent(Bool.self, forKey: .isMerged) ?? false
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeStateStatus = try container.decode(String.self, forKey: .mergeStateStatus)
        headRefOid = try container.decode(String.self, forKey: .headRefOid)
        baseRefOid = try container.decode(String.self, forKey: .baseRefOid)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        baseRef = try container.decodeIfPresent(RawBaseRef.self, forKey: .baseRef)
    }
}

/// Pull request base ref carrying the applicable classic branch-protection rule.
private nonisolated struct RawBaseRef: Decodable, Equatable {
    /// Rule applied to the base branch, or nil when unavailable or unprotected.
    let branchProtectionRule: RawBranchProtectionRule?
}

/// GitHub-enforced branch settings required for an atomic Review Desk merge.
private nonisolated struct RawBranchProtectionRule: Decodable, Equatable {
    /// Whether approving reviews are required.
    let requiresApprovingReviews: Bool
    /// Minimum number of approving reviews.
    let requiredApprovingReviewCount: Int?
    /// Whether status checks are required.
    let requiresStatusChecks: Bool
    /// Whether the head must remain current with the protected base.
    let requiresStrictStatusChecks: Bool
    /// Whether review conversations must be resolved.
    let requiresConversationResolution: Bool
    /// Whether administrators are also bound by this rule.
    let isAdminEnforced: Bool
    /// Actors that may bypass pull request requirements.
    let bypassPullRequestAllowances: RawBypassAllowanceConnection
}

/// Count-only bypass connection used to reject any merge-policy exception.
private nonisolated struct RawBypassAllowanceConnection: Decodable, Equatable {
    /// Number of users, teams, or apps allowed to bypass pull request requirements.
    let totalCount: Int
}

/// Generic GraphQL page metadata.
private nonisolated struct ReviewPageInfo: Decodable {
    /// Whether another page follows.
    let hasNextPage: Bool
    /// Cursor for the next page.
    let endCursor: String?
}

/// State machine that proves cursor progress, unique identities, and total-count coverage.
private nonisolated struct PaginationTracker {
    /// Maximum pages accepted for the connection.
    let pageLimit: Int
    /// Number of pages requested so far.
    private var pageCount = 0
    /// Cursors already followed.
    private var seenCursors = Set<String>()
    /// Stable identities already observed.
    private var seenIDs = Set<String>()
    /// Provider-declared total count from the first page.
    private var declaredTotalCount: Int?

    /// Creates a bounded pagination tracker.
    init(pageLimit: Int) {
        self.pageLimit = pageLimit
    }

    /// Records an impending page request and rejects page-limit overflow.
    mutating func beginPage() throws {
        pageCount += 1
        guard pageCount <= pageLimit else {
            throw GitHubPullRequestReviewError.incompletePagination
        }
    }

    /// Consumes one page and returns the next cursor only after all coverage checks pass.
    mutating func consume(
        ids: [String],
        totalCount: Int,
        pageInfo: ReviewPageInfo
    ) throws -> String? {
        guard totalCount >= 0,
              ids.allSatisfy({ !$0.isEmpty }) else {
            throw GitHubPullRequestReviewError.invalidResponse
        }
        if let declaredTotalCount, declaredTotalCount != totalCount {
            throw GitHubPullRequestReviewError.incompletePagination
        }
        declaredTotalCount = declaredTotalCount ?? totalCount
        for id in ids {
            guard seenIDs.insert(id).inserted else {
                throw GitHubPullRequestReviewError.duplicateIdentifier(id)
            }
        }
        if pageInfo.hasNextPage {
            guard !ids.isEmpty,
                  let cursor = pageInfo.endCursor,
                  !cursor.isEmpty,
                  seenCursors.insert(cursor).inserted else {
                throw GitHubPullRequestReviewError.incompletePagination
            }
            return cursor
        }
        guard pageInfo.endCursor == nil || !seenIDs.isEmpty,
              seenIDs.count == totalCount else {
            throw GitHubPullRequestReviewError.incompletePagination
        }
        return nil
    }
}

/// Top-level conversation-page data.
private nonisolated struct ConversationData: Decodable {
    /// Pull request node payload.
    let node: ConversationNode?
}

/// Pull request node carrying top-level comments.
private nonisolated struct ConversationNode: Decodable {
    /// Comment connection.
    let comments: ConversationConnection
}

/// Fully described top-level comment page.
private nonisolated struct ConversationConnection: Decodable {
    /// Provider-declared total comments.
    let totalCount: Int
    /// Pagination metadata.
    let pageInfo: ReviewPageInfo
    /// Comments on this page.
    let nodes: [RawConversationComment]
}

/// Raw top-level comment node.
private nonisolated struct RawConversationComment: Decodable {
    /// GraphQL identity.
    let id: String
    /// Author payload.
    let author: RawLogin?
    /// Markdown body.
    let body: String
    /// Creation timestamp.
    let createdAt: Date
    /// Update timestamp.
    let updatedAt: Date
    /// Browser URL.
    let url: URL

    /// App-facing top-level comment.
    var conversationComment: PullRequestConversationComment {
        PullRequestConversationComment(
            id: id,
            authorLogin: author?.login,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            url: url
        )
    }
}

/// Top-level approval-page data.
private nonisolated struct ApprovalData: Decodable {
    /// Pull request node payload.
    let node: ApprovalNode?
}

/// Pull request node carrying approval reviews.
private nonisolated struct ApprovalNode: Decodable {
    /// Approval review connection.
    let reviews: ApprovalConnection
}

/// Fully described approval-review page.
private nonisolated struct ApprovalConnection: Decodable {
    /// Provider-declared total approvals.
    let totalCount: Int
    /// Pagination metadata.
    let pageInfo: ReviewPageInfo
    /// Approvals on this page.
    let nodes: [RawApproval]
}

/// Raw approval review node.
private nonisolated struct RawApproval: Decodable {
    /// GraphQL identity.
    let id: String
    /// Reviewer payload.
    let author: RawLogin?
    /// Submission timestamp.
    let submittedAt: Date?
    /// Browser URL.
    let url: URL?

    /// App-facing approval entry.
    var approval: PullRequestApproval {
        PullRequestApproval(id: id, authorLogin: author?.login, submittedAt: submittedAt, url: url)
    }
}

/// Top-level review-thread page data.
private nonisolated struct ThreadData: Decodable {
    /// Pull request node payload.
    let node: ThreadNodeContainer?
}

/// Pull request node carrying review threads.
private nonisolated struct ThreadNodeContainer: Decodable {
    /// Review-thread connection.
    let reviewThreads: ThreadConnection
}

/// Fully described review-thread page.
private nonisolated struct ThreadConnection: Decodable {
    /// Provider-declared total threads.
    let totalCount: Int
    /// Pagination metadata.
    let pageInfo: ReviewPageInfo
    /// Threads on this page.
    let nodes: [RawThreadNode]
}

/// Raw review-thread metadata loaded before nested comments.
private nonisolated struct RawThreadNode: Decodable {
    /// GraphQL identity.
    let id: String
    /// Resolution state.
    let isResolved: Bool
    /// Outdated-location state.
    let isOutdated: Bool
    /// Repository-relative path.
    let path: String?
    /// Current line.
    let line: Int?
    /// Original line.
    let originalLine: Int?

    /// Creates an app-facing thread after its complete comment connection is available.
    func reviewThread(comments: [PullRequestReviewThreadComment]) -> PullRequestReviewThread {
        PullRequestReviewThread(
            id: id,
            isResolved: isResolved,
            isOutdated: isOutdated,
            path: path,
            line: line,
            originalLine: originalLine,
            comments: comments
        )
    }
}

/// Top-level nested thread-comment page data.
private nonisolated struct ThreadCommentData: Decodable {
    /// Review-thread node payload.
    let node: ThreadCommentNode?
}

/// Review-thread node carrying comments.
private nonisolated struct ThreadCommentNode: Decodable {
    /// Thread-comment connection.
    let comments: ThreadCommentConnection
}

/// Fully described nested thread-comment page.
private nonisolated struct ThreadCommentConnection: Decodable {
    /// Provider-declared total comments.
    let totalCount: Int
    /// Pagination metadata.
    let pageInfo: ReviewPageInfo
    /// Thread comments on this page.
    let nodes: [RawThreadComment]
}

/// Raw inline review comment node.
private nonisolated struct RawThreadComment: Decodable {
    /// GraphQL identity.
    let id: String
    /// Author payload.
    let author: RawLogin?
    /// Markdown body.
    let body: String
    /// Creation timestamp.
    let createdAt: Date
    /// Update timestamp.
    let updatedAt: Date
    /// Browser URL.
    let url: URL

    /// App-facing thread comment.
    var threadComment: PullRequestReviewThreadComment {
        PullRequestReviewThreadComment(
            id: id,
            authorLogin: author?.login,
            body: body,
            createdAt: createdAt,
            updatedAt: updatedAt,
            url: url
        )
    }
}

/// Top-level status-check page data.
private nonisolated struct CheckData: Decodable {
    /// Pull request node payload.
    let node: CheckPullRequestNode?
}

/// Pull request node carrying the current status rollup.
private nonisolated struct CheckPullRequestNode: Decodable {
    /// Status rollup, or `nil` when the head has no checks or statuses.
    let statusCheckRollup: RawStatusCheckRollup?
}

/// Raw status-check rollup.
private nonisolated struct RawStatusCheckRollup: Decodable {
    /// Check and status-context connection.
    let contexts: CheckConnection
}

/// Fully described check/status page.
private nonisolated struct CheckConnection: Decodable {
    /// Provider-declared total contexts.
    let totalCount: Int
    /// Pagination metadata.
    let pageInfo: ReviewPageInfo
    /// Contexts on this page.
    let nodes: [RawCheckNode]
}

/// Polymorphic check-run or legacy status-context node.
private nonisolated struct RawCheckNode: Decodable {
    /// GraphQL concrete type.
    let typename: String
    /// GraphQL identity.
    let id: String
    /// Check-run display name.
    let name: String?
    /// Check-run execution status.
    let status: String?
    /// Check-run terminal conclusion.
    let conclusion: String?
    /// Check-run details URL.
    let detailsUrl: URL?
    /// Legacy status-context name.
    let context: String?
    /// Legacy status state.
    let state: String?
    /// Legacy status target URL.
    let targetUrl: URL?
    /// Required-context result from GitHub.
    let isRequired: Bool

    /// Maps the polymorphic provider node into a fail-closed app check.
    var check: PullRequestCheck {
        get throws {
            guard !id.isEmpty else { throw GitHubPullRequestReviewError.invalidResponse }
            switch typename {
            case "CheckRun":
                guard let name, !name.isEmpty, let status else {
                    throw GitHubPullRequestReviewError.invalidResponse
                }
                return PullRequestCheck(
                    id: id,
                    name: name,
                    state: try Self.checkRunState(status: status, conclusion: conclusion),
                    isRequired: isRequired,
                    detailsURL: detailsUrl
                )
            case "StatusContext":
                guard let context, !context.isEmpty, let state else {
                    throw GitHubPullRequestReviewError.invalidResponse
                }
                return PullRequestCheck(
                    id: id,
                    name: context,
                    state: try Self.statusContextState(state),
                    isRequired: isRequired,
                    detailsURL: targetUrl
                )
            default:
                throw GitHubPullRequestReviewError.unknownState
            }
        }
    }

    /// Normalizes a check-run status and conclusion pair.
    private static func checkRunState(
        status: String,
        conclusion: String?
    ) throws -> PullRequestCheckState {
        switch status {
        case "REQUESTED", "QUEUED", "IN_PROGRESS", "WAITING", "PENDING":
            return .pending
        case "COMPLETED":
            switch conclusion {
            case "SUCCESS": return .success
            case "FAILURE", "STARTUP_FAILURE": return .failure
            case "NEUTRAL": return .neutral
            case "SKIPPED": return .skipped
            case "CANCELLED": return .cancelled
            case "TIMED_OUT": return .timedOut
            case "ACTION_REQUIRED": return .actionRequired
            case "STALE": return .stale
            default: throw GitHubPullRequestReviewError.unknownState
            }
        default:
            throw GitHubPullRequestReviewError.unknownState
        }
    }

    /// Normalizes a legacy commit-status state.
    private static func statusContextState(_ state: String) throws -> PullRequestCheckState {
        switch state {
        case "EXPECTED", "PENDING": return .pending
        case "SUCCESS": return .success
        case "ERROR", "FAILURE": return .failure
        default: throw GitHubPullRequestReviewError.unknownState
        }
    }

    private enum CodingKeys: String, CodingKey {
        /// GraphQL concrete-type discriminator.
        case typename = "__typename"
        /// GraphQL identity.
        case id
        /// Check-run name.
        case name
        /// Check-run status.
        case status
        /// Check-run conclusion.
        case conclusion
        /// Check-run details URL.
        case detailsUrl
        /// Legacy context name.
        case context
        /// Legacy status state.
        case state
        /// Legacy target URL.
        case targetUrl
        /// Required-context flag.
        case isRequired
    }
}

/// Minimal GraphQL actor payload.
private nonisolated struct RawLogin: Decodable {
    /// GitHub login.
    let login: String
}

/// Variables for a review-thread reply mutation.
private nonisolated struct ReplyVariables: Encodable, Sendable {
    /// Mutation input.
    let input: ReplyInput
}

/// Input for a review-thread reply mutation.
private nonisolated struct ReplyInput: Encodable, Sendable {
    /// Review thread identity.
    let pullRequestReviewThreadID: String
    /// Markdown reply body.
    let body: String
    /// Client correlation identity.
    let clientMutationID: String

    private enum CodingKeys: String, CodingKey {
        /// GraphQL input spelling for the thread identity.
        case pullRequestReviewThreadID = "pullRequestReviewThreadId"
        /// GraphQL input spelling for the body.
        case body
        /// GraphQL input spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
    }
}

/// Variables for a resolve-thread mutation.
private nonisolated struct ResolveVariables: Encodable, Sendable {
    /// Mutation input.
    let input: ResolveInput
}

/// Input for a resolve-thread mutation.
private nonisolated struct ResolveInput: Encodable, Sendable {
    /// Review thread identity.
    let threadID: String
    /// Client correlation identity.
    let clientMutationID: String

    private enum CodingKeys: String, CodingKey {
        /// GraphQL input spelling for the thread identity.
        case threadID = "threadId"
        /// GraphQL input spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
    }
}

/// Variables for a ready-for-review mutation.
private nonisolated struct ReadyVariables: Encodable, Sendable {
    /// Mutation input.
    let input: ReadyInput
}

/// Input for a ready-for-review mutation.
private nonisolated struct ReadyInput: Encodable, Sendable {
    /// Pull request identity.
    let pullRequestID: String
    /// Client correlation identity.
    let clientMutationID: String

    private enum CodingKeys: String, CodingKey {
        /// GraphQL input spelling for the pull request identity.
        case pullRequestID = "pullRequestId"
        /// GraphQL input spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
    }
}

/// Variables for a pull request merge mutation.
private nonisolated struct MergeVariables: Encodable, Sendable {
    /// Mutation input.
    let input: MergeInput
}

/// Input for a pull request merge mutation.
private nonisolated struct MergeInput: Encodable, Sendable {
    /// Pull request identity.
    let pullRequestID: String
    /// Expected head object ID.
    let expectedHeadOid: String
    /// GitHub merge-method enum value.
    let mergeMethod: String
    /// Client correlation identity.
    let clientMutationID: String

    private enum CodingKeys: String, CodingKey {
        /// GraphQL input spelling for the pull request identity.
        case pullRequestID = "pullRequestId"
        /// GraphQL input spelling for the expected head.
        case expectedHeadOid
        /// GraphQL input spelling for the merge method.
        case mergeMethod
        /// GraphQL input spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
    }
}

/// Successful reply-mutation data.
private nonisolated struct ReplyMutationData: Decodable {
    /// Mutation payload.
    let addPullRequestReviewThreadReply: ReplyMutationPayload?
}

/// Reply-mutation payload.
private nonisolated struct ReplyMutationPayload: Decodable {
    /// Client correlation identity returned by GitHub.
    let clientMutationID: String?
    /// Created review comment.
    let comment: MutationResource

    private enum CodingKeys: String, CodingKey {
        /// GraphQL response spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
        /// Created comment payload.
        case comment
    }
}

/// Successful resolve-mutation data.
private nonisolated struct ResolveMutationData: Decodable {
    /// Mutation payload.
    let resolveReviewThread: ResolveMutationPayload?
}

/// Resolve-mutation payload.
private nonisolated struct ResolveMutationPayload: Decodable {
    /// Client correlation identity returned by GitHub.
    let clientMutationID: String?
    /// Resolved thread payload.
    let thread: MutationThread

    private enum CodingKeys: String, CodingKey {
        /// GraphQL response spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
        /// Resolved thread payload.
        case thread
    }
}

/// Successful ready-mutation data.
private nonisolated struct ReadyMutationData: Decodable {
    /// Mutation payload.
    let markPullRequestReadyForReview: ReadyMutationPayload?
}

/// Ready-mutation payload.
private nonisolated struct ReadyMutationPayload: Decodable {
    /// Client correlation identity returned by GitHub.
    let clientMutationID: String?
    /// Updated pull request payload.
    let pullRequest: MutationPullRequest

    private enum CodingKeys: String, CodingKey {
        /// GraphQL response spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
        /// Updated pull request payload.
        case pullRequest
    }
}

/// Successful merge-mutation data.
private nonisolated struct MergeMutationData: Decodable {
    /// Mutation payload.
    let mergePullRequest: MergeMutationPayload?
}

/// Merge-mutation payload.
private nonisolated struct MergeMutationPayload: Decodable {
    /// Client correlation identity returned by GitHub.
    let clientMutationID: String?
    /// Merged pull request payload.
    let pullRequest: MutationPullRequest

    private enum CodingKeys: String, CodingKey {
        /// GraphQL response spelling for the correlation identity.
        case clientMutationID = "clientMutationId"
        /// Merged pull request payload.
        case pullRequest
    }
}

/// Mutation resource carrying only a stable identity.
private nonisolated struct MutationResource: Decodable {
    /// GraphQL identity.
    let id: String
}

/// Mutation thread payload used to verify resolution.
private nonisolated struct MutationThread: Decodable {
    /// GraphQL identity.
    let id: String
    /// Resolution state after the mutation.
    let isResolved: Bool
}

/// Mutation pull request payload used to verify ready and merge outcomes.
private nonisolated struct MutationPullRequest: Decodable {
    /// GraphQL identity.
    let id: String
    /// Draft state when returned by a ready mutation.
    let isDraft: Bool?
    /// Merge state when returned by a merge mutation.
    let merged: Bool?
}
