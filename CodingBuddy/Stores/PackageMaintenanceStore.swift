//
//  PackageMaintenanceStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Table filter for global package inventory.
nonisolated enum PackageInventoryFilter: String, CaseIterable, Sendable {
    case updates
    case direct
    case all

    var displayName: String {
        switch self {
        case .updates: String(localized: "Updates")
        case .direct: String(localized: "Direct")
        case .all: String(localized: "All")
        }
    }
}

/// Loading and update state for Software Updates.
nonisolated enum PackageMaintenanceState: Equatable, Sendable {
    case idle
    case loading
    case preparing
    case loaded
    case updating
}

/// Release-note state loaded only for the selected package.
nonisolated enum PackageReleaseNotesState: Equatable, Sendable {
    case idle
    case loading
    case loaded(PackageReleaseNotes)
    case unavailable
}

/// Observable coordinator for package inventory, confirmation, and sequential updates.
@Observable
final class PackageMaintenanceStore {
    private(set) var snapshots: [PackageManagerKind: ProviderSnapshot] = [:]
    private(set) var issues: [PackageProviderIssue] = []
    private(set) var state = PackageMaintenanceState.idle
    private(set) var updateEvents: [PackageUpdateEvent] = []
    private(set) var releaseNotesState = PackageReleaseNotesState.idle
    var selection = Set<InstalledPackage.ID>()
    var filter = PackageInventoryFilter.updates
    var updateMode = PackageUpdateMode.compatible
    var searchText = ""
    var pendingPlan: PackageUpdatePlan?
    var lastError: String?

    @ObservationIgnored private let service: PackageMaintenanceService
    @ObservationIgnored private let runner: any CommandRunning
    @ObservationIgnored private let releaseNotesProvider: any ReleaseNotesProviding
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var releaseNotesTask: Task<Void, Never>?

    init(
        service: PackageMaintenanceService = PackageMaintenanceService(),
        runner: any CommandRunning = FoundationCommandRunner(),
        releaseNotesProvider: any ReleaseNotesProviding = GitHubPackageReleaseNotesProvider()
    ) {
        self.service = service
        self.runner = runner
        self.releaseNotesProvider = releaseNotesProvider
    }

    deinit {
        reloadTask?.cancel()
        updateTask?.cancel()
        planTask?.cancel()
        releaseNotesTask?.cancel()
    }

    var packages: [InstalledPackage] {
        snapshots.values
            .flatMap(\.packages)
            .sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var filteredPackages: [InstalledPackage] {
        packages.filter { package in
            let matchesFilter = switch filter {
            case .updates: package.isUpdateAvailable(for: updateMode)
            case .direct: package.isDirect
            case .all: true
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesFilter && (query.isEmpty
                || package.name.localizedCaseInsensitiveContains(query)
                || package.manager.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var updateCount: Int { packages.filter { $0.isUpdateAvailable(for: updateMode) }.count }
    var isUpdating: Bool { state == .updating }
    var isPreparing: Bool { state == .preparing }

    func reload() {
        guard !isUpdating, !isPreparing else { return }
        reloadTask?.cancel()
        state = .loading
        let service = service
        reloadTask = Task {
            let result = await service.scan()
            guard !Task.isCancelled else { return }
            for snapshot in result.snapshots { snapshots[snapshot.installation.manager] = snapshot }
            issues = result.issues
            selection.formIntersection(Set(packages.map(\.id)))
            state = .loaded
        }
    }

    func prepareUpdatePlan() {
        do {
            let selected = packages.filter { selection.contains($0.id) && $0.isUpdateAvailable(for: updateMode) }
            guard !selected.isEmpty else { return }
            let plan = try service.plan(packages: selected, mode: updateMode)
            lastError = nil
            state = .preparing
            let runner = runner
            planTask?.cancel()
            planTask = Task {
                do {
                    for item in plan.items {
                        if let preview = item.previewCommand { _ = try await runner.run(preview) }
                    }
                    guard !Task.isCancelled else { return }
                    pendingPlan = plan
                    state = .loaded
                } catch {
                    lastError = error.localizedDescription
                    state = .loaded
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func confirmPendingPlan() {
        guard let plan = pendingPlan, !plan.items.isEmpty else { return }
        pendingPlan = nil
        updateTask?.cancel()
        state = .updating
        updateEvents = plan.items.map {
            PackageUpdateEvent(packageID: $0.id, packageName: $0.package.name, state: .queued, message: "")
        }
        let runner = runner
        updateTask = Task {
            for item in plan.items {
                if Task.isCancelled {
                    markRemainingCancelled()
                    break
                }
                setEvent(item.id, state: .running, message: String(localized: "Updating…"))
                do {
                    _ = try await runner.run(item.command)
                    setEvent(
                        item.id,
                        state: .succeeded,
                        message: String(
                            format: String(localized: "Updated from %@ to %@."),
                            item.package.installedVersion,
                            item.targetVersion
                        )
                    )
                } catch {
                    let state: PackageUpdateEventState = Task.isCancelled ? .cancelled : .failed
                    setEvent(item.id, state: state, message: error.localizedDescription)
                    if Task.isCancelled {
                        markRemainingCancelled()
                        break
                    }
                }
            }
            state = .loaded
            selection.removeAll()
            reload()
        }
    }

    func cancelUpdates() {
        updateTask?.cancel()
    }

    func loadReleaseNotes(for package: InstalledPackage) {
        releaseNotesTask?.cancel()
        guard let target = package.targetVersion(for: updateMode) else {
            releaseNotesState = .unavailable
            return
        }
        releaseNotesState = .loading
        let provider = releaseNotesProvider
        releaseNotesTask = Task {
            let notes = await provider.releaseNotes(for: package, targetVersion: target)
            guard !Task.isCancelled else { return }
            releaseNotesState = notes.map(PackageReleaseNotesState.loaded) ?? .unavailable
        }
    }

    func clearReleaseNotes() {
        releaseNotesTask?.cancel()
        releaseNotesState = .idle
    }

    private func setEvent(_ id: String, state: PackageUpdateEventState, message: String) {
        guard let index = updateEvents.firstIndex(where: { $0.id == id }) else { return }
        updateEvents[index].state = state
        updateEvents[index].message = message
    }

    private func markRemainingCancelled() {
        for index in updateEvents.indices where updateEvents[index].state == .queued {
            updateEvents[index].state = .cancelled
            updateEvents[index].message = String(localized: "Not started")
        }
    }
}
