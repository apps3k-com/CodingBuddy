//
//  AgentPRGuidance.swift
//  CodingBuddy
//

import Foundation

/// Whether a visible pull request row still reflects a successful repository refresh.
nonisolated enum AgentPRGuidanceFreshness: Equatable, Sendable {
    /// No repository refresh problem makes the row stale.
    case fresh
    /// A repository refresh is running while the previous snapshot remains visible.
    case refreshing
    /// GitHub authorization must be repaired before the row can be refreshed.
    case authorizationRequired
    /// GitHub is temporarily rejecting refresh requests because of its rate limit.
    case rateLimited
    /// A non-authorization refresh attempt failed while the previous row remained visible.
    case refreshFailed
}

/// Existing feature routes that guidance may offer for a monitored pull request.
nonisolated enum AgentPRGuidanceRoute: String, CaseIterable, Sendable {
    /// Opens the pull request in the browser.
    case openPullRequest = "agent-pr-monitor.route.open-pr"
    /// Starts the monitor's existing read-only refresh flow.
    case refresh = "agent-pr-monitor.route.refresh"
    /// Opens the app Settings surface used for GitHub authorization.
    case openSettings = "agent-pr-monitor.route.open-settings"
}

/// Stable identifiers for the sanitized evidence emitted by Agent PR guidance.
nonisolated enum AgentPRGuidanceEvidenceID: String, CaseIterable, Sendable {
    /// Identifies the sanitized owner/name pair without exposing a remote URL.
    case repository = "agent-pr-monitor.evidence.repository"
    /// Identifies the provider-assigned pull request number.
    case pullRequestNumber = "agent-pr-monitor.evidence.pr-number"
    /// Identifies the app's conservative merge-readiness classification.
    case readiness = "agent-pr-monitor.evidence.readiness"
    /// Identifies the aggregate state of required checks and status contexts.
    case continuousIntegration = "agent-pr-monitor.evidence.ci-state"
    /// Identifies the current review decision without retaining reviewer content.
    case review = "agent-pr-monitor.evidence.review-state"
    /// Identifies the count of unresolved review findings.
    case unresolvedFindings = "agent-pr-monitor.evidence.unresolved-findings"
    /// Identifies the abbreviated commit revision used to qualify the evidence.
    case headSHA = "agent-pr-monitor.evidence.head-sha"
}

/// Availability of the existing feature routes at the time guidance is built.
nonisolated struct AgentPRGuidanceActionAvailability: Equatable, Sendable {
    /// Whether the row has a valid browser destination for the pull request.
    let canOpenPullRequest: Bool
    /// Whether a repository refresh can currently be started.
    let canRefresh: Bool
    /// Whether the GitHub authorization settings route can be opened.
    let canOpenSettings: Bool

    /// Common production state when all routes are ready to execute.
    static let allAvailable = AgentPRGuidanceActionAvailability(
        canOpenPullRequest: true,
        canRefresh: true,
        canOpenSettings: true
    )
}

/// Shared deterministic PR classification used by guidance and attention ranking.
nonisolated enum AgentPRGuidanceState: String, Equatable, Sendable {
    /// The visible snapshot is stale because GitHub authorization needs repair.
    case staleAuthorization = "stale-authorization"
    /// The visible snapshot is stale because GitHub is rate limiting refreshes.
    case staleRateLimit = "stale-rate-limit"
    /// The visible snapshot is stale after a non-authorization refresh failure.
    case staleRefreshFailure = "stale-refresh-failure"
    /// A refresh is in flight while the previous snapshot remains visible.
    case refreshing
    /// All observed merge gates are satisfied, subject to GitHub's live state.
    case ready
    /// Required checks are present but have not reached a terminal result.
    case waitingForContinuousIntegration = "waiting-for-ci"
    /// Automated signals are green but a required review decision is still absent.
    case waitingForReview = "waiting-for-review"
    /// GitHub has not exposed enough check or review evidence for a safe classification.
    case waitingForSignals = "waiting-for-signals"
    /// At least one required check or status context has failed.
    case failedContinuousIntegration = "failed-ci"
    /// The current review decision requires author changes.
    case changesRequested = "changes-requested"
    /// Review threads still contain findings that must be resolved or answered.
    case unresolvedFindings = "unresolved-findings"
    /// The pull request intentionally remains outside the ready-for-review workflow.
    case draft
}

