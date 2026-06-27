import Foundation
import Observation

/// Root-owned state for the read-only Agent Context Inspector.
@Observable
final class AgentContextInspectorStore {
    /// UserDefaults key for the last selected repository folder.
    static let repositoryPathKey = "agentContextInspectorRepositoryPath"

    /// Currently selected repository folder, if the user has chosen one.
    private(set) var selectedRepositoryURL: URL?

    /// Latest scanner output in deterministic display order.
    private(set) var items: [AgentContextItem] = []

    /// UserDefaults storage injected by tests.
    @ObservationIgnored private let defaults: UserDefaults

    /// Current background reload, cancelled when a newer reload starts.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// Creates a store and restores the last selected repository path.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Self.repositoryPathKey), !path.isEmpty {
            selectedRepositoryURL = URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    /// Cancels any pending background reload when the store is released.
    deinit {
        reloadTask?.cancel()
    }

    /// Number of actionable warnings, excluding informational signals.
    var problemCount: Int {
        items.flatMap(\.warnings).filter { $0.severity != .info }.count
    }

    /// Persists a new repository folder and reloads scanner output.
    func selectRepository(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        selectedRepositoryURL = standardizedURL
        defaults.set(standardizedURL.path, forKey: Self.repositoryPathKey)
        reload()
    }

    /// Clears the selected repository folder and all scanner output.
    func clearRepository() {
        reloadTask?.cancel()
        selectedRepositoryURL = nil
        items = []
        defaults.removeObject(forKey: Self.repositoryPathKey)
    }

    /// Re-runs deterministic context discovery for the selected repository.
    func reload() {
        reloadTask?.cancel()

        guard let selectedRepositoryURL else {
            items = []
            return
        }

        let scanner = AgentContextScanner(repositoryURL: selectedRepositoryURL)
        reloadTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                scanner.items()
            }.value
            guard !Task.isCancelled else { return }
            self.items = items
        }
    }
}
