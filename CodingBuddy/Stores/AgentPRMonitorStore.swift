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

/// Trust state for the aggregate multi-repository pull request queue.
nonisolated enum AgentPRMonitorQueueCoverage: Equatable, Sendable {
    /// No repository watchlist exists yet.
    case notConfigured
    /// A refresh is running while an older completion time may remain visible.
    case refreshing(previouslyCompletedAt: Date?)
    /// Every watched repository produced a known result in the latest refresh.
    case complete(completedAt: Date)
    /// Cached rows remain visible but one or more repositories are not current.
    case partial(completedAt: Date?, repositories: [GitHubRepositoryRef])
    /// No trustworthy queue exists and the listed repositories could not be loaded.
    case unavailable(repositories: [GitHubRepositoryRef])
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
    /// UserDefaults key for the newline-delimited watched repository list.
    static let watchedRepositoriesKey = "agentPRMonitorRepositories"

    /// Currently selected repository.
    private(set) var selectedRepository: GitHubRepositoryRef?
    /// Repositories currently watched by the monitor.
    private(set) var watchedRepositories: [GitHubRepositoryRef] = []

    /// Latest visible pull request rows.
    private(set) var rows: [AgentPullRequest] = []

    /// Latest view state.
    private(set) var state: AgentPRMonitorState = .idle
    /// Latest refresh state per watched repository.
    private(set) var repositoryRefreshStates: [GitHubRepositoryRef: AgentPRMonitorState] = [:]
    /// Latest successful refresh completion per watched repository.
    private(set) var repositoryLastSuccessfulRefreshAt: [GitHubRepositoryRef: Date] = [:]

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
    /// Completion time of the latest refresh that loaded at least one watched repository.
    private(set) var lastRefreshCompletedAt: Date?

    /// Token persistence used for setup actions.
    @ObservationIgnored private let tokenStore: any GitHubTokenStore

    /// GitHub fetcher injected for tests.
    @ObservationIgnored private let client: any AgentPRMonitorFetching

    /// Key-value storage injected for tests.
    @ObservationIgnored private let defaults: any AgentPRMonitorDefaultsStoring

    /// Current refresh task, cancelled when a newer refresh starts.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Last successful pull request snapshot per repository.
    @ObservationIgnored private var repositorySnapshots: [GitHubRepositoryRef: [AgentPullRequest]] = [:]

    /// Current repository-list task, cancelled when a newer load starts.
    @ObservationIgnored private var repositoryListTask: Task<Void, Never>?

    /// Creates the monitor store and restores the last selected repository.
    init(
        tokenStore: any GitHubTokenStore = KeychainGitHubTokenStore(),
        credentialCoordinator: GitHubCredentialCoordinator? = nil,
        client: (any AgentPRMonitorFetching)? = nil,
        defaults: any AgentPRMonitorDefaultsStoring = UserDefaults.standard
    ) {
        self.tokenStore = tokenStore
        self.client = client ?? GitHubClient(
            credentialCoordinator: credentialCoordinator
                ?? GitHubCredentialCoordinator(tokenStore: tokenStore)
        )
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.watchedRepositoriesKey) {
            watchedRepositories = Self.repositoryList(from: saved)
        } else if let saved = defaults.string(forKey: Self.repositoryKey),
                  /// Repository restored from the legacy single-watch preference.
                  let repository = GitHubRepositoryRef(displayName: saved) {
            watchedRepositories = [repository]
            persistWatchedRepositories()
        }
        selectedRepository = watchedRepositories.first
        defaults.removeObject(forKey: Self.repositoryKey)
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

    /// Aggregate queue coverage that prevents cached or partial rows from appearing complete.
    var queueCoverage: AgentPRMonitorQueueCoverage {
        guard !watchedRepositories.isEmpty else { return .notConfigured }
        if isRefreshing {
            return .refreshing(previouslyCompletedAt: lastRefreshCompletedAt)
        }
        let incomplete = watchedRepositories.filter { repository in
            switch repositoryRefreshStates[repository] {
            case .loaded?, .empty?: false
            default: true
            }
        }
        if incomplete.isEmpty, let lastRefreshCompletedAt {
            return .complete(completedAt: lastRefreshCompletedAt)
        }
        if !rows.isEmpty || lastRefreshCompletedAt != nil {
            return .partial(completedAt: lastRefreshCompletedAt, repositories: incomplete)
        }
        return .unavailable(repositories: incomplete)
    }

    /// Debug text intentionally omits any token value.
    var debugDescription: String {
        "AgentPRMonitorStore(repository: \(selectedRepository?.displayName ?? "nil"), rows: \(rows.count), state: \(state))"
    }

    /// Persists a selected repository and clears stale rows.
    func selectRepository(_ repository: GitHubRepositoryRef) {
        refreshTask?.cancel()
        selectedRepository = repository
        watchedRepositories = [repository]
        persistWatchedRepositories()
        repositorySnapshots = [:]
        rows = []
        rateLimit = nil
        repositoryRefreshStates = [:]
        repositoryLastSuccessfulRefreshAt = [:]
        lastRefreshCompletedAt = nil
        isRefreshing = false
        state = .idle
    }

    /// Adds a repository to the watchlist without disturbing existing entries.
    func addWatchedRepository(_ repository: GitHubRepositoryRef) {
        guard !watchedRepositories.contains(where: { $0.canonicalID == repository.canonicalID }) else { return }
        let wasEmpty = watchedRepositories.isEmpty
        watchedRepositories.append(repository)
        selectedRepository = selectedRepository ?? repository
        repositoryRefreshStates[repository] = .idle
        if wasEmpty {
            state = .idle
        }
        persistWatchedRepositories()
    }

    /// Removes one repository from the watchlist while keeping the remaining entries.
    func removeWatchedRepository(_ repository: GitHubRepositoryRef) {
        guard watchedRepositories.contains(where: { $0.canonicalID == repository.canonicalID }) else { return }
        let wasRefreshing = isRefreshing
        refreshTask?.cancel()
        watchedRepositories.removeAll { $0.canonicalID == repository.canonicalID }
        if selectedRepository?.canonicalID == repository.canonicalID {
            selectedRepository = watchedRepositories.first
        }
        persistWatchedRepositories()
        repositorySnapshots = repositorySnapshots.filter { $0.key.canonicalID != repository.canonicalID }
        repositoryRefreshStates = repositoryRefreshStates.filter { $0.key.canonicalID != repository.canonicalID }
        repositoryLastSuccessfulRefreshAt = repositoryLastSuccessfulRefreshAt.filter {
            $0.key.canonicalID != repository.canonicalID
        }
        rows = cachedRows(for: watchedRepositories)
        if watchedRepositories.isEmpty {
            rateLimit = nil
            state = .needsRepository
        } else {
            if wasRefreshing {
                for remainingRepository in watchedRepositories
                where repositoryRefreshStates[remainingRepository] == .loading {
                    repositoryRefreshStates[remainingRepository] = rows.contains { $0.repository == remainingRepository }
                        ? .loaded
                        : .idle
                }
            }
            if rows.isEmpty, state == .loaded || state == .loading {
                state = .empty
            } else if !rows.isEmpty, state == .loading {
                state = .loaded
            }
        }
        isRefreshing = false
    }

    /// Clears repository selection and rows.
    func clearRepository() {
        refreshTask?.cancel()
        selectedRepository = nil
        watchedRepositories = []
        repositorySnapshots = [:]
        rows = []
        rateLimit = nil
        repositoryRefreshStates = [:]
        repositoryLastSuccessfulRefreshAt = [:]
        lastRefreshCompletedAt = nil
        state = .needsRepository
        isRefreshing = false
        defaults.removeObject(forKey: Self.repositoryKey)
        defaults.removeObject(forKey: Self.watchedRepositoriesKey)
    }

    /// Converts stored repository text into ordered unique references.
    private static func repositoryList(from storageValue: String) -> [GitHubRepositoryRef] {
        var seen = Set<String>()
        return storageValue
            .split(whereSeparator: \.isNewline)
            .compactMap { GitHubRepositoryRef(displayName: String($0)) }
            .filter { seen.insert($0.canonicalID).inserted }
    }

    /// Persists the watchlist using one owner/name reference per line.
    private func persistWatchedRepositories() {
        defaults.removeObject(forKey: Self.repositoryKey)
        guard !watchedRepositories.isEmpty else {
            defaults.removeObject(forKey: Self.watchedRepositoriesKey)
            return
        }
        let value = watchedRepositories
            .map(\.displayName)
            .joined(separator: "\n")
        defaults.setAgentPRMonitorString(value, forKey: Self.watchedRepositoriesKey)
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
            repositorySnapshots = [:]
            repositoryRefreshStates = [:]
            repositoryLastSuccessfulRefreshAt = [:]
            rows = []
            rateLimit = nil
            lastRefreshCompletedAt = nil
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

        let repositories = watchedRepositories.isEmpty ? [selectedRepository] : watchedRepositories
        isRefreshing = true
        state = rows.isEmpty ? .loading : state
        for repository in repositories {
            repositoryRefreshStates[repository] = .loading
        }

        let client = client
        refreshTask = Task { [weak self, repositories, client] in
            var refreshedSnapshots: [GitHubRepositoryRef: [AgentPullRequest]] = [:]
            var latestRateLimit: GitHubRateLimitState?
            var repositoryStates: [GitHubRepositoryRef: AgentPRMonitorState] = [:]
            var failures: [GitHubClientError] = []

            for repository in repositories {
                do {
                    let snapshot = try await client.fetchOpenPullRequests(repository: repository)
                    try Task.checkCancellation()
                    refreshedSnapshots[repository] = snapshot.rows
                    latestRateLimit = snapshot.rateLimit ?? latestRateLimit
                    repositoryStates[repository] = snapshot.rows.isEmpty ? .empty : .loaded
                } catch let error as GitHubClientError {
                    guard !Task.isCancelled else { return }
                    failures.append(error)
                    switch error {
                    case .noToken:
                        repositoryStates[repository] = .needsToken
                    case .rateLimited(let resetAt):
                        repositoryStates[repository] = .rateLimited(resetAt)
                    default:
                        repositoryStates[repository] = .refreshFailed(error)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    failures.append(.networkUnavailable)
                    repositoryStates[repository] = .refreshFailed(.networkUnavailable)
                }
            }

            guard !Task.isCancelled else { return }
            guard let self else { return }
            for (repository, rows) in refreshedSnapshots {
                self.repositorySnapshots[repository] = rows
                self.repositoryLastSuccessfulRefreshAt[repository] = Date()
            }
            if !refreshedSnapshots.isEmpty {
                self.lastRefreshCompletedAt = Date()
            }
            let visibleRows = self.cachedRows(for: repositories)
            self.repositoryRefreshStates = repositoryStates
            if failures.count < repositories.count {
                self.rows = visibleRows
                self.rateLimit = latestRateLimit
                self.state = visibleRows.isEmpty ? .empty : .loaded
            } else if let failure = failures.first {
                switch failure {
                case .noToken:
                    self.state = .needsToken
                case .rateLimited(let resetAt):
                    self.state = .rateLimited(resetAt)
                default:
                    self.state = .refreshFailed(failure)
                }
            }
            self.isRefreshing = false
        }
    }

    /// Returns the latest cached rows in watchlist order.
    private func cachedRows(for repositories: [GitHubRepositoryRef]) -> [AgentPullRequest] {
        repositories.flatMap { repositorySnapshots[$0] ?? [] }
    }
}
