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
        selectedRepository = repository
        defaults.setAgentPRMonitorString(repository.displayName, forKey: Self.repositoryKey)
        rows = []
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

    /// Saves a replacement token through the injected token store.
    func saveToken(_ token: String) {
        do {
            try tokenStore.saveToken(token)
            if selectedRepository != nil {
                refresh()
            } else if case .needsToken = state {
                state = selectedRepository == nil ? .needsRepository : .idle
            }
        } catch {
            state = .refreshFailed(.tokenStorageFailed)
        }
    }

    /// Removes the saved token through the injected token store.
    func deleteToken() {
        do {
            try tokenStore.deleteToken()
            state = .needsToken
        } catch {
            state = .refreshFailed(.tokenStorageFailed)
        }
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
        refreshTask = Task {
            do {
                let snapshot = try await client.fetchOpenPullRequests(repository: selectedRepository)
                guard !Task.isCancelled else { return }
                rows = snapshot.rows
                rateLimit = snapshot.rateLimit
                state = snapshot.rows.isEmpty ? .empty : .loaded
                isRefreshing = false
            } catch let error as GitHubClientError {
                guard !Task.isCancelled else { return }
                switch error {
                case .noToken:
                    state = .needsToken
                case .rateLimited(let resetAt):
                    state = .rateLimited(resetAt)
                default:
                    state = .refreshFailed(error)
                }
                isRefreshing = false
            } catch {
                guard !Task.isCancelled else { return }
                state = .refreshFailed(.networkUnavailable)
                isRefreshing = false
            }
        }
    }
}