/// Pure deterministic guidance catalog for one Agent PR Monitor row.
nonisolated enum AgentPRGuidanceCatalog {
    /// Non-routable action identity used for healthy and honestly waiting states.
    static let noActionID = "agent-pr-monitor.action.no-action"
    /// Non-routable action identity used while GitHub is rate limiting requests.
    static let waitForGitHubActionID = "agent-pr-monitor.action.wait-for-github"
    /// Non-routable action identity used while a repository refresh is already running.
    static let waitForRefreshActionID = "agent-pr-monitor.action.wait-for-refresh"

    /// Builds guidance without retaining provider errors, comments, titles, branches, or URLs.
    static func guidance(
        for row: AgentPullRequest,
        freshness: AgentPRGuidanceFreshness,
        actionAvailability: AgentPRGuidanceActionAvailability
    ) -> Guidance {
        let state = state(for: row, freshness: freshness)
        let copy = copy(for: state, row: row)

        return Guidance(
            id: "agent-pr-monitor.guidance.\(row.id).\(state.rawValue)",
            explanation: copy.explanation,
            relevance: copy.relevance,
            consequence: copy.consequence,
            recommendedAction: recommendedAction(
                for: state,
                copy: copy,
                availability: actionAvailability
            ),
            alternatives: [],
            technicalEvidence: evidence(for: row),
            glossaryTerms: glossaryTerms(for: state)
        )
    }

    /// Resolves only the available primary action emitted by this exact guidance value.
    static func route(for actionID: String, in guidance: Guidance) -> AgentPRGuidanceRoute? {
        guard guidance.recommendedAction.id == actionID,
              guidance.recommendedAction.availability == .available else {
            return nil
        }
        return AgentPRGuidanceRoute(rawValue: actionID)
    }

    /// Localized copy associated with one deterministic state.
    private struct Copy {
        /// Plain-language description of the observed state.
        let explanation: String
        /// Reason the state matters to the current workflow.
        let relevance: String
        /// Likely outcome if the state is left unchanged.
        let consequence: String
        /// Result the recommended action is expected to produce.
        let expectedResult: String
        /// Explicit justification when the state intentionally offers no action.
        let noActionReason: String?
    }

    /// Applies freshness precedence before examining advisory merge readiness.
    static func state(
        for row: AgentPullRequest,
        freshness: AgentPRGuidanceFreshness
    ) -> AgentPRGuidanceState {
        switch freshness {
        case .refreshing:
            return .refreshing
        case .authorizationRequired:
            return .staleAuthorization
        case .rateLimited:
            return .staleRateLimit
        case .refreshFailed:
            return .staleRefreshFailure
        case .fresh:
            break
        }

        if row.isDraft {
            return .draft
        }
        if row.checks.state == .failed {
            return .failedContinuousIntegration
        }
        if row.review.findingsState == .changesRequested {
            return .changesRequested
        }
        if row.review.unresolvedFindingCount > 0 {
            return .unresolvedFindings
        }
        if row.readiness.state == .ready {
            return .ready
        }
        if row.checks.state == .waiting {
            return .waitingForContinuousIntegration
        }
        if row.review.findingsState == .reviewPending {
            return .waitingForReview
        }
        return .waitingForSignals
    }

    /// Localized content that never incorporates provider-supplied error text.
    private static func copy(for state: AgentPRGuidanceState, row: AgentPullRequest) -> Copy {
        switch state {
        case .refreshing:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance refreshing explanation",
                    defaultValue:
                        "CodingBuddy is refreshing this repository, so this pull request still shows the previous snapshot."
                ),
                relevance: String(
                    localized: "Agent PR guidance refreshing relevance",
                    defaultValue: "The visible status can update when the current read-only refresh finishes."
                ),
                consequence: String(
                    localized: "Agent PR guidance refreshing consequence",
                    defaultValue: "The pull request stays unchanged while CodingBuddy checks GitHub for newer signals."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance wait for refresh expected result",
                    defaultValue: "No additional request is sent while the current refresh finishes."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance wait for refresh reason",
                    defaultValue: "No action is needed while the repository refresh is running."
                )
            )
        case .staleAuthorization:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance stale authorization explanation",
                    defaultValue:
                        "This pull request shows the last successful snapshot because GitHub authorization needs attention."
                ),
                relevance: String(
                    localized: "Agent PR guidance stale authorization relevance",
                    defaultValue: "CodingBuddy cannot confirm whether the pull request changed until authorization is restored."
                ),
                consequence: String(
                    localized: "Agent PR guidance stale authorization consequence",
                    defaultValue: "The visible readiness and review signals may be out of date."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance open Settings expected result",
                    defaultValue: "Settings opens so you can review the saved GitHub token."
                ),
                noActionReason: nil
            )
        case .staleRateLimit:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance stale rate limit explanation",
                    defaultValue: "This pull request shows an older snapshot because GitHub is temporarily limiting requests."
                ),
                relevance: String(
                    localized: "Agent PR guidance stale rate limit relevance",
                    defaultValue: "Refreshing before GitHub accepts requests again will not produce newer data."
                ),
                consequence: String(
                    localized: "Agent PR guidance stale rate limit consequence",
                    defaultValue: "The visible pull request status remains stale until a later refresh succeeds."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance wait for GitHub expected result",
                    defaultValue: "No request is sent while GitHub is limiting the monitor."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance wait for GitHub reason",
                    defaultValue: "Waiting is the useful next step; another refresh would be rejected."
                )
            )
        case .staleRefreshFailure:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance stale refresh failure explanation",
                    defaultValue: "The latest refresh failed, so this pull request still shows its last successful snapshot."
                ),
                relevance: String(
                    localized: "Agent PR guidance stale refresh failure relevance",
                    defaultValue: "A successful refresh is needed before CodingBuddy can confirm the current pull request status."
                ),
                consequence: String(
                    localized: "Agent PR guidance stale refresh failure consequence",
                    defaultValue: "Readiness and review information may remain out of date."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance refresh expected result",
                    defaultValue: "CodingBuddy requests a new read-only pull request snapshot."
                ),
                noActionReason: nil
            )
        case .ready:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance ready explanation",
                    defaultValue: "Visible CI checks are green and review signals show no known blocker for this pull request."
                ),
                relevance: String(
                    localized: "Agent PR guidance ready relevance",
                    defaultValue: "Based on the current snapshot, this pull request does not need follow-up in the monitor."
                ),
                consequence: String(
                    localized: "Agent PR guidance ready consequence",
                    defaultValue: "Its status can change after new commits, checks, or reviews."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance no action expected result",
                    defaultValue: "The pull request remains unchanged."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance ready no action reason",
                    defaultValue: "No action is needed based on the visible CI and review signals."
                )
            )
        case .waitingForContinuousIntegration:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance waiting for CI explanation",
                    defaultValue: "CI checks are still running or queued for this pull request."
                ),
                relevance: String(
                    localized: "Agent PR guidance waiting for CI relevance",
                    defaultValue: "The readiness result can update when those checks finish without a change from you."
                ),
                consequence: String(
                    localized: "Agent PR guidance waiting for CI consequence",
                    defaultValue: "The pull request remains in a waiting state until CI reports a result."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance wait for CI expected result",
                    defaultValue: "The pull request stays unchanged while CI finishes."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance wait for CI no action reason",
                    defaultValue: "No action is needed while CI is still running."
                )
            )
        case .waitingForReview:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance waiting for review explanation",
                    defaultValue: "This pull request is waiting for a review decision."
                ),
                relevance: String(
                    localized: "Agent PR guidance waiting for review relevance",
                    defaultValue: "The readiness result can update when a reviewer responds."
                ),
                consequence: String(
                    localized: "Agent PR guidance waiting for review consequence",
                    defaultValue: "The pull request remains in a waiting state until review is complete."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance wait for review expected result",
                    defaultValue: "The pull request stays unchanged while review is pending."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance wait for review no action reason",
                    defaultValue: "No action is needed while review is pending."
                )
            )
        case .waitingForSignals:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance waiting for signals explanation",
                    defaultValue: "The visible signals are not yet sufficient to mark this pull request ready."
                ),
                relevance: String(
                    localized: "Agent PR guidance waiting for signals relevance",
                    defaultValue: "An incomplete status is not the same as a failed check or requested change."
                ),
                consequence: String(
                    localized: "Agent PR guidance waiting for signals consequence",
                    defaultValue: "The monitor keeps this pull request in a waiting state until clearer signals are available."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance wait for signals expected result",
                    defaultValue: "The pull request stays unchanged while its status develops."
                ),
                noActionReason: String(
                    localized: "Agent PR guidance wait for signals no action reason",
                    defaultValue: "No action is required from this incomplete status alone."
                )
            )
        case .failedContinuousIntegration:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance failed CI explanation",
                    defaultValue: "At least one visible CI check failed for this pull request."
                ),
                relevance: String(
                    localized: "Agent PR guidance failed CI relevance",
                    defaultValue: "Failed checks can prevent the pull request from becoming ready."
                ),
                consequence: String(
                    localized: "Agent PR guidance failed CI consequence",
                    defaultValue: "The pull request remains blocked by CI until the failure is addressed or rerun."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance open failed CI expected result",
                    defaultValue: "The pull request opens in your browser so you can inspect the failed checks."
                ),
                noActionReason: nil
            )
        case .changesRequested:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance changes requested explanation",
                    defaultValue: "A reviewer requested changes on this pull request."
                ),
                relevance: String(
                    localized: "Agent PR guidance changes requested relevance",
                    defaultValue: "The review decision prevents the pull request from being ready."
                ),
                consequence: String(
                    localized: "Agent PR guidance changes requested consequence",
                    defaultValue: "The pull request remains blocked until the requested changes are addressed and reviewed."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance open requested changes expected result",
                    defaultValue: "The pull request opens in your browser so you can review the requested changes."
                ),
                noActionReason: nil
            )
        case .unresolvedFindings:
            Copy(
                explanation: unresolvedFindingsExplanation(
                    count: row.review.unresolvedFindingCount
                ),
                relevance: String(
                    localized: "Agent PR guidance unresolved findings relevance",
                    defaultValue: "Current review findings need attention before the pull request can be considered ready."
                ),
                consequence: String(
                    localized: "Agent PR guidance unresolved findings consequence",
                    defaultValue: "The pull request remains in a needs-attention state while findings are unresolved."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance open unresolved findings expected result",
                    defaultValue: "The pull request opens in your browser so you can inspect the unresolved findings."
                ),
                noActionReason: nil
            )
        case .draft:
            Copy(
                explanation: String(
                    localized: "Agent PR guidance draft explanation",
                    defaultValue: "GitHub marks this pull request as a draft."
                ),
                relevance: String(
                    localized: "Agent PR guidance draft relevance",
                    defaultValue: "A draft is not ready for the normal merge and review flow."
                ),
                consequence: String(
                    localized: "Agent PR guidance draft consequence",
                    defaultValue: "The pull request remains blocked until its draft status is changed on GitHub."
                ),
                expectedResult: String(
                    localized: "Agent PR guidance open draft expected result",
                    defaultValue: "The pull request opens in your browser so you can review its draft state."
                ),
                noActionReason: nil
            )
        }
    }

    /// Uses explicit singular and plural copy because String Catalog extraction cannot infer
    /// plural variations from a formatted fallback value.
    private static func unresolvedFindingsExplanation(count: Int) -> String {
        if count == 1 {
            return String(
                localized: "Agent PR guidance one unresolved finding explanation",
                defaultValue: "This pull request has 1 unresolved review finding."
            )
        }
        return String(
            format: String(
                localized: "Agent PR guidance unresolved findings explanation",
                defaultValue: "This pull request has %lld unresolved review findings."
            ),
            Int64(count)
        )
    }

    /// Builds the one primary action while keeping unavailable routes explicit.
    private static func recommendedAction(
        for state: AgentPRGuidanceState,
        copy: Copy,
        availability: AgentPRGuidanceActionAvailability
    ) -> RecommendedAction {
        switch state {
        case .refreshing:
            noAction(
                id: waitForRefreshActionID,
                title: String(
                    localized: "Agent PR guidance wait for refresh action title",
                    defaultValue: "Wait for refresh"
                ),
                copy: copy
            )
        case .staleAuthorization:
            routedAction(
                route: .openSettings,
                title: String(
                    localized: "Agent PR guidance open Settings action title",
                    defaultValue: "Open Settings"
                ),
                expectedResult: copy.expectedResult,
                isAvailable: availability.canOpenSettings,
                unavailableReason: String(
                    localized: "Agent PR guidance open Settings unavailable reason",
                    defaultValue: "Settings cannot be opened from this view."
                )
            )
        case .staleRefreshFailure:
            routedAction(
                route: .refresh,
                title: String(localized: "Agent PR guidance refresh action title", defaultValue: "Refresh"),
                expectedResult: copy.expectedResult,
                isAvailable: availability.canRefresh,
                unavailableReason: String(
                    localized: "Agent PR guidance refresh unavailable reason",
                    defaultValue: "Refresh is unavailable while another refresh is running."
                )
            )
        case .failedContinuousIntegration, .changesRequested, .unresolvedFindings, .draft:
            routedAction(
                route: .openPullRequest,
                title: String(localized: "Agent PR guidance open PR action title", defaultValue: "Open PR"),
                expectedResult: copy.expectedResult,
                isAvailable: availability.canOpenPullRequest,
                unavailableReason: String(
                    localized: "Agent PR guidance open PR unavailable reason",
                    defaultValue: "The pull request cannot be opened from this view."
                )
            )
        case .staleRateLimit:
            noAction(
                id: waitForGitHubActionID,
                title: String(
                    localized: "Agent PR guidance wait for GitHub action title",
                    defaultValue: "Wait for GitHub"
                ),
                copy: copy
            )
        case .ready, .waitingForContinuousIntegration, .waitingForReview, .waitingForSignals:
            noAction(
                id: noActionID,
                title: String(
                    localized: "Agent PR guidance no action title",
                    defaultValue: "No action needed"
                ),
                copy: copy
            )
        }
    }

    /// Creates an action backed by one typed route.
    private static func routedAction(
        route: AgentPRGuidanceRoute,
        title: String,
        expectedResult: String,
        isAvailable: Bool,
        unavailableReason: String
    ) -> RecommendedAction {
        RecommendedAction(
            id: route.rawValue,
            title: title,
            expectedResult: expectedResult,
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable ? .available : .unavailable(reason: unavailableReason)
        )
    }

    /// Creates an honest non-routable action for healthy or waiting states.
    private static func noAction(id: String, title: String, copy: Copy) -> RecommendedAction {
        guard let noActionReason = copy.noActionReason else {
            preconditionFailure("A no-action guidance state must provide a reason")
        }
        return RecommendedAction(
            id: id,
            title: title,
            expectedResult: copy.expectedResult,
            effort: .low,
            safetyClass: .readOnly,
            availability: .notNeeded(reason: noActionReason)
        )
    }

    /// Emits only the approved evidence fields, in stable display order.
    private static func evidence(for row: AgentPullRequest) -> [TechnicalEvidence] {
        [
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.repository.rawValue,
                label: String(
                    localized: "Agent PR guidance repository evidence label",
                    defaultValue: "Repository"
                ),
                sanitizedValue: safeRepositoryName(row.repository)
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.pullRequestNumber.rawValue,
                label: String(
                    localized: "Agent PR guidance PR number evidence label",
                    defaultValue: "Pull request number"
                ),
                sanitizedValue: "#\(row.number)"
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.readiness.rawValue,
                label: String(
                    localized: "Agent PR guidance readiness evidence label",
                    defaultValue: "Readiness"
                ),
                sanitizedValue: row.readiness.state.displayName
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.continuousIntegration.rawValue,
                label: String(
                    localized: "Agent PR guidance CI state evidence label",
                    defaultValue: "CI state"
                ),
                sanitizedValue: row.checks.state.displayName
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.review.rawValue,
                label: String(
                    localized: "Agent PR guidance review state evidence label",
                    defaultValue: "Review state"
                ),
                sanitizedValue: row.review.state.displayName
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.unresolvedFindings.rawValue,
                label: String(
                    localized: "Agent PR guidance unresolved findings evidence label",
                    defaultValue: "Unresolved findings"
                ),
                sanitizedValue: String(row.review.unresolvedFindingCount)
            ),
            TechnicalEvidence(
                id: AgentPRGuidanceEvidenceID.headSHA.rawValue,
                label: String(
                    localized: "Agent PR guidance head SHA evidence label",
                    defaultValue: "Head commit"
                ),
                sanitizedValue: shortHeadSHA(row.headSHA)
            ),
        ]
    }

    /// Keeps repository evidence on one line and removes control characters.
    private static func safeRepositoryName(_ repository: GitHubRepositoryRef) -> String {
        let owner = safeRepositoryComponent(repository.owner)
        let name = safeRepositoryComponent(repository.name)
        guard !owner.isEmpty, !name.isEmpty else {
            return String(
                localized: "Agent PR guidance unknown repository evidence value",
                defaultValue: "Unknown repository"
            )
        }
        return "\(owner)/\(name)"
    }

    /// Normalizes one provider-supplied repository component for single-line evidence.
    private static func safeRepositoryComponent(_ component: String) -> String {
        component
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    /// Shows at most seven hexadecimal characters and rejects malformed provider data.
    private static func shortHeadSHA(_ headSHA: String) -> String {
        let normalized = headSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            return String(
                localized: "Agent PR guidance unavailable head SHA evidence value",
                defaultValue: "Unavailable"
            )
        }
        return String(normalized.prefix(7))
    }

    /// Attaches only glossary terms directly used by the current explanation.
    private static func glossaryTerms(for state: AgentPRGuidanceState) -> [DeveloperTerm] {
        switch state {
        case .ready, .waitingForContinuousIntegration, .failedContinuousIntegration:
            [.pr, .ci]
        case .refreshing, .staleAuthorization, .staleRateLimit, .staleRefreshFailure, .waitingForReview,
             .waitingForSignals, .changesRequested, .unresolvedFindings, .draft:
            [.pr]
        }
    }
}
