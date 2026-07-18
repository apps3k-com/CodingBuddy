//
//  PullRequestReviewDesk.swift
//  CodingBuddy
//

import CryptoKit
import Foundation

/// A repository pull request addressed by the Review Desk.
nonisolated struct PullRequestReviewTarget: Codable, Equatable, Hashable, Sendable {
    /// Repository containing the pull request.
    let repository: GitHubRepositoryRef
    /// Repository-local pull request number.
    let number: Int

    /// Creates a validated Review Desk target.
    init(repository: GitHubRepositoryRef, number: Int) {
        self.repository = repository
        self.number = number
    }
}

/// Review decision normalized from GitHub's nullable GraphQL enum.
nonisolated enum PullRequestReviewDecision: String, Codable, Equatable, Sendable {
    /// GitHub reports that required approvals are satisfied.
    case approved
    /// A reviewer requested changes.
    case changesRequested
    /// GitHub reports that a review is still required.
    case reviewRequired
    /// The repository has no applicable review decision.
    case none
    /// GitHub returned an enum value CodingBuddy does not understand.
    case unknown
}

/// Merge-state status normalized from GitHub GraphQL.
nonisolated enum PullRequestMergeState: String, Codable, Equatable, Sendable {
    /// The head branch is behind the base branch.
    case behind
    /// Repository rules or another known condition blocks merging.
    case blocked
    /// GitHub currently considers the pull request mergeable.
    case clean
    /// Merge conflicts prevent merging.
    case dirty
    /// A pre-receive hook applies to the merge.
    case hasHooks
    /// Required checks have not all succeeded.
    case unstable
    /// GitHub returned an enum value CodingBuddy does not understand.
    case unknown
}

/// Normalized state of a check run or legacy status context.
nonisolated enum PullRequestCheckState: String, Codable, Equatable, Hashable, Sendable {
    /// The provider has not finished the check.
    case pending
    /// The provider completed successfully.
    case success
    /// The provider completed unsuccessfully.
    case failure
    /// The provider completed neutrally.
    case neutral
    /// The provider skipped the check.
    case skipped
    /// The provider cancelled the check.
    case cancelled
    /// The provider timed out.
    case timedOut
    /// The provider requires a user action.
    case actionRequired
    /// GitHub marked the completed result stale relative to its source.
    case stale
    /// GitHub returned a state CodingBuddy does not understand.
    case unknown

    /// Whether this state is conclusively successful for a required-check gate.
    var satisfiesRequirement: Bool { self == .success }
}

/// One check run or legacy status context attached to the current head commit.
nonisolated struct PullRequestCheck: Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL identity or canonical legacy-status identity.
    let id: String
    /// Human-readable check or status-context name.
    let name: String
    /// Normalized provider state.
    let state: PullRequestCheckState
    /// Whether GitHub marks this context as required for this pull request.
    let isRequired: Bool
    /// Provider details page when available.
    let detailsURL: URL?
}

/// One submitted approval review.
nonisolated struct PullRequestApproval: Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL review identity.
    let id: String
    /// Reviewer login when GitHub exposes it.
    let authorLogin: String?
    /// Submission timestamp when available.
    let submittedAt: Date?
    /// Browser URL for the review when available.
    let url: URL?
}

/// One top-level pull request conversation comment.
nonisolated struct PullRequestConversationComment: Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL comment identity.
    let id: String
    /// Comment author login when GitHub exposes it.
    let authorLogin: String?
    /// Markdown comment body.
    let body: String
    /// Creation timestamp.
    let createdAt: Date
    /// Last update timestamp.
    let updatedAt: Date
    /// Browser URL for the comment.
    let url: URL
}

/// One comment or reply in an inline review thread.
nonisolated struct PullRequestReviewThreadComment: Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL review-comment identity.
    let id: String
    /// Comment author login when GitHub exposes it.
    let authorLogin: String?
    /// Markdown comment body.
    let body: String
    /// Creation timestamp.
    let createdAt: Date
    /// Last update timestamp.
    let updatedAt: Date
    /// Browser URL for the comment.
    let url: URL
}

