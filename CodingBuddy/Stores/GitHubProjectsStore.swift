//
//  GitHubProjectsStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Minimal injectable persistence boundary for Project workspace preferences.
@MainActor
protocol GitHubProjectPreferencesStoring: AnyObject {
    /// Returns encoded preferences for one key.
    func data(forKey defaultName: String) -> Data?
    /// Stores encoded preferences for one key.
    func setGitHubProjectData(_ value: Data, forKey defaultName: String)
}

extension UserDefaults: GitHubProjectPreferencesStoring {
    /// Stores encoded Project preferences without persisting provider data.
    func setGitHubProjectData(_ value: Data, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}

/// Read lifecycle for organization Project discovery and one selected snapshot.
nonisolated enum GitHubProjectsLoadState: Equatable, Sendable {
    /// No network request has started.
    case idle
    /// A bounded read is running.
    case loading
    /// The requested provider data was loaded.
    case loaded
    /// The request failed while a previous snapshot may remain visible.
    case failed(String)
}

/// Serialized mutation lifecycle for one Project field move.
nonisolated enum GitHubProjectMoveState: Equatable, Sendable {
    /// No mutation work is active.
    case idle
    /// Fresh Project evidence and write capability are being validated.
    case preflighting
    /// A risk-classified move awaits explicit confirmation.
    case awaitingConfirmation
    /// Exactly one mutation is in flight.
    case executing
    /// A post-write snapshot verified the destination.
    case succeeded(String)
    /// Provider or local policy evidence changed before execution.
    case drifted
    /// GitHub may have accepted the mutation; every further write is blocked.
    case ambiguous
    /// A known mutation failure occurred before an ambiguous response.
    case failed(String)

    /// Whether another move may begin.
    var allowsNewMove: Bool {
        switch self {
        case .idle, .succeeded, .drifted, .failed: true
        case .preflighting, .awaitingConfirmation, .executing, .ambiguous: false
        }
    }
}

/// Main-actor ProjectV2 board, drift-audit, and guarded-mutation state machine.
@Observable
final class GitHubProjectsStore {
    /// UserDefaults key containing local display and policy preferences only.
    static let preferencesKey = "githubProjects.workspacePreferences.v1"
    /// UserDefaults key containing only the minimum context needed to verify an uncertain write.
    static let ambiguousMoveKey = "githubProjects.ambiguousMove.v1"

    /// Organization Project discovery lifecycle.
    private(set) var discoveryState = GitHubProjectsLoadState.idle
    /// Selected Project snapshot lifecycle.
    private(set) var snapshotState = GitHubProjectsLoadState.idle
    /// Serialized mutation lifecycle.
    private(set) var moveState = GitHubProjectMoveState.idle
    /// Last bounded Project discovery result.
    private(set) var projectList: GitHubProjectList?
    /// Latest authoritative selected Project snapshot.
    private(set) var snapshot: GitHubProjectSnapshot?
    /// Latest deterministic drift assessment.
    private(set) var assessment: GitHubProjectDriftAssessment?
    /// Shared filtered data consumed by both Table and Board.
    private(set) var projection: GitHubProjectBoardProjection?
    /// High-risk one-use proof awaiting user confirmation.
    private(set) var pendingPreflight: GitHubProjectMovePreflight?
    /// Restored local-only workspace preferences.
    private(set) var preferences: GitHubProjectBoardPreferences

    /// Native Project service.
    @ObservationIgnored private let client: any GitHubProjectsServing
    /// Credential source shared with GitHub Settings and Review Desk.
    @ObservationIgnored private let credentialCoordinator: GitHubCredentialCoordinator
    /// Pure deterministic drift analyzer.
    @ObservationIgnored private let analyzer: any GitHubProjectDriftAnalyzing
    /// Injectable local preferences backend.
    @ObservationIgnored private let defaults: any GitHubProjectPreferencesStoring
    /// Cancellable read task.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Serialized mutation task.
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    /// Mutation context retained only when provider outcome is ambiguous.
    @ObservationIgnored private var ambiguousMove: AmbiguousMove?
    /// Invalidates completions that began under an older GitHub credential.
    @ObservationIgnored private var authorizationGeneration = UUID()

