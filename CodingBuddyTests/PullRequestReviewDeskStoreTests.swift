//
//  PullRequestReviewDeskStoreTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// State-machine tests for selection, confirmation ownership, and preflight revocation.
@MainActor
struct PullRequestReviewDeskStoreTests {
    /// Verifies selecting a monitor row publishes only a complete focused snapshot.
    @Test func selectionLoadsCompleteSnapshot() async throws {
        let transport = ReviewDeskStoreTransport(responses: Self.minimalReadResponses())
        let store = makeStore(transport: transport)

        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }

        #expect(store.selectedTarget == target)
        #expect(store.snapshot?.coverage == .complete)
        #expect(store.snapshot?.principalID == "viewer-1")
        #expect(store.actionsAreEnabled)
    }

    /// Verifies a pending confirmation owns selection and cancellation revokes its nonce.
    @Test func cancelConfirmationRevokesPreflightAndReleasesSelection() async throws {
        let responses = Self.minimalReadResponses() + Self.minimalReadResponses()
        let transport = ReviewDeskStoreTransport(responses: responses)
        let client = GitHubPullRequestReviewClient(
            transport: transport,
            pageSize: 1,
            makePreflightID: { "store-preflight" }
        )
        let store = makeStore(transport: transport, client: client)
        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }

        store.requestMarkReadyConfirmation()
        try await waitUntil { store.pendingConfirmation != nil }
        let preflight = try #require(store.pendingConfirmation?.preflight)
        #expect(!store.select(pullRequest(number: 110)))

        store.cancelConfirmation()
        for _ in 0..<20 { await Task.yield() }

        await #expect(throws: GitHubPullRequestReviewError.invalidMutation) {
            try await client.markReady(
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requestCount == responses.count)
        #expect(store.pendingConfirmation == nil)
        #expect(store.actionState == .idle)
    }

    /// Verifies an uncertain write blocks retries until a fresh snapshot proves the transition.
    @Test func ambiguousReadyWriteBlocksActionsUntilVerificationProvesApplication() async throws {
        let responses = Self.minimalReadResponses()
            + Self.minimalReadResponses()
            + Self.minimalReadResponses()
            + Self.minimalReadResponses(isDraft: false)
        let transport = ReviewDeskStoreTransport(
            responses: responses,
            failingRequestNumbers: [19]
        )
        let store = makeStore(transport: transport)
        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }
        store.requestMarkReadyConfirmation()
        try await waitUntil { store.pendingConfirmation != nil }

        store.confirmPendingAction()
        try await waitUntil { store.actionState == .ambiguous }

        #expect(store.hasAmbiguousAction)
        #expect(!store.actionsAreEnabled)
        #expect(!store.select(pullRequest(number: 110)))

        store.verifyAmbiguousAction()
        try await waitUntil { store.lastVerifiedAction == .markReady }

        #expect(!store.hasAmbiguousAction)
        #expect(store.snapshot?.isDraft == false)
        #expect(store.actionsAreEnabled)
    }

    /// Verifies explicit acknowledgement is required when the user resolves ambiguity on GitHub.
    @Test func ambiguousWriteCanOnlyBeReleasedByExplicitAcknowledgement() async throws {
        let responses = Self.minimalReadResponses()
            + Self.minimalReadResponses()
            + Self.minimalReadResponses()
        let transport = ReviewDeskStoreTransport(
            responses: responses,
            failingRequestNumbers: [19]
        )
        let store = makeStore(transport: transport)
        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }
        store.requestMarkReadyConfirmation()
        try await waitUntil { store.pendingConfirmation != nil }
        store.confirmPendingAction()
        try await waitUntil { store.actionState == .ambiguous }

        store.clearActionNotice()
        #expect(store.actionState == .ambiguous)
        #expect(!store.select(pullRequest(number: 110)))

        store.acknowledgeAmbiguousAction()

        #expect(store.actionState == .idle)
        #expect(!store.hasAmbiguousAction)
        #expect(store.select(pullRequest(number: 110)))
    }

    /// Verifies identical concurrent reply text cannot prove an ambiguous write was ours.
    @Test func ambiguousReplyDoesNotAcceptMatchingForeignComment() async throws {
        let responses = Self.threadReadResponses(commentIDs: ["R1"])
            + Self.threadReadResponses(commentIDs: ["R1"])
            + Self.threadReadResponses(commentIDs: ["R1"])
            + Self.threadReadResponses(commentIDs: ["R1", "R2"], addedBody: "Handled.")
        let transport = ReviewDeskStoreTransport(
            responses: responses,
            failingRequestNumbers: [22]
        )
        let store = makeStore(transport: transport)
        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }

        store.reply(threadID: "T1", body: "Handled.")
        try await waitUntil { store.actionState == .ambiguous }
        store.verifyAmbiguousAction()
        try await waitUntil { store.snapshot?.reviewThreads.first?.comments.count == 2 }

        #expect(store.actionState == .ambiguous)
        #expect(store.hasAmbiguousAction)
        #expect(store.lastVerifiedAction == nil)
    }

    /// Verifies GitHub's exact reply receipt proves the matching new comment after re-fetch.
    @Test func successfulReplyUsesReceiptToVerifyExactComment() async throws {
        let responses = Self.threadReadResponses(commentIDs: ["R1"])
            + Self.threadReadResponses(commentIDs: ["R1"])
            + Self.threadReadResponses(commentIDs: ["R1"])
            + [#"{"data":{"addPullRequestReviewThreadReply":{"clientMutationId":"mutation-1","comment":{"id":"R2"}}}}"#]
            + Self.threadReadResponses(commentIDs: ["R1", "R2"], addedBody: "Handled.")
        let transport = ReviewDeskStoreTransport(responses: responses)
        let client = GitHubPullRequestReviewClient(
            transport: transport,
            pageSize: 50,
            makeMutationID: { "mutation-1" }
        )
        let store = makeStore(transport: transport, client: client)
        #expect(store.select(pullRequest()))
        try await waitUntil { store.state == .loaded }

        store.reply(threadID: "T1", body: "Handled.")
        try await waitUntil { store.lastVerifiedAction != nil }

        #expect(store.lastVerifiedAction == .reply(threadID: "T1", body: "Handled."))
        #expect(!store.hasAmbiguousAction)
    }

    /// Repository target shared by deterministic fixtures.
    private var target: PullRequestReviewTarget {
        PullRequestReviewTarget(
            repository: GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
            number: 109
        )
    }

    /// GitHub App credential accepted by the mutation boundary.
    private var appCredential: GitHubCredential {
        GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "device-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil
        )
    }

    /// Creates a production-shaped store with an in-memory credential backend.
    private func makeStore(
        transport: ReviewDeskStoreTransport,
        client: GitHubPullRequestReviewClient? = nil
    ) -> PullRequestReviewDeskStore {
        let credentialStore = ReviewDeskStoreCredentialStore(credential: appCredential)
        return PullRequestReviewDeskStore(
            client: client ?? GitHubPullRequestReviewClient(transport: transport, pageSize: 1),
            credentialCoordinator: GitHubCredentialCoordinator(
                tokenStore: credentialStore,
                oauthClient: nil
            )
        )
    }

    /// Creates one monitor row without touching the existing monitor service.
    private func pullRequest(number: Int = 109) -> AgentPullRequest {
        AgentPullRequest(
            repository: GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
            number: number,
            title: "Review Desk",
            url: URL(string: "https://github.com/apps3k-com/CodingBuddy/pull/\(number)")!,
            isDraft: true,
            authorLogin: "developer",
            source: .likelyHuman,
            headRefName: "bvk/pr-review-desk-109",
            headSHA: "head-oid",
            baseRefName: "main",
            linkedIssues: [],
            review: AgentPRReviewSummary(decision: .reviewRequired, latestReviews: [], threads: []),
            checks: AgentPRCheckSummary(contexts: []),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// Waits for one observable state transition without a wall-clock dependency.
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw ReviewDeskStoreTestError.timedOut
    }

    /// Complete minimal snapshot sequence used for reads and preflights.
    private static func minimalReadResponses(isDraft: Bool = true) -> [String] {
        let baseResponse = baseResponse(isDraft: isDraft)
        return [
            baseResponse,
            connectionResponse(field: "comments"),
            connectionResponse(field: "reviews"),
            connectionResponse(field: "reviewThreads"),
            #"{"data":{"node":{"statusCheckRollup":null}}}"#,
            baseResponse,
        ]
    }

    /// Complete focused snapshot containing one review thread and deterministic comments.
    private static func threadReadResponses(
        commentIDs: [String],
        addedBody: String? = nil
    ) -> [String] {
        let comments = commentIDs.map { id in
            let body = id == "R2" ? (addedBody ?? "Handled.") : "Original"
            return #"{"id":"\#(id)","author":{"login":"reviewer"},"body":"\#(body)","createdAt":"2026-07-17T10:00:00Z","updatedAt":"2026-07-17T10:00:00Z","url":"https://github.com/apps3k-com/CodingBuddy/pull/109#discussion_\#(id)"}"#
        }.joined(separator: ",")
        let base = baseResponse(isDraft: true)
        return [
            base,
            connectionResponse(field: "comments"),
            connectionResponse(field: "reviews"),
            #"{"data":{"node":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":false,"isOutdated":false,"path":"CodingBuddy/App.swift","line":10,"originalLine":10}]}}}}"#,
            #"{"data":{"node":{"comments":{"totalCount":\#(commentIDs.count),"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(comments)]}}}}"#,
            #"{"data":{"node":{"statusCheckRollup":null}}}"#,
            base,
        ]
    }

    /// Stable draft base payload including authenticated viewer identity.
    private static func baseResponse(isDraft: Bool) -> String {
        #"{"data":{"viewer":{"id":"viewer-1"},"repository":{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,"pullRequest":{"id":"PR1","title":"Review Desk","url":"https://github.com/apps3k-com/CodingBuddy/pull/109","updatedAt":"2026-07-17T10:00:00Z","isDraft":\#(isDraft),"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED","headRefOid":"head-oid","baseRefOid":"base-oid","headRefName":"bvk/pr-review-desk-109","baseRefName":"main"}}}}"#
    }

    /// Empty complete GraphQL connection payload.
    private static func connectionResponse(field: String) -> String {
        "{\"data\":{\"node\":{\"\(field)\":{\"totalCount\":0,\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}"
    }
}