/// One fully loaded inline review thread and all of its replies.
nonisolated struct PullRequestReviewThread: Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL thread identity used by reply and resolve mutations.
    let id: String
    /// Whether GitHub reports the thread as resolved.
    let isResolved: Bool
    /// Whether the reviewed diff location is outdated.
    let isOutdated: Bool
    /// Repository-relative path when available.
    let path: String?
    /// Current diff line when available.
    let line: Int?
    /// Original diff line when available.
    let originalLine: Int?
    /// Every comment in the thread in GitHub order.
    let comments: [PullRequestReviewThreadComment]
}

/// Coverage state carried by a snapshot to prevent partial data from authorizing writes.
nonisolated enum PullRequestReviewSnapshotCoverage: String, Codable, Equatable, Sendable {
    /// Every required connection and nested connection was loaded without ambiguity.
    case complete
    /// At least one required connection was not proven complete.
    case incomplete
}

/// Server-side branch policy that must atomically enforce every Review Desk merge gate.
nonisolated struct PullRequestMergePolicy: Codable, Equatable, Sendable {
    /// Whether GitHub requires approving reviews before merge.
    let requiresApprovingReviews: Bool?
    /// Minimum number of approving reviews required by GitHub.
    let requiredApprovingReviewCount: Int?
    /// Whether GitHub requires configured status checks before merge.
    let requiresStatusChecks: Bool?
    /// Whether GitHub requires the head to remain current with the protected base.
    let requiresStrictStatusChecks: Bool?
    /// Whether GitHub requires every review conversation to be resolved.
    let requiresConversationResolution: Bool?
    /// Whether repository administrators are subject to the same rule.
    let isAdminEnforced: Bool?
    /// Number of actors allowed to bypass pull request requirements.
    let bypassAllowanceCount: Int?

    /// Fail-closed policy used when no complete classic branch-protection proof is available.
    static let unverified = PullRequestMergePolicy(
        requiresApprovingReviews: nil,
        requiredApprovingReviewCount: nil,
        requiresStatusChecks: nil,
        requiresStrictStatusChecks: nil,
        requiresConversationResolution: nil,
        isAdminEnforced: nil,
        bypassAllowanceCount: nil
    )

    /// Whether GitHub itself will reject a merge when any Review Desk gate drifts.
    var enforcesReviewDeskGates: Bool {
        requiresApprovingReviews == true
            && (requiredApprovingReviewCount ?? 0) > 0
            && requiresStatusChecks == true
            && requiresStrictStatusChecks == true
            && requiresConversationResolution == true
            && isAdminEnforced == true
            && bypassAllowanceCount == 0
    }
}

/// Repository-level merge methods that GitHub currently permits.
nonisolated struct PullRequestMergeMethods: Codable, Equatable, Sendable {
    /// Whether GitHub accepts a merge commit for this repository.
    let mergeCommitAllowed: Bool?
    /// Whether GitHub accepts a squash merge for this repository.
    let squashMergeAllowed: Bool?
    /// Whether GitHub accepts a rebase merge for this repository.
    let rebaseMergeAllowed: Bool?

    /// Fail-closed value used when repository method settings were not proven.
    static let unverified = PullRequestMergeMethods(
        mergeCommitAllowed: nil,
        squashMergeAllowed: nil,
        rebaseMergeAllowed: nil
    )

    /// Methods that can be offered without relying on a rejected mutation for validation.
    var available: [PullRequestMergeMethod] {
        PullRequestMergeMethod.allCases.filter(allows)
    }

    /// Whether the exact method is enabled by the repository.
    func allows(_ method: PullRequestMergeMethod) -> Bool {
        switch method {
        case .merge: mergeCommitAllowed == true
        case .squash: squashMergeAllowed == true
        case .rebase: rebaseMergeAllowed == true
        }
    }
}