    /// Creates a store without reading GitHub or user home content.
    init(
        client: any GitHubProjectsServing = GitHubProjectsClient(),
        credentialCoordinator: GitHubCredentialCoordinator = GitHubCredentialCoordinator(),
        analyzer: any GitHubProjectDriftAnalyzing = GitHubProjectDriftAnalyzer(),
        defaults: any GitHubProjectPreferencesStoring = UserDefaults.standard
    ) {
        self.client = client
        self.credentialCoordinator = credentialCoordinator
        self.analyzer = analyzer
        self.defaults = defaults
        self.preferences = Self.loadPreferences(from: defaults)
        self.ambiguousMove = Self.loadAmbiguousMove(from: defaults)
        if ambiguousMove != nil {
            moveState = .ambiguous
        }
    }

    /// Cancels read-only work when the root-owned store is released.
    deinit {
        loadTask?.cancel()
    }

    /// Whether complete evidence and semantics allow a new move preflight.
    var movesAreEnabled: Bool {
        guard discoveryState == .loaded,
              snapshotState == .loaded,
              let selectedProjectID = preferences.selectedProjectID,
              projectList?.projects.contains(where: { $0.id == selectedProjectID }) == true,
              let snapshot,
              snapshot.project.id == selectedProjectID,
              snapshot.coverage.isComplete,
              snapshot.project.viewerCanUpdate,
              let fieldID = preferences.selectedFieldID,
              let field = snapshot.fields.first(where: { $0.id == fieldID }),
              let policy = preferences.policy else { return false }
        return moveState.allowsNewMove
            && pendingPreflight == nil
            && ambiguousMove == nil
            && policy.projectID == snapshot.project.id
            && policy.fieldID == field.id
            && policy.completelyClassifies(field)
    }

    /// Clears provider-backed state and invalidates work started under an older credential.
    func handleGitHubAuthorizationChange(_ change: GitHubAuthorizationChange) {
        let hasUnreconciledWrite = ambiguousMove != nil
        authorizationGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        moveTask?.cancel()
        moveTask = nil
        cancelPendingPreflight()

        projectList = nil
        snapshot = nil
        assessment = nil
        projection = nil
        preferences.selectedProjectID = nil
        preferences.selectedFieldID = nil
        preferences.policy = nil
        discoveryState = .idle
        snapshotState = .idle
        if hasUnreconciledWrite {
            moveState = .ambiguous
        } else {
            replaceAmbiguousMove(nil)
            moveState = .idle
        }
        persistPreferences()

        if change == .saved,
           moveState.allowsNewMove,
           !preferences.organizationLogin.isEmpty {
            discoverProjects()
        }
    }

    /// Updates the organization input and clears provider selections from another owner.
    func setOrganizationLogin(_ login: String) {
        guard moveState.allowsNewMove else { return }
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferences.organizationLogin != trimmed else { return }
        loadTask?.cancel()
        preferences.organizationLogin = trimmed
        preferences.selectedProjectID = nil
        preferences.selectedFieldID = nil
        preferences.policy = nil
        projectList = nil
        snapshot = nil
        assessment = nil
        projection = nil
        discoveryState = .idle
        snapshotState = .idle
        persistPreferences()
    }

    /// Discovers organization Projects with the current read credential.
    func discoverProjects() {
        guard moveState.allowsNewMove else { return }
        let login = preferences.organizationLogin
        let generation = authorizationGeneration
        loadTask?.cancel()
        discoveryState = .loading
        loadTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .readOnly)
                let list = try await client.discoverProjects(
                    organizationLogin: login,
                    token: credential.accessToken
                )
                try Task.checkCancellation()
                guard authorizationGeneration == generation,
                      preferences.organizationLogin == login else { return }
                projectList = list
                discoveryState = .loaded
                if let projectID = preferences.selectedProjectID {
                    if list.projects.contains(where: { $0.id == projectID }) || list.isTruncated {
                        refreshSnapshot()
                    } else {
                        clearRemovedProjectContext()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard authorizationGeneration == generation,
                      preferences.organizationLogin == login else { return }
                discoveryState = .failed(Self.safeMessage(for: error))
            }
        }
    }

