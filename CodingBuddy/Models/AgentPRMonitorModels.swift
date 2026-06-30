//
//  AgentPRMonitorModels.swift
//  CodingBuddy
//

import Foundation

/// GitHub repository identity monitored by the Agent PR Monitor.
nonisolated struct GitHubRepositoryRef: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Repository owner or organization login.
    let owner: String
    /// Repository name without the owner prefix.
    let name: String

    /// Stable identifier used for persistence and table filtering.
    var id: String { "\(owner)/\(name)" }

    /// Human-readable `owner/name` repository label.
    var displayName: String { id }

    /// Creates a normalized GitHub repository reference.
    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses an `owner/name` string into a repository reference.
    init?(displayName: String) {
        let parts = displayName.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        self.owner = String(parts[0])
        self.name = String(parts[1])
    }
}

/// Repository entry returned by the authenticated GitHub repository picker.
nonisolated struct GitHubRepositorySummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable repository identity used by monitor fetches and persistence.
    let ref: GitHubRepositoryRef
    /// GitHub repository description when one is visible.
    let description: String?
    /// Whether the repository is private.
    let isPrivate: Bool
    /// Whether the repository is archived on GitHub.
    let isArchived: Bool
    /// Last pushed timestamp when GitHub exposed it.
    let pushedAt: Date?

    /// Stable identifier matching the underlying `owner/name` reference.
    var id: String { ref.id }

    /// Human-readable `owner/name` repository label.
    var displayName: String { ref.displayName }

    /// Owner login used for search and display.
    var owner: String { ref.owner }

    /// Repository name used for search and display.
    var name: String { ref.name }

    /// True when the repository should remain visible for a picker search.
    func matches(searchText: String) -> Bool {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else { return true }
        return owner.localizedCaseInsensitiveContains(normalizedSearch)
            || name.localizedCaseInsensitiveContains(normalizedSearch)
            || displayName.localizedCaseInsensitiveContains(normalizedSearch)
            || (description?.localizedCaseInsensitiveContains(normalizedSearch) == true)
    }
}

/// Page-capped repository list returned to the Agent PR Monitor picker.
nonisolated struct GitHubRepositoryList: Equatable, Sendable {
    /// Repositories visible to the current token.
    let repositories: [GitHubRepositorySummary]
    /// Latest rate-limit metadata returned by GitHub.
    let rateLimit: GitHubRateLimitState?
    /// Whether the configured pagination cap stopped before GitHub's final page.
    let isTruncated: Bool
}

/// Best-effort source classification for a pull request.
nonisolated enum AgentPRAuthorSource: String, CaseIterable, Sendable {
    /// Signals indicate the PR was likely created by a coding agent.
    case likelyAgent
    /// Signals indicate a human-authored PR.
    case likelyHuman
    /// No confident source classification could be derived.
    case unknown

    /// Localized display label for source classification.
    var displayName: String {
        switch self {
        case .likelyAgent:
            String(localized: "Likely agent")
        case .likelyHuman:
            String(localized: "Likely human")
        case .unknown:
            String(localized: "Unknown")
        }
    }
}

/// GitHub issue state shown for linked closing issues.
nonisolated enum AgentPRLinkedIssueState: String, Sendable {
    /// The linked issue is still open.
    case open
    /// The linked issue has been closed.
    case closed
    /// GitHub did not expose a known issue state.
    case unknown

    /// Localized display label for linked issue state.
    var displayName: String {
        switch self {
        case .open:
            String(localized: "Open")
        case .closed:
            String(localized: "Closed")
        case .unknown:
            String(localized: "Unknown")
        }
    }
}

/// Issue referenced by a pull request closing keyword.
nonisolated struct AgentPRLinkedIssue: Identifiable, Equatable, Hashable, Sendable {
    /// GitHub issue number.
    let number: Int
    /// Issue title returned by GitHub.
    let title: String
    /// Browser URL for issue follow-up.
    let url: URL
    /// Current issue state if visible to the token.
    let state: AgentPRLinkedIssueState

    /// Stable issue identity.
    var id: Int { number }
}