/// Store-test-only timeout marker.
private enum ReviewDeskStoreTestError: Error {
    case timedOut
}

/// Thread-safe queued transport for store state transitions.
private final class ReviewDeskStoreTransport: GitHubTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var requests = 0
    private let failingRequestNumbers: Set<Int>

    init(responses: [String], failingRequestNumbers: Set<Int> = []) {
        self.responses = responses
        self.failingRequestNumbers = failingRequestNumbers
    }

    var requestCount: Int { lock.withLock { requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try lock.withLock { () throws -> String in
            requests += 1
            if failingRequestNumbers.contains(requests) {
                throw URLError(.networkConnectionLost)
            }
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            return responses.removeFirst()
        }
        let data = Data(body.utf8)
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

/// Thread-safe in-memory credential backend for store tests.
private final class ReviewDeskStoreCredentialStore: GitHubTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: GitHubCredential?

    init(credential: GitHubCredential?) {
        self.credential = credential
    }

    func loadToken() throws -> String? { lock.withLock { credential?.accessToken } }
    func saveToken(_ token: String) throws { lock.withLock { credential = .personalAccessToken(token) } }
    func deleteToken() throws { lock.withLock { credential = nil } }
    func loadCredential() throws -> GitHubCredential? { lock.withLock { credential } }
    func saveCredential(_ credential: GitHubCredential) throws { lock.withLock { self.credential = credential } }
}