    /// Selects one discovered Project and loads its authoritative snapshot.
    func selectProject(id: String) {
        guard moveState.allowsNewMove,
              projectList?.projects.contains(where: { $0.id == id }) == true else { return }
        cancelPendingPreflight()
        preferences.selectedProjectID = id
        preferences.selectedFieldID = nil
        preferences.policy = nil
        snapshot = nil
        assessment = nil
        projection = nil
        persistPreferences()
        refreshSnapshot()
    }

    /// Re-fetches the selected Project while retaining prior verified data on failure.
    func refreshSnapshot() {
        guard moveState.allowsNewMove,
              pendingPreflight == nil,
              let projectID = preferences.selectedProjectID else { return }
        let login = preferences.organizationLogin
        let generation = authorizationGeneration
        loadTask?.cancel()
        snapshotState = .loading
        loadTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .readOnly)
                let refreshed = try await client.fetchSnapshot(
                    organizationLogin: login,
                    projectID: projectID,
                    token: credential.accessToken
                )
                try Task.checkCancellation()
                guard authorizationGeneration == generation,
                      preferences.organizationLogin == login,
                      preferences.selectedProjectID == projectID else { return }
                publish(refreshed)
                snapshotState = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard authorizationGeneration == generation,
                      preferences.selectedProjectID == projectID else { return }
                snapshotState = .failed(Self.safeMessage(for: error))
            }
        }
    }

    /// Selects the field used by both display modes and initializes an unclassified policy.
    func selectField(id: String) {
        guard moveState.allowsNewMove,
              let snapshot,
              snapshot.fields.contains(where: { $0.id == id }) else { return }
        cancelPendingPreflight()
        preferences.selectedFieldID = id
        if preferences.policy?.projectID != snapshot.project.id || preferences.policy?.fieldID != id {
            preferences.policy = .empty(projectID: snapshot.project.id, fieldID: id)
        }
        persistPreferences()
        rebuildProjection()
    }

    /// Replaces explicit local drift semantics and invalidates every older confirmation.
    func updatePolicy(_ policy: GitHubProjectDriftPolicy) {
        guard moveState.allowsNewMove,
              pendingPreflight == nil,
              let snapshot,
              let fieldID = preferences.selectedFieldID,
              policy.projectID == snapshot.project.id,
              policy.fieldID == fieldID else { return }
        cancelPendingPreflight()
        preferences.policy = policy
        persistPreferences()
        rebuildProjection()
    }

    /// Updates the local representation without changing provider data.
    func setViewMode(_ mode: GitHubProjectViewMode) {
        preferences.viewMode = mode
        persistPreferences()
    }

    /// Updates local filters and rebuilds the single shared projection.
    func setFilter(_ filter: GitHubProjectBoardFilter) {
        preferences.filter = filter
        persistPreferences()
        rebuildProjection()
    }

    /// Starts a fresh write-capable preflight for one exact destination.
    func requestMove(itemID: String, destinationOptionID: String?) {
        guard moveTask == nil,
              movesAreEnabled,
              let projectID = preferences.selectedProjectID,
              let fieldID = preferences.selectedFieldID,
              let policy = preferences.policy else { return }
        let login = preferences.organizationLogin
        let generation = authorizationGeneration
        moveState = .preflighting
        moveTask = Task { [credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                let prepared = try await client.prepareMove(
                    organizationLogin: login,
                    projectID: projectID,
                    itemID: itemID,
                    fieldID: fieldID,
                    destinationOptionID: destinationOptionID,
                    policy: policy,
                    credential: credential
                )
                try Task.checkCancellation()
                guard authorizationGeneration == generation else {
                    await client.discard(preflight: prepared.preflight)
                    return
                }
                publish(prepared.snapshot)
                guard preferences.policy?.digest == prepared.preflight.policyDigest else {
                    await client.discard(preflight: prepared.preflight)
                    throw GitHubProjectsError.driftDetected
                }
                if prepared.preflight.risk.requiresConfirmation {
                    pendingPreflight = prepared.preflight
                    moveState = .awaitingConfirmation
                } else {
                    await execute(
                        prepared.preflight,
                        policy: policy,
                        credential: credential,
                        generation: generation
                    )
                }
            } catch {
                if authorizationGeneration == generation {
                    publishMoveFailure(error)
                }
            }
            if authorizationGeneration == generation {
                moveTask = nil
            }
        }
    }

    /// Revokes a pending one-use proof when the user declines the move.
    func cancelPendingMove() {
        guard moveState == .awaitingConfirmation else { return }
        cancelPendingPreflight()
        moveState = .idle
    }

    /// Applies the pending move only while the exact policy remains unchanged.
    func confirmPendingMove() {
        guard moveTask == nil,
              moveState == .awaitingConfirmation,
              let preflight = pendingPreflight,
              let policy = preferences.policy,
              policy.digest == preflight.policyDigest else {
            cancelPendingMove()
            return
        }
        pendingPreflight = nil
        let generation = authorizationGeneration
        moveState = .executing
        moveTask = Task { [credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .write)
                await execute(
                    preflight,
                    policy: policy,
                    credential: credential,
                    generation: generation
                )
            } catch {
                if authorizationGeneration == generation {
                    publishMoveFailure(error)
                }
            }
            if authorizationGeneration == generation {
                moveTask = nil
            }
        }
    }

    /// Re-fetches an uncertain target and classifies its exact source or destination value.
    func verifyAmbiguousMove() {
        guard moveTask == nil,
              moveState == .ambiguous,
              let ambiguousMove else { return }
        let generation = authorizationGeneration
        moveTask = Task { [client, credentialCoordinator] in
            do {
                let credential = try await credentialCoordinator.credential(for: .readOnly)
                let refreshed = try await client.fetchSnapshot(
                    organizationLogin: ambiguousMove.preflight.intent.organizationLogin,
                    projectID: ambiguousMove.preflight.intent.projectID,
                    token: credential.accessToken
                )
                try Task.checkCancellation()
                guard authorizationGeneration == generation else { return }
                publish(refreshed)
                let intent = ambiguousMove.preflight.intent
                guard refreshed.coverage.isComplete,
                      refreshed.fields.contains(where: { $0.id == intent.fieldID }),
                      let item = refreshed.items.first(where: { $0.id == intent.itemID }),
                      item.fieldValuesComplete else {
                    moveState = .ambiguous
                    moveTask = nil
                    return
                }
                let optionID = item.singleSelectValue(
                    fieldID: intent.fieldID
                )?.optionID
                if optionID == intent.destinationOptionID {
                    moveState = .succeeded(String(localized: "Project move verified on GitHub"))
                    replaceAmbiguousMove(nil)
                } else if optionID == ambiguousMove.preflight.sourceOptionID {
                    moveState = .failed(String(localized: "GitHub did not apply the Project move."))
                    replaceAmbiguousMove(nil)
                } else {
                    moveState = .drifted
                    replaceAmbiguousMove(nil)
                }
            } catch {
                if authorizationGeneration == generation {
                    moveState = .ambiguous
                    snapshotState = .failed(Self.safeMessage(for: error))
                }
            }
            if authorizationGeneration == generation {
                moveTask = nil
            }
        }
    }

    /// Clears a terminal action notice without changing verified Project data.
    func clearMoveNotice() {
        guard moveState.allowsNewMove else { return }
        moveState = .idle
    }

    /// Executes one issued preflight and publishes only the verified post-write snapshot.
    private func execute(
        _ preflight: GitHubProjectMovePreflight,
        policy: GitHubProjectDriftPolicy,
        credential: GitHubCredential,
        generation: UUID
    ) async {
        guard authorizationGeneration == generation, !Task.isCancelled else {
            await client.discard(preflight: preflight)
            return
        }
        moveState = .executing
        replaceAmbiguousMove(AmbiguousMove(preflight: preflight))
        do {
            let result = try await client.applyMove(
                credential: credential,
                preflight: preflight,
                policy: policy
            )
            guard authorizationGeneration == generation else { return }
            publish(result.snapshot)
            replaceAmbiguousMove(nil)
            moveState = .succeeded(String(localized: "Project move verified on GitHub"))
        } catch {
            guard authorizationGeneration == generation else { return }
            if error as? GitHubProjectsError == .ambiguousWrite {
                replaceAmbiguousMove(AmbiguousMove(preflight: preflight))
                moveState = .ambiguous
            } else {
                replaceAmbiguousMove(nil)
                publishMoveFailure(error)
            }
        }
    }

    /// Installs one provider snapshot and derives all local representations from it.
    private func publish(_ refreshed: GitHubProjectSnapshot) {
        snapshot = refreshed
        if refreshed.coverage.fieldsComplete,
           let fieldID = preferences.selectedFieldID,
           !refreshed.fields.contains(where: { $0.id == fieldID }) {
            preferences.selectedFieldID = nil
            preferences.policy = nil
        }
        if preferences.selectedFieldID == nil, let firstField = refreshed.fields.first {
            preferences.selectedFieldID = firstField.id
            preferences.policy = .empty(projectID: refreshed.project.id, fieldID: firstField.id)
        }
        if projectList?.isTruncated == true,
           projectList?.organization == refreshed.organization,
           projectList?.projects.contains(where: { $0.id == refreshed.project.id }) == false {
            projectList = GitHubProjectList(
                organization: refreshed.organization,
                projects: (projectList?.projects ?? []) + [refreshed.project],
                isTruncated: true
            )
        }
        persistPreferences()
        rebuildProjection()
    }

    /// Clears every provider and mutation reference to a Project removed during rediscovery.
    private func clearRemovedProjectContext() {
        cancelPendingPreflight()
        moveTask?.cancel()
        moveTask = nil
        replaceAmbiguousMove(nil)
        preferences.selectedProjectID = nil
        preferences.selectedFieldID = nil
        preferences.policy = nil
        snapshot = nil
        assessment = nil
        projection = nil
        snapshotState = .idle
        moveState = .idle
        persistPreferences()
    }

    /// Derives assessment and view rows from current in-memory provider evidence.
    private func rebuildProjection() {
        guard let snapshot,
              let fieldID = preferences.selectedFieldID,
              let policy = preferences.policy else {
            assessment = nil
            projection = nil
            return
        }
        let assessment = analyzer.assess(snapshot: snapshot, fieldID: fieldID, policy: policy)
        self.assessment = assessment
        projection = GitHubProjectBoardProjection.make(
            snapshot: snapshot,
            fieldID: fieldID,
            assessment: assessment,
            filter: preferences.filter
        )
    }

    /// Revokes and clears any confirmation invalidated by navigation or policy changes.
    private func cancelPendingPreflight() {
        guard let preflight = pendingPreflight else { return }
        pendingPreflight = nil
        Task { [client] in await client.discard(preflight: preflight) }
    }

    /// Classifies failures without exposing provider payloads or credential material.
    private func publishMoveFailure(_ error: Error) {
        if error as? GitHubProjectsError == .driftDetected {
            moveState = .drifted
        } else if error as? GitHubProjectsError == .ambiguousWrite {
            moveState = .ambiguous
        } else {
            moveState = .failed(Self.safeMessage(for: error))
        }
    }

    /// Persists only the documented local preference envelope.
    private func persistPreferences() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.setGitHubProjectData(data, forKey: Self.preferencesKey)
    }

    /// Replaces and persists the minimal crash-recovery context for an uncertain write.
    private func replaceAmbiguousMove(_ move: AmbiguousMove?) {
        ambiguousMove = move
        let data = move.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.setGitHubProjectData(data, forKey: Self.ambiguousMoveKey)
    }

    /// Restores a valid preference envelope or starts from empty local context.
    private static func loadPreferences(
        from defaults: any GitHubProjectPreferencesStoring
    ) -> GitHubProjectBoardPreferences {
        guard let data = defaults.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(GitHubProjectBoardPreferences.self, from: data) else {
            return GitHubProjectBoardPreferences()
        }
        return preferences
    }

    /// Restores a valid uncertain-write marker without trusting malformed local data.
    private static func loadAmbiguousMove(
        from defaults: any GitHubProjectPreferencesStoring
    ) -> AmbiguousMove? {
        guard let data = defaults.data(forKey: ambiguousMoveKey),
              !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(AmbiguousMove.self, from: data)
    }

    /// Maps only typed safe errors into user-facing copy.
    private static func safeMessage(for error: Error) -> String {
        if let error = error as? GitHubCredentialCoordinatorError {
            return error.localizedDescription
        }
        if let error = error as? GitHubProjectsError {
            return error.localizedDescription
        }
        return String(localized: "CodingBuddy could not complete the GitHub Projects request.")
    }

    /// Exact mutation retained only until an ambiguous outcome is reconciled.
    private struct AmbiguousMove: Codable {
        /// One-use proof describing source and intended destination.
        let preflight: GitHubProjectMovePreflight
    }
}