/// Normalized state for one check run or legacy commit status context.
nonisolated enum AgentPRStatusState: String, Sendable {
    /// GitHub has queued the check but not completed it.
    case queued
    /// The check is currently running.
    case inProgress
    /// Legacy commit status is pending.
    case pending
    /// The check completed successfully.
    case success
    /// The check completed neutrally and should not block readiness.
    case neutral
    /// The check was skipped and should not block readiness.
    case skipped
    /// The check failed.
    case failure
    /// The check was cancelled.
    case cancelled
    /// The check timed out.
    case timedOut
    /// The check requires an external action.
    case actionRequired
    /// GitHub returned an unknown status or conclusion.
    case unknown

    /// True when the state means work is still in progress.
    var isWaiting: Bool {
        switch self {
        case .queued, .inProgress, .pending:
            true
        default:
            false
        }
    }

    /// True when the state represents a failure or blocker.
    var isFailure: Bool {
        switch self {
        case .failure, .cancelled, .timedOut, .actionRequired, .unknown:
            true
        default:
            false
        }
    }

    /// True when the state should be treated as green for advisory readiness.
    var isSuccess: Bool {
        switch self {
        case .success, .neutral, .skipped:
            true
        default:
            false
        }
    }
}

/// One check-run or legacy status context attached to a PR head SHA.
nonisolated struct AgentPRStatusContext: Identifiable, Equatable, Hashable, Sendable {
    /// Stable context name as shown by GitHub.
    let name: String
    /// Normalized status state.
    let state: AgentPRStatusState
    /// Browser URL for the provider details page, if GitHub exposed one.
    let detailsURL: URL?

    /// Stable identity used by SwiftUI.
    var id: String { name }
}

/// High-level CI/check state for one pull request.
nonisolated enum AgentPRCheckState: String, Sendable {
    /// All visible checks are green or neutral.
    case green
    /// At least one visible check is still pending.
    case waiting
    /// At least one visible check has failed or requires action.
    case failed
    /// No check state was visible.
    case unknown

    /// Localized display label for table cells.
    var displayName: String {
        switch self {
        case .green:
            String(localized: "CI green")
        case .waiting:
            String(localized: "CI pending")
        case .failed:
            String(localized: "CI failed")
        case .unknown:
            String(localized: "CI unknown")
        }
    }
}

/// Aggregated CI/check summary for one pull request.
nonisolated struct AgentPRCheckSummary: Equatable, Hashable, Sendable {
    /// Normalized check contexts in display order.
    let contexts: [AgentPRStatusContext]
    /// Whether GitHub indicated there are more contexts than v1 fetched.
    let isTruncated: Bool

    /// Derived high-level CI state.
    var state: AgentPRCheckState {
        guard !contexts.isEmpty else { return .unknown }
        if contexts.contains(where: { $0.state.isFailure }) { return .failed }
        if contexts.contains(where: { $0.state.isWaiting }) { return .waiting }
        if isTruncated { return .unknown }
        if contexts.allSatisfy({ $0.state.isSuccess }) { return .green }
        return .unknown
    }

    /// Context names that currently block readiness.
    var failingContextNames: [String] {
        contexts.filter { $0.state.isFailure }.map(\.name)
    }

    /// Creates an aggregated check summary from normalized contexts.
    init(contexts: [AgentPRStatusContext], isTruncated: Bool = false) {
        self.contexts = contexts
        self.isTruncated = isTruncated
    }
}

/// Review decision returned by GitHub GraphQL for a pull request.
nonisolated enum AgentPRReviewDecision: String, Sendable {
    /// GitHub reports an approving review decision.
    case approved
    /// GitHub reports requested changes.
    case changesRequested
    /// GitHub requires review before merge.
    case reviewRequired
    /// Review decision is unavailable or not required.
    case none
    /// GitHub returned an unknown review decision.
    case unknown
}

/// Latest review state for a single review event.
nonisolated enum AgentPRReviewState: String, Sendable {
    /// The review approved the PR.
    case approved
    /// The review requested changes.
    case changesRequested
    /// The review left a non-approval comment.
    case commented
    /// The review was dismissed.
    case dismissed
    /// GitHub returned an unknown review state.
    case unknown
}

