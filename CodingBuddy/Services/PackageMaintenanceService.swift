//
//  PackageMaintenanceService.swift
//  CodingBuddy
//

import Foundation

/// Aggregate result that keeps successful providers separate from failures.
nonisolated struct PackageMaintenanceScanResult: Sendable {
    /// Successful provider snapshots, sorted by package-manager identifier.
    let snapshots: [ProviderSnapshot]
    /// User-safe provider failures, sorted by package-manager identifier.
    let issues: [PackageProviderIssue]
}

/// Coordinates executable discovery, provider scans, and exact update plans.
nonisolated struct PackageMaintenanceService: Sendable {
    /// Package-manager adapters participating in scans and update planning.
    let providers: [any PackageProvider]
    /// Locator used to bind each provider to a concrete executable installation.
    let locator: any ExecutableLocating

    /// Creates the coordinator with injectable providers and executable discovery.
    init(
        providers: [any PackageProvider] = [
            HomebrewPackageProvider(),
            NPMPackageProvider(),
            PNPMPackageProvider(),
        ],
        locator: any ExecutableLocating = PackageExecutableLocator()
    ) {
        self.providers = providers
        self.locator = locator
    }

    /// Scans all providers concurrently while preserving successful results when others fail.
    func scan() async -> PackageMaintenanceScanResult {
        await withTaskGroup(of: ScanOutcome.self) { group in
            for provider in providers {
                guard let installation = locator.installation(for: provider.manager) else {
                    group.addTask {
                        .failure(PackageProviderIssue(
                            manager: provider.manager,
                            message: String(
                                format: String(localized: "%@ was not found. Choose its executable in Settings."),
                                provider.manager.displayName
                            )
                        ))
                    }
                    continue
                }
                group.addTask {
                    do {
                        return .success(try await provider.scan(installation: installation))
                    } catch {
                        return .failure(PackageProviderIssue(
                            manager: provider.manager,
                            message: error.localizedDescription
                        ))
                    }
                }
            }

            var snapshots: [ProviderSnapshot] = []
            var issues: [PackageProviderIssue] = []
            for await outcome in group {
                switch outcome {
                case .success(let snapshot): snapshots.append(snapshot)
                case .failure(let issue): issues.append(issue)
                }
            }
            return PackageMaintenanceScanResult(
                snapshots: snapshots.sorted { $0.installation.manager.rawValue < $1.installation.manager.rawValue },
                issues: issues.sorted { $0.manager.rawValue < $1.manager.rawValue }
            )
        }
    }

    /// Builds deterministic preview and update commands for packages with exact, valid targets.
    func plan(packages: [InstalledPackage], mode: PackageUpdateMode) throws -> PackageUpdatePlan {
        let providersByManager = Dictionary(uniqueKeysWithValues: providers.map { ($0.manager, $0) })
        let items = try packages.map { package -> PackageUpdatePlanItem in
            guard package.status.isUpdateAvailable,
                  let target = package.targetVersion(for: mode),
                  target != package.installedVersion,
                  let provider = providersByManager[package.manager],
                  let installation = locator.installation(for: package.manager),
                  installation.id == package.installationID else {
                throw PackageProviderError.unavailableTarget
            }
            return PackageUpdatePlanItem(
                package: package,
                targetVersion: target,
                previewCommand: try provider.previewRequest(
                    for: package,
                    mode: mode,
                    installation: installation
                ),
                command: try provider.updateRequest(
                    for: package,
                    mode: mode,
                    installation: installation
                )
            )
        }
        return PackageUpdatePlan(
            items: items.sorted {
                if $0.package.manager != $1.package.manager {
                    return $0.package.manager.rawValue < $1.package.manager.rawValue
                }
                return $0.package.name.localizedStandardCompare($1.package.name) == .orderedAscending
            },
            mode: mode
        )
    }
}

private enum ScanOutcome: Sendable {
    /// A provider completed with a normalized inventory snapshot.
    case success(ProviderSnapshot)
    /// A provider failed with a user-safe issue description.
    case failure(PackageProviderIssue)
}
