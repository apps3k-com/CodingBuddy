//
//  AgentPRMonitorStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Minimal key-value storage for Agent PR Monitor repository selection.
protocol AgentPRMonitorDefaultsStoring: AnyObject {
    /// Returns a stored string for the given key.
    func string(forKey defaultName: String) -> String?

    /// Stores a string for the given key.
    func setAgentPRMonitorString(_ value: String, forKey defaultName: String)

    /// Removes a stored value for the given key.
    func removeObject(forKey defaultName: String)
}

/// Production persistence backend for the selected Agent PR Monitor repository.
extension UserDefaults: AgentPRMonitorDefaultsStoring {
    /// Stores a string for the given key.
    func setAgentPRMonitorString(_ value: String, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}

/// User-facing refresh state for the Agent PR Monitor.
nonisolated enum AgentPRMonitorState: Equatable, Sendable {
    /// The view has not refreshed yet.
    case idle
    /// No GitHub token is available.
    case needsToken
    /// No repository has been selected.
    case needsRepository
    /// A refresh is currently running.
    case loading
    /// Rows are loaded and visible.
    case loaded
    /// The selected repository has no matching open PRs.
    case empty
    /// GitHub rate limit prevents refresh until a reset time.
    case rateLimited(Date?)
    /// Refresh failed while the previous snapshot, if any, remains visible.
    case refreshFailed(GitHubClientError)
}

/// User-facing load state for the repository picker.
nonisolated enum AgentPRRepositoryPickerState: Equatable, Sendable {
    /// The picker has not loaded repositories yet.
    case idle
    /// Repository choices are currently loading.
    case loading
    /// Repository choices are available.
    case loaded
    /// GitHub returned no accessible repositories.
    case empty
    /// Loading repository choices failed.
    case failed(GitHubClientError)
}

/// Root-owned state for the read-only Agent PR Monitor.
@Observable
final class AgentPRMonitorStore: CustomDebugStringConvertible {
    /// UserDefaults key for the selected repository string.
    static let repositoryKey = "agentPRMonitorRepository"

    /// Currently selected repository.
    private(set) var selectedRepository: GitHubRepositoryRef?

    /// Latest visible pull request rows.
    private(set) var rows: [AgentPullRequest] = []

    /// Latest view state.
    private(set) var state: AgentPRMonitorState = .idle

    /// Latest rate-limit metadata returned by GitHub.
    private(set) var rateLimit: GitHubRateLimitState?

    /// Repositories visible to the saved token for setup selection.
    private(set) var repositoryChoices: [GitHubRepositorySummary] = []

    /// Latest repository picker state.
    private(set) var repositoryPickerState: AgentPRRepositoryPickerState = .idle

    /// Whether the repository picker stopped early at the configured pagination cap.
    private(set) var repositoryChoicesAreTruncated = false

    /// Latest rate-limit metadata returned while loading repository choices.
    private(set) var repositoryPickerRateLimit: GitHubRateLimitState?

    /// Whether a refresh request is currently running.
    private(set) var isRefreshing = false

    /// Token persistence used for setup actions.
    @ObservationIgnored private let tokenStore: any GitHubTokenStore

    /// GitHub fetcher injected for tests.
    @ObservationIgnored private let client: any AgentPRMonitorFetching

    /// Key-value storage injected for tests.
    @ObservationIgnored private let defaults: any AgentPRMonitorDefaultsStoring

    /// Current refresh task, cancelled when a newer refresh starts.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Current repository-list task, cancelled when a newer load starts.
    @ObservationIgnored private var repositoryListTask: Task<Void, Never>?

    /// Creates the monitor store and restores the last selected repository.
    init(
        tokenStore: any GitHubTokenStore = KeychainGitHubTokenStore(),
        client: (any AgentPRMonitorFetching)? = nil,
        defaults: any AgentPRMonitorDefaultsStoring = UserDefaults.standard
    ) {
        self.tokenStore = tokenStore
        self.client = client ?? GitHubClient(tokenStore: tokenStore)
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.repositoryKey) {
            selectedRepository = GitHubRepositoryRef(displayName: saved)
        }
    }

    /// Cancels any pending refresh when the store is released.
    deinit {
        refreshTask?.cancel()
        repositoryListTask?.cancel()
    }

    /// Count of rows that currently need attention.
    var attentionCount: Int {
        rows.filter { $0.readiness.state == .attentionNeeded || $0.readiness.state == .blocked }.count
    }