/// One latest review entry used to derive advisory review status.
nonisolated struct AgentPRReview: Equatable, Hashable, Sendable {
    /// Reviewer login if visible to the token.
    let authorLogin: String?
    /// Normalized review state.
    let state: AgentPRReviewState
    /// Submission timestamp when visible.
    let submittedAt: Date?
    /// Browser URL for the review, if available.
    let url: URL?
}

/// One pull-request review thread used to count unresolved findings.
nonisolated struct AgentPRReviewThread: Equatable, Hashable, Sendable {
    /// Repository path of the thread.
    let path: String?
    /// Line number when GitHub exposes one.
    let line: Int?
    /// Whether the thread has been resolved.
    let isResolved: Bool
    /// Whether the thread belongs to outdated diff context.
    let isOutdated: Bool
    /// Browser URL for the first thread comment, if available.
    let url: URL?

    /// True when the thread is current and still needs attention.
    var isUnresolvedFinding: Bool {
        !isResolved && !isOutdated
    }
}

/// Provider-agnostic review finding state for one pull request.
nonisolated enum AgentPRFindingsState: Equatable, Hashable, Sendable {
    /// No unresolved current review findings are visible.
    case none
    /// One or more current review threads are unresolved.
    case unresolvedFindings(count: Int)
    /// A reviewer formally requested changes.
    case changesRequested
    /// Review is still pending or formally required.
    case reviewPending

    /// Localized display label for review findings.
    var displayName: String {
        switch self {
        case .none:
            String(localized: "No findings")
        case .unresolvedFindings(let count):
            String(format: String(localized: "%lld unresolved"), Int64(count))
        case .changesRequested:
            String(localized: "Changes requested")
        case .reviewPending:
            String(localized: "Review pending")
        }
    }
}

/// High-level review state shown in the PR monitor table.
nonisolated enum AgentPRReviewSummaryState: String, Sendable {
    /// Review is approved or not required.
    case approved
    /// Review is formally required.
    case reviewRequired
    /// Review requested changes.
    case changesRequested
    /// Review is pending or unavailable.
    case pending
    /// Review state could not be inferred.
    case unknown

    /// Localized display label for review state.
    var displayName: String {
        switch self {
        case .approved:
            String(localized: "Review approved")
        case .reviewRequired:
            String(localized: "Review required")
        case .changesRequested:
            String(localized: "Changes requested")
        case .pending:
            String(localized: "Review pending")
        case .unknown:
            String(localized: "Review unknown")
        }
    }
}

/// Aggregated review and finding summary for one pull request.
nonisolated struct AgentPRReviewSummary: Equatable, Hashable, Sendable {
    /// GitHub's review decision, normalized for app display.
    let decision: AgentPRReviewDecision
    /// Latest reviews returned by GitHub.
    let latestReviews: [AgentPRReview]
    /// Current and historical review threads returned by GitHub.
    let threads: [AgentPRReviewThread]
    /// Whether GitHub indicated there are more review threads than v1 fetched.
    let hasTruncatedThreads: Bool

    /// Derived high-level review state.
    var state: AgentPRReviewSummaryState {
        if latestReviews.contains(where: { $0.state == .changesRequested }) {
            return .changesRequested
        }
        switch decision {
        case .approved, .none:
            return .approved
        case .reviewRequired:
            return .reviewRequired
        case .changesRequested:
            return .changesRequested
        case .unknown:
            return .unknown
        }
    }

    /// Number of current, unresolved review findings.
    var unresolvedFindingCount: Int {
        threads.filter(\.isUnresolvedFinding).count
    }

    /// Derived provider-agnostic findings state.
    var findingsState: AgentPRFindingsState {
        if state == .changesRequested { return .changesRequested }
        if unresolvedFindingCount > 0 { return .unresolvedFindings(count: unresolvedFindingCount) }
        if hasTruncatedThreads { return .reviewPending }
        if state == .reviewRequired || state == .pending { return .reviewPending }
        return .none
    }

    /// Creates an aggregated review summary from normalized GitHub data.
    init(
        decision: AgentPRReviewDecision,
        latestReviews: [AgentPRReview],
        threads: [AgentPRReviewThread],
        hasTruncatedThreads: Bool = false
    ) {
        self.decision = decision
        self.latestReviews = latestReviews
        self.threads = threads
        self.hasTruncatedThreads = hasTruncatedThreads
    }
}

