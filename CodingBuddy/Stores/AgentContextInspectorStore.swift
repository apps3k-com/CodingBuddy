import Foundation
import Observation

/// Atomically published repository and scan state for the Agent Context Inspector.
nonisolated enum AgentContextInspectorState: Equatable, Sendable {
    /// No repository has been selected.
    case noRepository
    /// The selected repository is undergoing descriptor-bound inspection.
    case loading(URL)
    /// A completed scan and its repository-bound rows.
    case loaded(URL, [AgentContextItem])
    /// Inspection was refused because the repository root was not safe to traverse.
    case refused(URL, AgentContextScanRefusalReason)

    /// Repository represented by this state, if any.
    var repositoryURL: URL? {
        switch self {
        case .noRepository:
            nil
        case let .loading(repositoryURL),
             let .loaded(repositoryURL, _),
             let .refused(repositoryURL, _):
            repositoryURL
        }
    }

    /// Rows that belong to the repository represented by this state.
    var items: [AgentContextItem] {
        guard case let .loaded(_, items) = self else { return [] }
        return items
    }

    /// Coarse phase used by presentation and accessibility focus behavior.
    var phase: AgentContextInspectorPhase {
        switch self {
        case .noRepository:
            .noRepository
        case .loading:
            .loading
        case .loaded:
            .loaded
        case .refused:
            .refused
        }
    }
}

/// Stable presentation phase independent of loaded row contents.
nonisolated enum AgentContextInspectorPhase: Equatable, Sendable {
    /// No repository is selected.
    case noRepository
    /// A repository scan is active.
    case loading
    /// A repository scan completed successfully.
    case loaded
    /// A repository scan was refused for safety.
    case refused
}

/// Root-owned state for the read-only Agent Context Inspector.
@Observable
final class AgentContextInspectorStore {
    /// UserDefaults key for the last selected repository folder.
    static let repositoryPathKey = "agentContextInspectorRepositoryPath"

    /// Atomically published repository selection, loading state, and scanner output.
    private(set) var state: AgentContextInspectorState

    /// UserDefaults storage injected by tests.
    @ObservationIgnored private let defaults: UserDefaults
    /// Injectable asynchronous scan boundary used by deterministic state tests.
    @ObservationIgnored private let scan: @Sendable (URL) async -> AgentContextScanResult

    /// Current background reload, cancelled when a newer reload starts.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Identity of the only reload still permitted to publish state.
    @ObservationIgnored private var reloadRequestID: UUID?

    /// Creates a store and restores the last selected repository path.
    init(
        defaults: UserDefaults = .standard,
        scan: @escaping @Sendable (URL) async -> AgentContextScanResult = { repositoryURL in
            await Task.detached(priority: .userInitiated) {
                AgentContextScanner(repositoryURL: repositoryURL).scan()
            }.value
        }
    ) {
        self.defaults = defaults
        self.scan = scan
        if let path = defaults.string(forKey: Self.repositoryPathKey), !path.isEmpty {
            state = .loading(URL(fileURLWithPath: path).standardizedFileURL)
        } else {
            state = .noRepository
        }
    }

    /// Cancels any pending background reload when the store is released.
    deinit {
        reloadTask?.cancel()
    }

    /// Currently selected repository folder, derived from the atomic state.
    var selectedRepositoryURL: URL? { state.repositoryURL }

    /// Latest scanner output, empty unless the represented repository is fully loaded.
    var items: [AgentContextItem] { state.items }

    /// Number of actionable warnings, counting repo-wide signals once.
    var problemCount: Int {
        if case .refused = state { return 1 }

        var count = 0
        var countedGovernanceConflict = false

        for warning in items.flatMap(\.warnings) {
            guard warning.severity != .info else { continue }

            if warning == .bothGovernanceFilesPresent {
                guard !countedGovernanceConflict else { continue }
                countedGovernanceConflict = true
            }

            count += 1
        }

        return count
    }

    /// Persists a new repository folder and reloads scanner output.
    func selectRepository(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        defaults.set(standardizedURL.path, forKey: Self.repositoryPathKey)
        startReload(for: standardizedURL)
    }

    /// Clears the selected repository folder and all scanner output.
    func clearRepository() {
        reloadTask?.cancel()
        reloadRequestID = nil
        state = .noRepository
        defaults.removeObject(forKey: Self.repositoryPathKey)
    }

    /// Re-runs deterministic context discovery for the selected repository.
    func reload() {
        guard let selectedRepositoryURL else {
            state = .noRepository
            return
        }
        startReload(for: selectedRepositoryURL)
    }

    /// Starts one repository-bound reload and rejects all older asynchronous results.
    private func startReload(for repositoryURL: URL) {
        reloadTask?.cancel()
        let requestID = UUID()
        reloadRequestID = requestID
        state = .loading(repositoryURL)
        let scanOperation = scan

        reloadTask = Task { [weak self, scanOperation] in
            let result = await scanOperation(repositoryURL)
            guard let self,
                  !Task.isCancelled,
                  reloadRequestID == requestID,
                  selectedRepositoryURL == repositoryURL
            else { return }

            switch result {
            case let .loaded(items):
                state = .loaded(repositoryURL, items)
            case let .refused(reason):
                state = .refused(repositoryURL, reason)
            }
        }
    }
}