    /// Debug text intentionally omits any token value.
    var debugDescription: String {
        "AgentPRMonitorStore(repository: \(selectedRepository?.displayName ?? "nil"), rows: \(rows.count), state: \(state))"
    }

    /// Persists a selected repository and clears stale rows.
    func selectRepository(_ repository: GitHubRepositoryRef) {
        refreshTask?.cancel()
        selectedRepository = repository
        defaults.setAgentPRMonitorString(repository.displayName, forKey: Self.repositoryKey)
        rows = []
        rateLimit = nil
        isRefreshing = false
        state = .idle
    }

    /// Clears repository selection and rows.
    func clearRepository() {
        refreshTask?.cancel()
        selectedRepository = nil
        rows = []
        rateLimit = nil
        state = .needsRepository
        isRefreshing = false
        defaults.removeObject(forKey: Self.repositoryKey)
    }

    /// Loads repositories visible to the saved token for the picker sheet.
    func loadRepositoryChoices(force: Bool = false) {
        if !force {
            switch repositoryPickerState {
            case .loading, .loaded, .empty:
                return
            case .idle, .failed:
                break
            }
        }

        repositoryListTask?.cancel()
        repositoryPickerState = .loading
        repositoryChoicesAreTruncated = false

        let client = client
        repositoryListTask = Task { [weak self, client] in
            do {
                let list = try await client.fetchAccessibleRepositories()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.repositoryChoices = list.repositories
                self.repositoryPickerRateLimit = list.rateLimit
                self.repositoryChoicesAreTruncated = list.isTruncated
                self.repositoryPickerState = list.repositories.isEmpty ? .empty : .loaded
            } catch let error as GitHubClientError {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.repositoryPickerRateLimit = nil
                self.repositoryChoicesAreTruncated = false
                self.repositoryPickerState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.repositoryPickerRateLimit = nil
                self.repositoryChoicesAreTruncated = false
                self.repositoryPickerState = .failed(.networkUnavailable)
            }
        }
    }

    /// Saves a replacement token through the injected token store.
    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return false
        }

        do {
            try tokenStore.saveToken(trimmedToken)
            handleGitHubAuthorizationChange(.saved)
            return true
        } catch {
            state = .refreshFailed(.tokenStorageFailed)
            return false
        }
    }

    /// Removes the saved token through the injected token store.
    func deleteToken() {
        refreshTask?.cancel()
        do {
            try tokenStore.deleteToken()
            handleGitHubAuthorizationChange(.removed)
        } catch {
            isRefreshing = false
            state = .refreshFailed(.tokenStorageFailed)
        }
    }

    /// Reacts to token changes made outside the monitor, such as in Settings.
    func handleGitHubAuthorizationChange(_ change: GitHubAuthorizationChange) {
        resetRepositoryChoices()
        switch change {
        case .saved:
            if selectedRepository != nil {
                refresh()
            } else {
                state = .needsRepository
            }
        case .removed:
            refreshTask?.cancel()
            rows = []
            rateLimit = nil
            isRefreshing = false
            state = .needsToken
        }
    }

    /// Clears cached repository choices when token state changes.
    private func resetRepositoryChoices() {
        repositoryListTask?.cancel()
        repositoryChoices = []
        repositoryPickerRateLimit = nil
        repositoryChoicesAreTruncated = false
        repositoryPickerState = .idle
    }

    /// Refreshes the selected repository while preserving the last snapshot on failure.
    func refresh() {
        refreshTask?.cancel()

        guard let selectedRepository else {
            state = .needsRepository
            isRefreshing = false
            return
        }

        isRefreshing = true
        state = rows.isEmpty ? .loading : state

        let client = client
        refreshTask = Task { [weak self, selectedRepository, client] in
            do {
                let snapshot = try await client.fetchOpenPullRequests(repository: selectedRepository)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.rows = snapshot.rows
                self.rateLimit = snapshot.rateLimit
                self.state = snapshot.rows.isEmpty ? .empty : .loaded
                self.isRefreshing = false
            } catch let error as GitHubClientError {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                switch error {
                case .noToken:
                    self.state = .needsToken
                case .rateLimited(let resetAt):
                    self.state = .rateLimited(resetAt)
                default:
                    self.state = .refreshFailed(error)
                }
                self.isRefreshing = false
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.state = .refreshFailed(.networkUnavailable)
                self.isRefreshing = false
            }
        }
    }
}
