//
//  GitHubPullRequestReviewClientTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Regression coverage for complete Review Desk snapshots and guarded GraphQL mutations.
@Suite(.serialized)
struct GitHubPullRequestReviewClientTests {
    /// Stable repository fixture.
    private let repository = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy")
    /// Stable pull request target fixture.
    private var target: PullRequestReviewTarget {
        PullRequestReviewTarget(repository: repository, number: 109)
    }
    /// Stable snapshot capture timestamp.
    private let capturedAt = Date(timeIntervalSince1970: 1_784_282_400)

    /// Verifies all independent and nested GraphQL connections paginate to completion.
    @Test func fetchSnapshotPaginatesEveryConnectionAndNestedThreadReplies() async throws {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse()),
            .ok(Self.conversationPage(ids: ["C1"], total: 2, next: "comments-2")),
            .ok(Self.conversationPage(ids: ["C2"], total: 2)),
            .ok(Self.approvalPage(ids: ["A1"], total: 2, next: "approvals-2")),
            .ok(Self.approvalPage(ids: ["A2"], total: 2)),
            .ok(Self.threadPage(ids: ["T1"], total: 1)),
            .ok(Self.threadCommentPage(ids: ["R1"], total: 2, next: "replies-2")),
            .ok(Self.threadCommentPage(ids: ["R2"], total: 2)),
            .ok(Self.checkPage(ids: ["K1"], total: 2, next: "checks-2")),
            .ok(Self.checkPage(ids: ["S1"], total: 2, statusContext: true)),
            .ok(Self.baseResponse()),
        ])
        let client = makeClient(transport: transport)

        let snapshot = try await client.fetchSnapshot(target: target, token: " device-token ")

        #expect(snapshot.coverage == .complete)
        #expect(snapshot.conversationComments.map(\.id) == ["C1", "C2"])
        #expect(snapshot.approvals.map(\.id) == ["A1", "A2"])
        #expect(snapshot.reviewThreads.map(\.id) == ["T1"])
        #expect(snapshot.reviewThreads[0].comments.map(\.id) == ["R1", "R2"])
        #expect(snapshot.checks.map(\.id) == ["K1", "S1"])
        #expect(snapshot.requiredChecks.map(\.id) == ["K1"])
        #expect(snapshot.digest.count == 64)
        #expect(transport.requests.count == 11)
        #expect(try transport.variables(at: 2)["after"] as? String == "comments-2")
        #expect(try transport.variables(at: 7)["after"] as? String == "replies-2")
        #expect(try transport.variables(at: 9)["after"] as? String == "checks-2")
    }

    /// Verifies a repeated cursor fails closed before unrelated connections are read.
    @Test func fetchSnapshotRejectsCursorCycles() async {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse()),
            .ok(Self.conversationPage(ids: ["C1"], total: 3, next: "cycle")),
            .ok(Self.conversationPage(ids: ["C2"], total: 3, next: "cycle")),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.incompletePagination) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
        #expect(transport.requests.count == 3)
    }

    /// Verifies repeated stable identities fail closed even when cursors advance.
    @Test func fetchSnapshotRejectsDuplicateNodeIdentifiers() async {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse()),
            .ok(Self.conversationPage(ids: ["C1"], total: 2, next: "comments-2")),
            .ok(Self.conversationPage(ids: ["C1"], total: 2)),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.duplicateIdentifier("C1")) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
    }

    /// Verifies a terminal page whose node count contradicts `totalCount` is incomplete.
    @Test func fetchSnapshotRejectsTruncatedConnections() async {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse()),
            .ok(Self.conversationPage(ids: ["C1"], total: 2)),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.incompletePagination) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
    }

    /// Verifies a connection that exceeds the configured page bound is rejected.
    @Test func fetchSnapshotRejectsPageLimitOverflow() async {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse()),
            .ok(Self.conversationPage(ids: ["C1"], total: 2, next: "comments-2")),
        ])
        let client = makeClient(transport: transport, pageLimit: 1)

        await #expect(throws: GitHubPullRequestReviewError.incompletePagination) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
        #expect(transport.requests.count == 2)
    }

    /// Verifies provider enum growth cannot be interpreted as a safe known state.
    @Test func fetchSnapshotRejectsUnknownMergeState() async {
        let transport = ReviewDeskRecordingTransport(responses: [
            .ok(Self.baseResponse(mergeState: "UNKNOWN")),
        ])
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.unknownState) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
    }

    /// Verifies unknown check conclusions fail closed rather than becoming successful.
    @Test func fetchSnapshotRejectsUnknownCheckConclusion() async {
        let transport = ReviewDeskRecordingTransport(responses: Self.minimalReadResponses(
            checks: Self.checkPage(ids: ["K1"], total: 1, conclusion: "FUTURE_STATE"),
            includeFinalBase: false
        ))
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.unknownState) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
    }

    /// Verifies metadata or head drift across pagination invalidates the entire snapshot.
    @Test func fetchSnapshotRejectsDriftAcrossConsistencyReads() async {
        let responses = Self.minimalReadResponses(
            finalBase: Self.baseResponse(headOID: "different-head")
        )
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)

        await #expect(throws: GitHubPullRequestReviewError.driftDetected) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
    }

    /// Verifies legacy PAT capabilities block writes before any preflight network request.
    @Test func replyRejectsPATWritesWithoutCallingTransport() async throws {
        let transport = ReviewDeskRecordingTransport(responses: [])
        let client = makeClient(transport: transport)
        let preflight = try PullRequestMutationPreflight(
            snapshot: modelSnapshot(withThread: true),
            intent: .reply(threadID: "T1", body: "Handled."),
            nonce: "unregistered-preflight"
        )

        await #expect(throws: GitHubPullRequestReviewError.writesNotAllowed) {
            try await client.reply(
                to: "T1",
                body: "Handled.",
                credential: .personalAccessToken("pat-token"),
                preflight: preflight
            )
        }
        #expect(transport.requests.isEmpty)
    }

    /// Verifies a preflight cannot authorize a different mutation intent.
    @Test func preflightRejectsCrossActionReuseBeforeNetwork() async throws {
        let responses = Self.minimalReadResponses(isDraft: true)
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.invalidMutation) {
            try await client.merge(
                method: .squash,
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == responses.count)
    }

    /// Verifies a reply proof cannot authorize even whitespace-only cleartext drift.
    @Test func replyPreflightRejectsChangedBodyBeforeNetwork() async throws {
        let responses = Self.threadReadResponses()
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .reply(threadID: "T1", body: "Original body")
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.invalidMutation) {
            try await client.reply(
                to: "T1",
                body: "Original body ",
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == responses.count)
    }

    /// Verifies a preflight cannot cross GitHub principals even when PR state is identical.
    @Test func mutationRejectsPrincipalChangeBeforeWrite() async throws {
        let responses = Self.minimalReadResponses(viewerID: "viewer-1", isDraft: true)
            + Self.minimalReadResponses(viewerID: "viewer-2", isDraft: true)
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.driftDetected) {
            try await client.markReady(credential: appCredential, preflight: preflight)
        }
        #expect(transport.requests.count == responses.count)
    }

    /// Verifies aggregate snapshot work fails before exceeding its request budget.
    @Test func fetchSnapshotEnforcesAggregateRequestBudget() async {
        let responses = Self.minimalReadResponses()
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport, maximumSnapshotRequests: 3)

        await #expect(throws: GitHubPullRequestReviewError.snapshotBudgetExceeded) {
            try await client.fetchSnapshot(target: target, token: "device-token")
        }
        #expect(transport.requests.count == 3)
    }

    /// Verifies a reply uses the bound thread ID, body, and deterministic correlation value.
    @Test func replyRevalidatesSnapshotAndSendsExpectedMutationVariables() async throws {
        let responses = Self.threadReadResponses() + Self.threadReadResponses() + [
            .ok(#"{"data":{"addPullRequestReviewThreadReply":{"clientMutationId":"mutation-1","comment":{"id":"R2"}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .reply(threadID: "T1", body: "Handled safely.")
        ).preflight

        let receipt = try await client.reply(
            to: "T1",
            body: "Handled safely.",
            credential: appCredential,
            preflight: preflight
        )

        let variables = try transport.variables(at: transport.requests.count - 1)
        let input = try #require(variables["input"] as? [String: Any])
        #expect(input["pullRequestReviewThreadId"] as? String == "T1")
        #expect(input["body"] as? String == "Handled safely.")
        #expect(input["clientMutationId"] as? String == "mutation-1")
        #expect(receipt.resourceID == "R2")
    }

    /// Verifies resolve-thread sends the exact guarded thread identity.
    @Test func resolveRevalidatesSnapshotAndSendsExpectedMutationVariables() async throws {
        let responses = Self.threadReadResponses() + Self.threadReadResponses() + [
            .ok(#"{"data":{"resolveReviewThread":{"clientMutationId":"mutation-1","thread":{"id":"T1","isResolved":true}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .resolve(threadID: "T1")
        ).preflight

        _ = try await client.resolve(
            threadID: "T1",
            credential: appCredential,
            preflight: preflight
        )

        let input = try #require(
            transport.variables(at: transport.requests.count - 1)["input"] as? [String: Any]
        )
        #expect(input["threadId"] as? String == "T1")
        #expect(input["clientMutationId"] as? String == "mutation-1")
    }

    /// Verifies ready-for-review sends the pull request node identity after draft revalidation.
    @Test func markReadyRevalidatesSnapshotAndSendsExpectedMutationVariables() async throws {
        let responses = Self.minimalReadResponses(isDraft: true)
            + Self.minimalReadResponses(isDraft: true) + [
            .ok(#"{"data":{"markPullRequestReadyForReview":{"clientMutationId":"mutation-1","pullRequest":{"id":"PR1","isDraft":false}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        _ = try await client.markReady(
            credential: appCredential,
            preflight: preflight
        )

        let input = try #require(
            transport.variables(at: transport.requests.count - 1)["input"] as? [String: Any]
        )
        #expect(input["pullRequestId"] as? String == "PR1")
    }

    /// Verifies one issued preflight cannot be replayed after a successful write.
    @Test func preflightCanBeConsumedOnlyOnce() async throws {
        let responses = Self.minimalReadResponses(isDraft: true)
            + Self.minimalReadResponses(isDraft: true) + [
            .ok(#"{"data":{"markPullRequestReadyForReview":{"clientMutationId":"mutation-1","pullRequest":{"id":"PR1","isDraft":false}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        _ = try await client.markReady(
            credential: appCredential,
            preflight: preflight
        )
        await #expect(throws: GitHubPullRequestReviewError.invalidMutation) {
            try await client.markReady(
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == responses.count)
    }

    /// Verifies merge sends both the selected method and explicit expected-head OID.
    @Test func mergeRevalidatesReadinessAndSendsExpectedHeadGuard() async throws {
        let mergeSnapshotResponses = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1),
            mergePolicyJSON: Self.strictMergePolicyJSON
        )
        let responses = mergeSnapshotResponses + mergeSnapshotResponses + [
            .ok(#"{"data":{"mergePullRequest":{"clientMutationId":"mutation-1","pullRequest":{"id":"PR1","merged":true}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .merge(method: .squash)
        ).preflight

        _ = try await client.merge(
            method: .squash,
            credential: appCredential,
            preflight: preflight
        )

        let input = try #require(
            transport.variables(at: transport.requests.count - 1)["input"] as? [String: Any]
        )
        #expect(input["pullRequestId"] as? String == "PR1")
        #expect(input["expectedHeadOid"] as? String == "head-oid")
        #expect(input["mergeMethod"] as? String == "SQUASH")
    }

    /// Verifies a repository-disabled merge method is rejected before mutation transport.
    @Test func mergeRejectsRepositoryDisabledMethod() async throws {
        let mergeSnapshotResponses = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1),
            mergePolicyJSON: Self.strictMergePolicyJSON,
            squashMergeAllowed: false
        )
        let transport = ReviewDeskRecordingTransport(
            responses: mergeSnapshotResponses + mergeSnapshotResponses
        )
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .merge(method: .squash)
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.mergeNotReady) {
            try await client.merge(
                method: .squash,
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == mergeSnapshotResponses.count * 2)
    }

    /// Verifies locally green state cannot authorize merge without complete server enforcement.
    @Test func mergeEligibilityFailsClosedWithoutStrictServerPolicy() async throws {
        let localGreenResponses = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1)
        )
        let transport = ReviewDeskRecordingTransport(responses: localGreenResponses)
        let snapshot = try await makeClient(transport: transport).fetchSnapshot(
            target: target,
            token: "device-token"
        )

        #expect(snapshot.mergePolicy == .unverified)
        #expect(!snapshot.isMergeEligible)
    }

    /// Verifies any configured bypass keeps an otherwise strict pull request non-mergeable.
    @Test func mergeEligibilityRejectsServerPolicyBypasses() async throws {
        let responses = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1),
            mergePolicyJSON: Self.bypassMergePolicyJSON
        )
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let snapshot = try await makeClient(transport: transport).fetchSnapshot(
            target: target,
            token: "device-token"
        )

        #expect(snapshot.mergePolicy.bypassAllowanceCount == 1)
        #expect(!snapshot.mergePolicy.enforcesReviewDeskGates)
        #expect(!snapshot.isMergeEligible)
    }

    /// Verifies digest drift stops before the queued mutation response is consumed.
    @Test func mutationRejectsDigestDriftBeforeWrite() async throws {
        let responses = Self.minimalReadResponses(isDraft: true)
            + Self.minimalReadResponses(title: "Changed title", isDraft: true) + [
            .ok(#"{"data":{"markPullRequestReadyForReview":{"clientMutationId":"mutation-1","pullRequest":{"id":"PR1","isDraft":false}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.driftDetected) {
            try await client.markReady(
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(
            transport.requests.count
                == Self.minimalReadResponses(isDraft: true).count
                    + Self.minimalReadResponses(title: "Changed title", isDraft: true).count
        )
    }

    /// Verifies branch-protection drift invalidates a merge preflight before any write.
    @Test func mergeRejectsServerPolicyDriftBeforeWrite() async throws {
        let strict = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1),
            mergePolicyJSON: Self.strictMergePolicyJSON
        )
        let bypassed = Self.minimalReadResponses(
            reviewDecision: "APPROVED",
            mergeState: "CLEAN",
            checks: Self.checkPage(ids: ["K1"], total: 1),
            mergePolicyJSON: Self.bypassMergePolicyJSON
        )
        let responses = strict + bypassed + [
            .ok(#"{"data":{"mergePullRequest":{"clientMutationId":"mutation-1","pullRequest":{"id":"PR1","merged":true}}}}"#),
        ]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .merge(method: .squash)
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.driftDetected) {
            try await client.merge(
                method: .squash,
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == strict.count + bypassed.count)
    }

    /// Verifies transport failure during a write is surfaced as ambiguous and not retried.
    @Test func mutationTransportFailureIsAmbiguousAndNotRetried() async throws {
        let responses = Self.minimalReadResponses(isDraft: true)
            + Self.minimalReadResponses(isDraft: true)
            + [.failure(URLError(.networkConnectionLost))]
        let transport = ReviewDeskRecordingTransport(responses: responses)
        let client = makeClient(transport: transport)
        let preflight = try await client.prepareMutation(
            target: target,
            token: "device-token",
            intent: .markReady
        ).preflight

        await #expect(throws: GitHubPullRequestReviewError.ambiguousWrite) {
            try await client.markReady(
                credential: appCredential,
                preflight: preflight
            )
        }
        #expect(transport.requests.count == responses.count)
    }

    /// Creates a deterministic client around one recording transport.
    private var appCredential: GitHubCredential {
        GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "device-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil
        )
    }

    /// Creates a deterministic client around one recording transport.
    private func makeClient(
        transport: ReviewDeskRecordingTransport,
        pageLimit: Int = 10,
        maximumSnapshotRequests: Int = 256
    ) -> GitHubPullRequestReviewClient {
        GitHubPullRequestReviewClient(
            transport: transport,
            pageLimit: pageLimit,
            pageSize: 1,
            maximumSnapshotRequests: maximumSnapshotRequests,
            now: { capturedAt },
            makeMutationID: { "mutation-1" },
            makePreflightID: { "preflight-1" }
        )
    }

    /// Creates an app-facing snapshot matching the deterministic GraphQL fixtures.
    private func modelSnapshot(
        isDraft: Bool = false,
        reviewDecision: PullRequestReviewDecision = .reviewRequired,
        mergeState: PullRequestMergeState = .blocked,
        checks: [PullRequestCheck] = [],
        withThread: Bool = false
    ) -> PullRequestReviewSnapshot {
        let threadComments = [PullRequestReviewThreadComment(
            id: "R1",
            authorLogin: "reviewer",
            body: "Thread comment R1",
            createdAt: capturedAt,
            updatedAt: capturedAt,
            url: URL(string: "https://github.com/apps3k-com/CodingBuddy/pull/109#discussion_r1")!
        )]
        let threads = withThread ? [PullRequestReviewThread(
            id: "T1",
            isResolved: false,
            isOutdated: false,
            path: "CodingBuddy/App.swift",
            line: 10,
            originalLine: 10,
            comments: threadComments
        )] : []
        return PullRequestReviewSnapshot(
            target: target,
            pullRequestID: "PR1",
            title: "Review Desk",
            url: URL(string: "https://github.com/apps3k-com/CodingBuddy/pull/109")!,
            headOID: "head-oid",
            baseOID: "base-oid",
            headRefName: "bvk/pr-review-desk-109",
            baseRefName: "main",
            isDraft: isDraft,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            approvals: [],
            conversationComments: [],
            reviewThreads: threads,
            coverage: .complete,
            capturedAt: capturedAt
        )
    }

    /// Builds a complete minimal read sequence with no comments, approvals, or threads.
    private static func minimalReadResponses(
        title: String = "Review Desk",
        headOID: String = "head-oid",
        viewerID: String = "viewer-1",
        isDraft: Bool = false,
        reviewDecision: String? = "REVIEW_REQUIRED",
        mergeState: String = "BLOCKED",
        checks: String = noCheckPage,
        mergePolicyJSON: String? = nil,
        squashMergeAllowed: Bool = true,
        finalBase: String? = nil,
        includeFinalBase: Bool = true
    ) -> [ReviewDeskRecordingTransport.Response] {
        var responses: [ReviewDeskRecordingTransport.Response] = [
            .ok(baseResponse(
                title: title,
                headOID: headOID,
                viewerID: viewerID,
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                mergeState: mergeState,
                mergePolicyJSON: mergePolicyJSON,
                squashMergeAllowed: squashMergeAllowed
            )),
            .ok(conversationPage(ids: [], total: 0)),
            .ok(approvalPage(ids: [], total: 0)),
            .ok(threadPage(ids: [], total: 0)),
            .ok(checks),
        ]
        if includeFinalBase {
            responses.append(.ok(finalBase ?? baseResponse(
                title: title,
                headOID: headOID,
                viewerID: viewerID,
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                mergeState: mergeState,
                mergePolicyJSON: mergePolicyJSON,
                squashMergeAllowed: squashMergeAllowed
            )))
        }
        return responses
    }

    /// Builds a complete read sequence containing one unresolved review thread.
    private static func threadReadResponses() -> [ReviewDeskRecordingTransport.Response] {
        [
            .ok(baseResponse()),
            .ok(conversationPage(ids: [], total: 0)),
            .ok(approvalPage(ids: [], total: 0)),
            .ok(threadPage(ids: ["T1"], total: 1)),
            .ok(threadCommentPage(ids: ["R1"], total: 1)),
            .ok(noCheckPage),
            .ok(baseResponse()),
        ]
    }

    /// Builds pull request base metadata returned at both ends of a snapshot read.
    private static func baseResponse(
        title: String = "Review Desk",
        headOID: String = "head-oid",
        viewerID: String = "viewer-1",
        isDraft: Bool = false,
        reviewDecision: String? = "REVIEW_REQUIRED",
        mergeState: String = "BLOCKED",
        mergePolicyJSON: String? = nil,
        squashMergeAllowed: Bool = true
    ) -> String {
        let decision = reviewDecision.map { "\"\($0)\"" } ?? "null"
        let baseRef = mergePolicyJSON.map {
            #","baseRef":{"branchProtectionRule":\#($0)}"#
        } ?? #","baseRef":{"branchProtectionRule":null}"#
        return """
        {"data":{"viewer":{"id":"\(viewerID)"},"repository":{
          "mergeCommitAllowed":true,"squashMergeAllowed":\(squashMergeAllowed),"rebaseMergeAllowed":true,
          "pullRequest":{
          "id":"PR1","title":"\(title)",
          "url":"https://github.com/apps3k-com/CodingBuddy/pull/109",
          "updatedAt":"2026-07-17T10:00:00Z","isDraft":\(isDraft),
          "reviewDecision":\(decision),"mergeStateStatus":"\(mergeState)",
          "headRefOid":"\(headOID)","baseRefOid":"base-oid",
          "headRefName":"bvk/pr-review-desk-109","baseRefName":"main"\(baseRef)
        }}}}
        """
    }

    /// Strict classic branch-protection fixture with no pull request bypass actors.
    private static let strictMergePolicyJSON = """
    {"requiresApprovingReviews":true,"requiredApprovingReviewCount":1,
     "requiresStatusChecks":true,"requiresStrictStatusChecks":true,
     "requiresConversationResolution":true,"isAdminEnforced":true,
     "bypassPullRequestAllowances":{"totalCount":0}}
    """

    /// Otherwise strict branch-protection fixture containing one bypass actor.
    private static let bypassMergePolicyJSON = """
    {"requiresApprovingReviews":true,"requiredApprovingReviewCount":1,
     "requiresStatusChecks":true,"requiresStrictStatusChecks":true,
     "requiresConversationResolution":true,"isAdminEnforced":true,
     "bypassPullRequestAllowances":{"totalCount":1}}
    """

    /// Builds one top-level conversation-comment page.
    private static func conversationPage(ids: [String], total: Int, next: String? = nil) -> String {
        connectionPage(field: "comments", nodes: ids.map { id in
            """
            {"id":"\(id)","author":{"login":"author"},"body":"Comment \(id)",
             "createdAt":"2026-07-17T10:00:00Z","updatedAt":"2026-07-17T10:00:00Z",
             "url":"https://github.com/apps3k-com/CodingBuddy/pull/109#issuecomment-\(id)"}
            """
        }, total: total, next: next)
    }

    /// Builds one approval-review page.
    private static func approvalPage(ids: [String], total: Int, next: String? = nil) -> String {
        connectionPage(field: "reviews", nodes: ids.map { id in
            """
            {"id":"\(id)","author":{"login":"reviewer"},
             "submittedAt":"2026-07-17T10:00:00Z",
             "url":"https://github.com/apps3k-com/CodingBuddy/pull/109#pullrequestreview-\(id)"}
            """
        }, total: total, next: next)
    }

    /// Builds one review-thread metadata page.
    private static func threadPage(ids: [String], total: Int, next: String? = nil) -> String {
        connectionPage(field: "reviewThreads", nodes: ids.map { id in
            """
            {"id":"\(id)","isResolved":false,"isOutdated":false,
             "path":"CodingBuddy/App.swift","line":10,"originalLine":10}
            """
        }, total: total, next: next)
    }

    /// Builds one nested review-thread comment page.
    private static func threadCommentPage(ids: [String], total: Int, next: String? = nil) -> String {
        connectionPage(field: "comments", nodes: ids.map { id in
            """
            {"id":"\(id)","author":{"login":"reviewer"},"body":"Thread comment \(id)",
             "createdAt":"2026-07-17T10:00:00Z","updatedAt":"2026-07-17T10:00:00Z",
             "url":"https://github.com/apps3k-com/CodingBuddy/pull/109#discussion_\(id.lowercased())"}
            """
        }, total: total, next: next)
    }

    /// Builds one polymorphic status-check page.
    private static func checkPage(
        ids: [String],
        total: Int,
        next: String? = nil,
        statusContext: Bool = false,
        conclusion: String = "SUCCESS"
    ) -> String {
        let nodes = ids.map { id in
            if statusContext {
                return """
                {"__typename":"StatusContext","id":"\(id)","context":"legacy",
                 "state":"SUCCESS","targetUrl":null,"isRequired":false}
                """
            }
            return """
            {"__typename":"CheckRun","id":"\(id)","name":"build","status":"COMPLETED",
             "conclusion":"\(conclusion)","detailsUrl":null,"isRequired":true}
            """
        }
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"data":{"node":{"statusCheckRollup":{"contexts":{
          "totalCount":\(total),"pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)},
          "nodes":[\(nodes.joined(separator: ","))]
        }}}}}
        """
    }

    /// GraphQL response representing a head with no check or status rollup.
    private static let noCheckPage = #"{"data":{"node":{"statusCheckRollup":null}}}"#

    /// Builds a node connection response shared by comment, approval, and thread fixtures.
    private static func connectionPage(
        field: String,
        nodes: [String],
        total: Int,
        next: String?
    ) -> String {
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"data":{"node":{"\(field)":{
          "totalCount":\(total),"pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)},
          "nodes":[\(nodes.joined(separator: ","))]
        }}}}
        """
    }
}

