//
//  PullRequestReviewDeskStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Read lifecycle for the focused pull request Review Desk.
nonisolated enum PullRequestReviewDeskState: Equatable, Sendable {
    /// No pull request has been selected.
    case idle
    /// A complete snapshot is loading.
    case loading
    /// A complete snapshot is available.
    case loaded
    /// Refresh failed while a previous snapshot may remain visible.
    case failed(String)
}

/// Mutation lifecycle kept separate from read refresh state.
nonisolated enum PullRequestReviewActionState: Equatable, Sendable {
    /// No action is running.
    case idle
    /// CodingBuddy is loading and validating a fresh preflight.
    case preflighting
    /// One mutation request is in flight.
    case executing
    /// GitHub accepted the mutation and CodingBuddy is verifying server state.
    case verifying
    /// A fresh snapshot verified the last mutation.
    case succeeded(String)
    /// State changed before the action could execute.
    case drifted
    /// GitHub may have committed the write, so a fresh read is required.
    case ambiguous
    /// A known action failure occurred.
    case failed(String)

    /// Whether a new action may start.
    var allowsNewAction: Bool {
        switch self {
        case .idle, .succeeded, .drifted, .failed:
            true
        case .preflighting, .executing, .verifying, .ambiguous:
            false
        }
    }
}

/// High-risk action awaiting an explicit user confirmation.
nonisolated enum PullRequestReviewConfirmation: Equatable, Sendable {
    /// Draft-to-ready transition bound to a fresh preflight.
    case markReady(PullRequestMutationPreflight)
    /// Merge transition bound to a fresh preflight and selected merge method.
    case merge(PullRequestMergeMethod, PullRequestMutationPreflight)

    /// Snapshot head shown in confirmation copy.
    var expectedHeadOID: String {
        switch self {
        case .markReady(let preflight), .merge(_, let preflight):
            preflight.expectedHeadOID
        }
    }

    /// One-use proof that should be revoked if the confirmation is cancelled.
    var preflight: PullRequestMutationPreflight {
        switch self {
        case .markReady(let preflight), .merge(_, let preflight):
            preflight
        }
    }
}

/// Main-actor state machine for one focused pull request and serialized actions.
@Observable
final class PullRequestReviewDeskStore {
    /// Current read lifecycle.
    private(set) var state: PullRequestReviewDeskState = .idle
    /// Current action lifecycle.
    private(set) var actionState: PullRequestReviewActionState = .idle
    /// Selected Review Desk target.
    private(set) var selectedTarget: PullRequestReviewTarget?
    /// Latest complete server snapshot.
    private(set) var snapshot: PullRequestReviewSnapshot?
    /// One-use confirmation consumed before its mutation begins.
    private(set) var pendingConfirmation: PullRequestReviewConfirmation?
    /// Last action whose resulting server state was verified by a complete re-fetch.
    private(set) var lastVerifiedAction: PullRequestMutationIntent?
    /// Uncertain mutation retained until CodingBuddy verifies it or the user acknowledges it.
    @ObservationIgnored private var ambiguousMutation: AmbiguousMutation?

    /// Complete GraphQL Review Desk client.
    @ObservationIgnored private let client: GitHubPullRequestReviewClient
    /// Actor enforcing credential source and refresh policy.
    @ObservationIgnored private let credentialCoordinator: GitHubCredentialCoordinator
    /// Current cancellable read request.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Serialized action task; a second action cannot replace it.
    @ObservationIgnored private var actionTask: Task<Void, Never>?

    /// Creates a store with injectable GitHub boundaries.
    init(
        client: GitHubPullRequestReviewClient = GitHubPullRequestReviewClient(),
        credentialCoordinator: GitHubCredentialCoordinator = GitHubCredentialCoordinator()
    ) {
        self.client = client
        self.credentialCoordinator = credentialCoordinator
    }

    /// Cancels read-only work when the root store is released.
    deinit {
        loadTask?.cancel()
    }

    /// Whether the current verified snapshot can start a scoped action.
    var actionsAreEnabled: Bool {
        state == .loaded
            && snapshot?.coverage == .complete
            && actionState.allowsNewAction
            && pendingConfirmation == nil
    }