/// Advisory merge-readiness state for one pull request.
nonisolated enum AgentPRMergeReadinessState: String, Sendable {
    /// CI and review signals show no known blockers.
    case ready
    /// The PR is still waiting on CI or review.
    case waiting
    /// Review findings or failed checks need attention.
    case attentionNeeded
    /// Draft state or another hard blocker prevents readiness.
    case blocked

    /// Localized display label for readiness state.
    var displayName: String {
        switch self {
        case .ready:
            String(localized: "Ready")
        case .waiting:
            String(localized: "Waiting")
        case .attentionNeeded:
            String(localized: "Needs attention")
        case .blocked:
            String(localized: "Blocked")
        }
    }
}

/// Derived advisory readiness for one pull request.
nonisolated struct AgentPRMergeReadiness: Equatable, Hashable, Sendable {
    /// Whether GitHub marks the PR as draft.
    let isDraft: Bool
    /// Aggregated CI/check summary.
    let checks: AgentPRCheckSummary
    /// Aggregated review and findings summary.
    let review: AgentPRReviewSummary

    /// Derived readiness state.
    var state: AgentPRMergeReadinessState {
        if isDraft { return .blocked }
        if checks.state == .failed || review.findingsState == .changesRequested {
            return .attentionNeeded
        }
        if case .unresolvedFindings = review.findingsState {
            return .attentionNeeded
        }
        if checks.state == .waiting || review.findingsState == .reviewPending {
            return .waiting
        }
        if checks.state == .green && review.state == .approved && review.findingsState == .none {
            return .ready
        }
        return .waiting
    }
}

/// Display row for one monitored pull request.
nonisolated struct AgentPullRequest: Identifiable, Equatable, Hashable, Sendable {
    /// Repository that owns the pull request.
    let repository: GitHubRepositoryRef
    /// GitHub pull request number.
    let number: Int
    /// Pull request title.
    let title: String
    /// Browser URL for pull request follow-up.
    let url: URL
    /// Whether the pull request is marked as draft.
    let isDraft: Bool
    /// Author login if visible to the token.
    let authorLogin: String?
    /// Best-effort agent/human source classification.
    let source: AgentPRAuthorSource
    /// Head branch name.
    let headRefName: String
    /// Head commit SHA.
    let headSHA: String
    /// Base branch name.
    let baseRefName: String
    /// Linked closing issues visible to the token.
    let linkedIssues: [AgentPRLinkedIssue]
    /// Review and finding summary.
    let review: AgentPRReviewSummary
    /// CI/check summary.
    let checks: AgentPRCheckSummary
    /// Last updated timestamp returned by GitHub.
    let updatedAt: Date

    /// Stable row identity using repository and PR number.
    var id: String { "\(repository.id)#\(number)" }

    /// Advisory merge-readiness state derived from draft, CI, and review data.
    var readiness: AgentPRMergeReadiness {
        AgentPRMergeReadiness(isDraft: isDraft, checks: checks, review: review)
    }

    /// Search predicate covering title, branch, author, repository, issue, and state text.
    func matches(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let issueText = linkedIssues.map { "#\($0.number) \($0.title)" }.joined(separator: " ")
        return [
            title,
            repository.displayName,
            "#\(number)",
            authorLogin ?? "",
            source.displayName,
            headRefName,
            baseRefName,
            issueText,
            checks.state.displayName,
            review.state.displayName,
            review.findingsState.displayName,
            readiness.state.displayName,
        ]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(trimmed)
    }
}

/// Immutable refresh snapshot returned by a GitHub fetch.
nonisolated struct AgentPRMonitorSnapshot: Equatable, Sendable {
    /// Pull request rows in display order.
    let rows: [AgentPullRequest]
    /// Latest GitHub rate-limit state when available.
    let rateLimit: GitHubRateLimitState?
}

/// GitHub API rate-limit metadata safe for display.
nonisolated struct GitHubRateLimitState: Decodable, Equatable, Sendable {
    /// Remaining request budget if GitHub exposed it.
    let remaining: Int?
    /// Reset time if GitHub exposed it.
    let resetAt: Date?
}
