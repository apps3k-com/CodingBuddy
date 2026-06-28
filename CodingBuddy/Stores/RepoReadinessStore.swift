import Foundation
import Observation

/// Minimal key-value storage used to persist the selected Repo Readiness folder.
protocol RepoReadinessDefaultsStoring: AnyObject {
    /// Returns a stored string for the given key.
    func string(forKey defaultName: String) -> String?

    /// Stores a string for the given key.
    func setRepoReadinessString(_ value: String, forKey defaultName: String)

    /// Removes a stored value for the given key.
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: RepoReadinessDefaultsStoring {
    /// Stores a string for the given key.
    func setRepoReadinessString(_ value: String, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}

/// Root-owned state for the read-only Repo Readiness checklist.
@Observable
final class RepoReadinessStore {
    /// UserDefaults key for the last selected repository folder.
    static let repositoryPathKey = "repoReadinessRepositoryPath"

    /// Currently selected repository folder, if the user has chosen one.
    private(set) var selectedRepositoryURL: URL?

    /// Latest scanner output in deterministic display order.
    private(set) var items: [RepoReadinessItem] = []

    /// Key-value storage injected by tests.
    @ObservationIgnored private let defaults: any RepoReadinessDefaultsStoring

    /// Current background reload, cancelled when a newer reload starts.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// Creates a store and restores the last selected repository path.
    init(defaults: any RepoReadinessDefaultsStoring = UserDefaults.standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Self.repositoryPathKey), !path.isEmpty {
            selectedRepositoryURL = URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    /// Cancels any pending background reload when the store is released.
    deinit {
        reloadTask?.cancel()
    }

    /// Number of warning or failure results.
    var problemCount: Int {
        items.filter(\.isProblem).count
    }

    /// Persists a new repository folder and reloads scanner output.
    func selectRepository(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        selectedRepositoryURL = standardizedURL
        items = []
        defaults.setRepoReadinessString(standardizedURL.path, forKey: Self.repositoryPathKey)
        reload()
    }

    /// Clears the selected repository folder and all scanner output.
    func clearRepository() {
        reloadTask?.cancel()
        selectedRepositoryURL = nil
        items = []
        defaults.removeObject(forKey: Self.repositoryPathKey)
    }

    /// Re-runs deterministic readiness checks for the selected repository.
    func reload() {
        reloadTask?.cancel()

        guard let selectedRepositoryURL else {
            items = []
            return
        }

        let scanner = RepoReadinessScanner(repositoryURL: selectedRepositoryURL)
        reloadTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                scanner.items()
            }.value
            guard !Task.isCancelled else { return }
            self.items = items
        }
    }
}