/// Deterministic FIFO transport that records every Review Desk request.
private final class ReviewDeskRecordingTransport: GitHubTransport, @unchecked Sendable {
    /// One queued transport outcome.
    enum Response {
        /// Successful HTTP response with a UTF-8 JSON body.
        case ok(String)
        /// Transport-level failure.
        case failure(Error)
    }

    /// Queued outcomes.
    private var responses: [Response]
    /// Requests observed by the fake.
    private var recordedRequests: [URLRequest] = []
    /// Lock protecting mutable fake state.
    private let lock = NSLock()

    /// Creates a fake with deterministic FIFO outcomes.
    init(responses: [Response]) {
        self.responses = responses
    }

    /// Thread-safe snapshot of all recorded requests.
    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// Records a request and returns the next queued outcome exactly once.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = lock.withLock { () -> Response in
            recordedRequests.append(request)
            guard !responses.isEmpty else { return .failure(URLError(.cancelled)) }
            return responses.removeFirst()
        }
        switch response {
        case .ok(let body):
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), http)
        case .failure(let error):
            throw error
        }
    }

    /// Decodes the variables object for one recorded GraphQL request.
    func variables(at index: Int) throws -> [String: Any] {
        let request = requests[index]
        let data = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["variables"] as? [String: Any])
    }
}