/// Fully paginated, internally consistent pull request state used by the Review Desk.
nonisolated struct PullRequestReviewSnapshot: Codable, Equatable, Sendable {
    /// Address used to load the pull request.
    let target: PullRequestReviewTarget
    /// Stable GraphQL pull request identity.
    let pullRequestID: String
    /// Stable GitHub viewer identity that loaded this snapshot.
    let principalID: String
    /// Pull request title.
    let title: String
    /// Browser URL for the pull request.
    let url: URL
    /// Current head commit object ID.
    let headOID: String
    /// Current base commit object ID.
    let baseOID: String
    /// Head branch name.
    let headRefName: String
    /// Base branch name.
    let baseRefName: String
    /// Whether the pull request is still a draft.
    let isDraft: Bool
    /// Whether GitHub reports that the pull request has been merged.
    let isMerged: Bool
    /// Current review decision.
    let reviewDecision: PullRequestReviewDecision
    /// Current merge-state status.
    let mergeState: PullRequestMergeState
    /// Every check run and legacy status context for the current head.
    let checks: [PullRequestCheck]
    /// Every submitted approval review returned by the fully paginated review connection.
    let approvals: [PullRequestApproval]
    /// Every top-level conversation comment.
    let conversationComments: [PullRequestConversationComment]
    /// Every inline review thread with all replies.
    let reviewThreads: [PullRequestReviewThread]
    /// Server-side rule that must atomically enforce approval, checks, and conversations.
    let mergePolicy: PullRequestMergePolicy
    /// Repository-level merge methods proven by the same consistent base read.
    let mergeMethods: PullRequestMergeMethods
    /// Proof that every required connection was loaded completely.
    let coverage: PullRequestReviewSnapshotCoverage
    /// Time at which the final consistency read completed.
    let capturedAt: Date
    /// SHA-256 digest binding all mutation-relevant state.
    let digest: String

    /// Creates a snapshot and computes its bound state digest.
    init(
        target: PullRequestReviewTarget,
        pullRequestID: String,
        title: String,
        url: URL,
        headOID: String,
        baseOID: String,
        headRefName: String,
        baseRefName: String,
        isDraft: Bool,
        isMerged: Bool = false,
        reviewDecision: PullRequestReviewDecision,
        mergeState: PullRequestMergeState,
        checks: [PullRequestCheck],
        approvals: [PullRequestApproval],
        conversationComments: [PullRequestConversationComment],
        reviewThreads: [PullRequestReviewThread],
        mergePolicy: PullRequestMergePolicy = .unverified,
        mergeMethods: PullRequestMergeMethods = .unverified,
        coverage: PullRequestReviewSnapshotCoverage,
        principalID: String = "test-principal",
        capturedAt: Date
    ) {
        self.target = target
        self.pullRequestID = pullRequestID
        self.principalID = principalID
        self.title = title
        self.url = url
        self.headOID = headOID
        self.baseOID = baseOID
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.reviewDecision = reviewDecision
        self.mergeState = mergeState
        self.checks = checks
        self.approvals = approvals
        self.conversationComments = conversationComments
        self.reviewThreads = reviewThreads
        self.mergePolicy = mergePolicy
        self.mergeMethods = mergeMethods
        self.coverage = coverage
        self.capturedAt = capturedAt
        digest = Self.makeDigest(
            target: target,
            pullRequestID: pullRequestID,
            principalID: principalID,
            title: title,
            url: url,
            headOID: headOID,
            baseOID: baseOID,
            headRefName: headRefName,
            baseRefName: baseRefName,
            isDraft: isDraft,
            isMerged: isMerged,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            approvals: approvals,
            conversationComments: conversationComments,
            reviewThreads: reviewThreads,
            mergePolicy: mergePolicy,
            mergeMethods: mergeMethods,
            coverage: coverage
        )
    }

    /// Checks marked required by GitHub.
    var requiredChecks: [PullRequestCheck] { checks.filter(\.isRequired) }

    /// Threads that remain unresolved, including outdated locations.
    var unresolvedThreads: [PullRequestReviewThread] { reviewThreads.filter { !$0.isResolved } }

    /// Whether this snapshot can safely pass the client's conservative merge gate.
    var isMergeEligible: Bool {
        coverage == .complete
            && !isMerged
            && !isDraft
            && reviewDecision == .approved
            && mergeState == .clean
            && unresolvedThreads.isEmpty
            && mergePolicy.enforcesReviewDeskGates
            && requiredChecks.allSatisfy(\.state.satisfiesRequirement)
            && checks.allSatisfy { $0.state != .unknown }
    }

    /// Computes a deterministic SHA-256 digest over mutation-relevant state.
    private static func makeDigest(
        target: PullRequestReviewTarget,
        pullRequestID: String,
        principalID: String,
        title: String,
        url: URL,
        headOID: String,
        baseOID: String,
        headRefName: String,
        baseRefName: String,
        isDraft: Bool,
        isMerged: Bool,
        reviewDecision: PullRequestReviewDecision,
        mergeState: PullRequestMergeState,
        checks: [PullRequestCheck],
        approvals: [PullRequestApproval],
        conversationComments: [PullRequestConversationComment],
        reviewThreads: [PullRequestReviewThread],
        mergePolicy: PullRequestMergePolicy,
        mergeMethods: PullRequestMergeMethods,
        coverage: PullRequestReviewSnapshotCoverage
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = DigestPayload(
            target: target,
            pullRequestID: pullRequestID,
            principalID: principalID,
            title: title,
            url: url,
            headOID: headOID,
            baseOID: baseOID,
            headRefName: headRefName,
            baseRefName: baseRefName,
            isDraft: isDraft,
            isMerged: isMerged,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            approvals: approvals,
            conversationComments: conversationComments,
            reviewThreads: reviewThreads,
            mergePolicy: mergePolicy,
            mergeMethods: mergeMethods,
            coverage: coverage
        )
        guard let data = try? encoder.encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Immutable preflight proof required by every Review Desk mutation.
nonisolated enum PullRequestMutationIntent: Codable, Equatable, Sendable {
    /// Reply to one exact review thread with one exact body.
    case reply(threadID: String, bodyDigest: String)
    /// Resolve one exact review thread.
    case resolve(threadID: String)
    /// Transition the pull request out of draft state.
    case markReady
    /// Merge with one exact GitHub merge strategy.
    case merge(method: PullRequestMergeMethod)

    /// Creates an intent that binds the exact reply body without retaining cleartext.
    static func reply(threadID: String, body: String) -> PullRequestMutationIntent {
        let digest = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return .reply(threadID: threadID, bodyDigest: digest)
    }
}

/// Immutable preflight proof required by every Review Desk mutation.
nonisolated struct PullRequestMutationPreflight: Codable, Equatable, Sendable {
    /// Unpredictable one-use identity registered by the issuing client.
    let nonce: String
    /// Exact mutation and scoped parameters authorized by this preflight.
    let intent: PullRequestMutationIntent
    /// Pull request identity bound by the preflight.
    let target: PullRequestReviewTarget
    /// GraphQL node identity bound by the preflight.
    let pullRequestID: String
    /// GitHub principal that performed the consistency read.
    let principalID: String
    /// Full snapshot digest that a fresh read must reproduce.
    let snapshotDigest: String
    /// Head OID that merge requests also send to GitHub.
    let expectedHeadOID: String
    /// Time of the consistency read that created the proof.
    let capturedAt: Date

    /// Creates a preflight only from a complete, digestible snapshot.
    init(
        snapshot: PullRequestReviewSnapshot,
        intent: PullRequestMutationIntent,
        nonce: String
    ) throws {
        guard snapshot.coverage == .complete,
              !snapshot.pullRequestID.isEmpty,
              !snapshot.principalID.isEmpty,
              !snapshot.headOID.isEmpty,
              !snapshot.digest.isEmpty,
              !nonce.isEmpty else {
            throw GitHubPullRequestReviewError.incompleteSnapshot
        }
        self.nonce = nonce
        self.intent = intent
        target = snapshot.target
        pullRequestID = snapshot.pullRequestID
        principalID = snapshot.principalID
        snapshotDigest = snapshot.digest
        expectedHeadOID = snapshot.headOID
        capturedAt = snapshot.capturedAt
    }
}

/// Merge strategy exposed by GitHub's pull request mutation.
nonisolated enum PullRequestMergeMethod: String, CaseIterable, Codable, Equatable, Sendable {
    /// Create a merge commit.
    case merge = "MERGE"
    /// Squash pull request commits into one commit.
    case squash = "SQUASH"
    /// Rebase pull request commits onto the base branch.
    case rebase = "REBASE"
}

/// Receipt returned after GitHub accepts a Review Desk mutation.
nonisolated struct PullRequestMutationReceipt: Codable, Equatable, Sendable {
    /// GraphQL identity of the mutated resource.
    let resourceID: String
    /// Client-provided idempotency correlation value returned by GitHub when available.
    let clientMutationID: String?
}

/// Typed, token-safe failures produced by the Review Desk client.
nonisolated enum GitHubPullRequestReviewError: Error, Equatable, Sendable {
    /// The supplied token is empty.
    case noToken
    /// The target owner, repository, or pull request number is invalid.
    case invalidTarget
    /// GitHub rejected the credential.
    case authenticationFailed
    /// The credential lacks a required permission.
    case missingPermission
    /// The target pull request is unavailable to the credential.
    case pullRequestUnavailable
    /// GitHub rate-limited the request.
    case rateLimited
    /// GitHub returned an unexpected HTTP status.
    case server(statusCode: Int)
    /// The network request failed before a read completed.
    case networkUnavailable
    /// GitHub returned malformed or structurally incomplete data.
    case invalidResponse
    /// GitHub returned an enum or check state CodingBuddy does not understand.
    case unknownState
    /// A cursor repeated, disappeared, or exceeded the configured page limit.
    case incompletePagination
    /// A stable GraphQL identity appeared more than once.
    case duplicateIdentifier(String)
    /// The snapshot was not proven complete.
    case incompleteSnapshot
    /// Aggregate request, node, or byte work exceeded the snapshot-wide budget.
    case snapshotBudgetExceeded
    /// The pull request changed while a snapshot or mutation preflight was being evaluated.
    case driftDetected
    /// The supplied credential capability is read-only.
    case writesNotAllowed
    /// Mutation input is invalid for the current snapshot.
    case invalidMutation
    /// A merge was requested while conservative readiness gates were not satisfied.
    case mergeNotReady
    /// A write may have reached GitHub, so automatic retry is unsafe.
    case ambiguousWrite
    /// GitHub returned a mutation payload that did not identify the expected resource.
    case mutationRejected
}

/// Codable digest payload excluding capture time and the digest itself.
private nonisolated struct DigestPayload: Codable {
    /// Pull request address.
    let target: PullRequestReviewTarget
    /// Pull request GraphQL identity.
    let pullRequestID: String
    /// GitHub viewer identity used for the snapshot.
    let principalID: String
    /// Pull request title.
    let title: String
    /// Pull request browser URL.
    let url: URL
    /// Head commit OID.
    let headOID: String
    /// Base commit OID.
    let baseOID: String
    /// Head branch name.
    let headRefName: String
    /// Base branch name.
    let baseRefName: String
    /// Draft state.
    let isDraft: Bool
    /// Merged state.
    let isMerged: Bool
    /// Review decision.
    let reviewDecision: PullRequestReviewDecision
    /// Merge state.
    let mergeState: PullRequestMergeState
    /// All checks.
    let checks: [PullRequestCheck]
    /// All approvals.
    let approvals: [PullRequestApproval]
    /// All conversation comments.
    let conversationComments: [PullRequestConversationComment]
    /// All review threads and replies.
    let reviewThreads: [PullRequestReviewThread]
    /// Server-side merge enforcement proof.
    let mergePolicy: PullRequestMergePolicy
    /// Repository-level allowed merge methods.
    let mergeMethods: PullRequestMergeMethods
    /// Snapshot coverage proof.
    let coverage: PullRequestReviewSnapshotCoverage
}