    /// Whether an uncertain write currently blocks every further mutation and target change.
    var hasAmbiguousAction: Bool { ambiguousMutation != nil }

    /// Selects a monitor row and loads its dedicated complete Review Desk snapshot.
    @discardableResult
    func select(_ pullRequest: AgentPullRequest) -> Bool {
        let target = PullRequestReviewTarget(
            repository: pullRequest.repository,
            number: pullRequest.number
        )
        guard selectedTarget != target || snapshot == nil else { return true }
        guard actionState.allowsNewAction, pendingConfirmation == nil else { return false }
        selectedTarget = target
        snapshot = nil
        lastVerifiedAction = nil
        refresh()
        return true
    }

    /// Clears a stale table selection only when no mutation still owns its target.
    @discardableResult
    func clearSelection() -> Bool {
        guard actionState.allowsNewAction, pendingConfirmation == nil else { return false }
        loadTask?.cancel()
        selectedTarget = nil
        snapshot = nil
        lastVerifiedAction = nil
        state = .idle
        return true
    }

    /// Reloads the selected pull request while retaining a previous verified snapshot.
    func refresh() {
        guard actionState.allowsNewAction, pendingConfirmation == nil else { return }
        guard let target = selectedTarget else {
            state = .idle
            return
        }
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .readOnly)
                let refreshed = try await client.fetchSnapshot(
                    target: target,
                    token: credential.accessToken
                )
                try Task.checkCancellation()
                guard selectedTarget == target else { return }
                snapshot = refreshed
                state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard selectedTarget == target else { return }
                state = .failed(Self.safeMessage(for: error))
            }
        }
    }

    /// Replies to one unresolved inline thread after a fresh complete preflight.
    func reply(threadID: String, body: String) {
        runImmediateAction(
            intent: .reply(threadID: threadID, body: body),
            successMessage: String(localized: "Reply sent")
        ) { client, credential, preflight in
            try await client.reply(
                to: threadID,
                body: body,
                credential: credential,
                preflight: preflight
            )
        }
    }

    /// Resolves one unresolved inline thread after a fresh complete preflight.
    func resolve(threadID: String) {
        runImmediateAction(
            intent: .resolve(threadID: threadID),
            successMessage: String(localized: "Thread resolved")
        ) { client, credential, preflight in
            try await client.resolve(
                threadID: threadID,
                credential: credential,
                preflight: preflight
            )
        }
    }

    /// Prepares a state-bound draft transition and exposes its confirmation.
    func requestMarkReadyConfirmation() {
        prepareConfirmation(intent: .markReady) { snapshot, preflight in
            guard snapshot.isDraft else { throw GitHubPullRequestReviewError.invalidMutation }
            return .markReady(preflight)
        }
    }

    /// Prepares a merge only when the complete fresh snapshot satisfies every gate.
    func requestMergeConfirmation(method: PullRequestMergeMethod) {
        prepareConfirmation(intent: .merge(method: method)) { snapshot, preflight in
            guard snapshot.isMergeEligible,
                  snapshot.mergeMethods.allows(method) else {
                throw GitHubPullRequestReviewError.mergeNotReady
            }
            return .merge(method, preflight)
        }
    }

    /// Cancels the current confirmation without affecting verified read state.
    func cancelConfirmation() {
        let preflight = pendingConfirmation?.preflight
        pendingConfirmation = nil
        actionState = .idle
        if let preflight {
            Task { [client] in
                await client.discard(preflight: preflight)
            }
        }
    }

    /// Consumes and executes one pending high-risk confirmation.
    func confirmPendingAction() {
        guard actionTask == nil,
              let confirmation = pendingConfirmation,
              let baselineSnapshot = snapshot,
              baselineSnapshot.digest == confirmation.preflight.snapshotDigest else {
            return
        }
        pendingConfirmation = nil
        actionState = .executing
        lastVerifiedAction = nil
        actionTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                switch confirmation {
                case .markReady(let preflight):
                    let receipt = try await client.markReady(
                        credential: credential,
                        preflight: preflight
                    )
                    await verifyAfterMutation(
                        target: confirmationTarget(confirmation),
                        credential: credential,
                        intent: confirmationIntent(confirmation),
                        baselineSnapshot: baselineSnapshot,
                        receipt: receipt,
                        successMessage: String(localized: "Pull request is ready for review")
                    )
                case .merge(let method, let preflight):
                    let receipt = try await client.merge(
                        method: method,
                        credential: credential,
                        preflight: preflight
                    )
                    await verifyAfterMutation(
                        target: confirmationTarget(confirmation),
                        credential: credential,
                        intent: confirmationIntent(confirmation),
                        baselineSnapshot: baselineSnapshot,
                        receipt: receipt,
                        successMessage: String(localized: "Pull request merged")
                    )
                }
            } catch {
                publishMutationFailure(
                    error,
                    target: confirmationTarget(confirmation),
                    intent: confirmationIntent(confirmation),
                    baselineSnapshot: baselineSnapshot
                )
            }
            actionTask = nil
        }
    }

    /// Clears a terminal action notice without changing the loaded snapshot.
    func clearActionNotice() {
        guard actionState.allowsNewAction else { return }
        actionState = .idle
    }

    /// Re-fetches server state and compares it with the exact uncertain mutation baseline.
    func verifyAmbiguousAction() {
        guard actionTask == nil,
              actionState == .ambiguous,
              let ambiguousMutation else {
            return
        }
        actionState = .verifying
        actionTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                let refreshed = try await client.fetchSnapshot(
                    target: ambiguousMutation.target,
                    token: credential.accessToken
                )
                snapshot = refreshed
                state = .loaded
                publishReconciliation(
                    refreshed,
                    ambiguousMutation: ambiguousMutation,
                    successMessage: String(localized: "Action verified on GitHub")
                )
            } catch {
                state = .failed(Self.safeMessage(for: error))
                actionState = .ambiguous
            }
            actionTask = nil
        }
    }

    /// Releases an uncertain write only after the user explicitly checked GitHub.
    func acknowledgeAmbiguousAction() {
        guard actionTask == nil, actionState == .ambiguous, ambiguousMutation != nil else { return }
        ambiguousMutation = nil
        lastVerifiedAction = nil
        actionState = .idle
    }

    /// Prepares and runs a low-risk scoped mutation without a confirmation sheet.
    private func runImmediateAction(
        intent: PullRequestMutationIntent,
        successMessage: String,
        operation: @escaping @Sendable (
            GitHubPullRequestReviewClient,
            GitHubCredential,
            PullRequestMutationPreflight
        ) async throws -> PullRequestMutationReceipt
    ) {
        guard actionTask == nil, actionsAreEnabled, let target = selectedTarget else { return }
        actionState = .preflighting
        lastVerifiedAction = nil
        actionTask = Task { [client, credentialCoordinator] in
            var preparedSnapshot: PullRequestReviewSnapshot?
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                let prepared = try await client.prepareMutation(
                    target: target,
                    token: credential.accessToken,
                    intent: intent
                )
                preparedSnapshot = prepared.snapshot
                actionState = .executing
                let receipt = try await operation(client, credential, prepared.preflight)
                await verifyAfterMutation(
                    target: target,
                    credential: credential,
                    intent: intent,
                    baselineSnapshot: prepared.snapshot,
                    receipt: receipt,
                    successMessage: successMessage
                )
            } catch {
                publishMutationFailure(
                    error,
                    target: target,
                    intent: intent,
                    baselineSnapshot: preparedSnapshot
                )
            }
            actionTask = nil
        }
    }

    /// Loads one confirmation-bound preflight for Ready or merge.
    private func prepareConfirmation(
        intent: PullRequestMutationIntent,
        makeConfirmation: @escaping @Sendable (
            PullRequestReviewSnapshot,
            PullRequestMutationPreflight
        ) throws -> PullRequestReviewConfirmation
    ) {
        guard actionTask == nil, actionsAreEnabled, let target = selectedTarget else { return }
        actionState = .preflighting
        actionTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                let prepared = try await client.prepareMutation(
                    target: target,
                    token: credential.accessToken,
                    intent: intent
                )
                pendingConfirmation = try makeConfirmation(prepared.snapshot, prepared.preflight)
                snapshot = prepared.snapshot
                state = .loaded
                actionState = .idle
            } catch {
                publishPreparationFailure(error)
            }
            actionTask = nil
        }
    }

    /// Reloads complete server state before announcing a successful mutation.
    private func verifyAfterMutation(
        target: PullRequestReviewTarget,
        credential: GitHubCredential,
        intent: PullRequestMutationIntent,
        baselineSnapshot: PullRequestReviewSnapshot,
        receipt: PullRequestMutationReceipt,
        successMessage: String
    ) async {
        actionState = .verifying
        do {
            let verified = try await client.fetchSnapshot(target: target, token: credential.accessToken)
            snapshot = verified
            state = .loaded
            publishReconciliation(
                verified,
                ambiguousMutation: AmbiguousMutation(
                    target: target,
                    intent: intent,
                    baselineSnapshot: baselineSnapshot,
                    receiptResourceID: receipt.resourceID
                ),
                successMessage: successMessage
            )
        } catch {
            state = .failed(Self.safeMessage(for: error))
            ambiguousMutation = AmbiguousMutation(
                target: target,
                intent: intent,
                baselineSnapshot: baselineSnapshot,
                receiptResourceID: receipt.resourceID
            )
            actionState = .ambiguous
        }
    }

    /// Returns the target bound by a confirmation's preflight.
    private func confirmationTarget(_ confirmation: PullRequestReviewConfirmation) -> PullRequestReviewTarget {
        switch confirmation {
        case .markReady(let preflight), .merge(_, let preflight):
            preflight.target
        }
    }

    /// Returns the exact action intent carried by a confirmation.
    private func confirmationIntent(
        _ confirmation: PullRequestReviewConfirmation
    ) -> PullRequestMutationIntent {
        switch confirmation {
        case .markReady:
            .markReady
        case .merge(let method, _):
            .merge(method: method)
        }
    }

    /// Publishes a preflight failure before any mutation could have reached GitHub.
    private func publishPreparationFailure(_ error: Error) {
        switch error {
        case GitHubPullRequestReviewError.driftDetected:
            actionState = .drifted
            refresh()
        default:
            actionState = .failed(Self.safeMessage(for: error))
        }
    }

    /// Retains enough baseline state to prevent an automatic retry after an uncertain write.
    private func publishMutationFailure(
        _ error: Error,
        target: PullRequestReviewTarget,
        intent: PullRequestMutationIntent,
        baselineSnapshot: PullRequestReviewSnapshot?
    ) {
        switch error {
        case GitHubPullRequestReviewError.driftDetected:
            ambiguousMutation = nil
            actionState = .drifted
            refresh()
        case GitHubPullRequestReviewError.ambiguousWrite:
            guard let baselineSnapshot else {
                actionState = .failed(Self.safeMessage(for: error))
                return
            }
            ambiguousMutation = AmbiguousMutation(
                target: target,
                intent: intent,
                baselineSnapshot: baselineSnapshot,
                receiptResourceID: nil
            )
            actionState = .ambiguous
        default:
            ambiguousMutation = nil
            actionState = .failed(Self.safeMessage(for: error))
        }
    }

    /// Converts a complete post-write snapshot into a verified, retryable, or blocked outcome.
    private func publishReconciliation(
        _ refreshed: PullRequestReviewSnapshot,
        ambiguousMutation mutation: AmbiguousMutation,
        successMessage: String
    ) {
        switch Self.applicationStatus(of: mutation, in: refreshed) {
        case .applied:
            ambiguousMutation = nil
            lastVerifiedAction = mutation.intent
            actionState = .succeeded(successMessage)
        case .notApplied:
            ambiguousMutation = nil
            lastVerifiedAction = nil
            actionState = .failed(String(localized: "GitHub did not apply the action. Review the refreshed state before trying again."))
        case .inconclusive:
            ambiguousMutation = mutation
            lastVerifiedAction = nil
            actionState = .ambiguous
        }
    }

    /// Compares the exact mutation baseline with one complete same-principal snapshot.
    private static func applicationStatus(
        of mutation: AmbiguousMutation,
        in refreshed: PullRequestReviewSnapshot
    ) -> MutationApplicationStatus {
        let baseline = mutation.baselineSnapshot
        guard refreshed.coverage == .complete,
              refreshed.target == mutation.target,
              refreshed.pullRequestID == baseline.pullRequestID,
              refreshed.principalID == baseline.principalID else {
            return .inconclusive
        }

        switch mutation.intent {
        case .reply(let threadID, _):
            guard let oldThread = baseline.reviewThreads.first(where: { $0.id == threadID }),
                  let newThread = refreshed.reviewThreads.first(where: { $0.id == threadID }) else {
                return .inconclusive
            }
            let oldCommentIDs = Set(oldThread.comments.map(\.id))
            let addedComments = newThread.comments.filter { !oldCommentIDs.contains($0.id) }
            if let receiptResourceID = mutation.receiptResourceID,
               addedComments.contains(where: {
                   $0.id == receiptResourceID
                       && PullRequestMutationIntent.reply(threadID: threadID, body: $0.body) == mutation.intent
               }) {
                return .applied
            }
            return addedComments.isEmpty ? .notApplied : .inconclusive
        case .resolve(let threadID):
            guard let newThread = refreshed.reviewThreads.first(where: { $0.id == threadID }) else {
                return .inconclusive
            }
            return newThread.isResolved ? .applied : .notApplied
        case .markReady:
            return refreshed.isDraft ? .notApplied : .applied
        case .merge:
            return refreshed.isMerged ? .applied : .notApplied
        }
    }

    /// Maps only known safe error types into user-facing copy.
    private static func safeMessage(for error: Error) -> String {
        if let error = error as? GitHubCredentialCoordinatorError {
            return error.localizedDescription
        }
        if let error = error as? GitHubOAuthDeviceFlowError {
            return error.localizedDescription
        }
        if let error = error as? GitHubPullRequestReviewError {
            switch error {
            case .noToken: return String(localized: "Sign in to GitHub to continue.")
            case .authenticationFailed: return String(localized: "GitHub rejected the saved authorization.")
            case .missingPermission: return String(localized: "The GitHub App is missing a required repository permission.")
            case .pullRequestUnavailable: return String(localized: "This pull request is no longer available.")
            case .rateLimited: return String(localized: "GitHub rate limit reached. Try again later.")
            case .networkUnavailable: return String(localized: "GitHub is unreachable. Check your network connection and try again.")
            case .driftDetected: return String(localized: "The pull request changed. Review the refreshed state before trying again.")
            case .writesNotAllowed: return String(localized: "Sign in with the CodingBuddy GitHub App before changing pull requests.")
            case .mergeNotReady: return String(localized: "This pull request does not satisfy every merge requirement.")
            case .ambiguousWrite: return String(localized: "GitHub may have applied the action. Refresh before trying again.")
            default: return String(localized: "CodingBuddy could not verify the pull request state.")
            }
        }
        return String(localized: "CodingBuddy could not complete the GitHub action.")
    }

    /// Snapshot-bound context required to reconcile one uncertain mutation.
    private struct AmbiguousMutation {
        /// Pull request that owned the write.
        let target: PullRequestReviewTarget
        /// Exact scoped action that may have reached GitHub.
        let intent: PullRequestMutationIntent
        /// Complete state immediately before the write.
        let baselineSnapshot: PullRequestReviewSnapshot
        /// Exact changed resource returned by GitHub, absent after transport ambiguity.
        let receiptResourceID: String?
    }

    /// Result of comparing a mutation baseline with fresh complete server state.
    private enum MutationApplicationStatus {
        /// The expected state transition is proven.
        case applied
        /// Complete state proves the transition did not occur.
        case notApplied
        /// Concurrent or transformed state prevents a safe conclusion.
        case inconclusive
    }
}
