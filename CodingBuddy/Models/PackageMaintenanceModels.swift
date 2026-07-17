//
//  PackageMaintenanceModels.swift
//  CodingBuddy
//

import Foundation

/// Package managers supported by workstation maintenance v1.
nonisolated enum PackageManagerKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Homebrew formula and cask installation.
    case homebrew
    /// npm global package installation.
    case npm
    /// pnpm global package installation.
    case pnpm

    /// Product name shown verbatim in maintenance views.
    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .pnpm: "pnpm"
        }
    }

    /// SF Symbol associated with the package ecosystem.
    var systemImage: String {
        switch self {
        case .homebrew: "mug"
        case .npm, .pnpm: "shippingbox"
        }
    }
}

/// One active command-line installation selected for a package manager.
nonisolated struct PackageManagerInstallation: Identifiable, Equatable, Hashable, Sendable {
    /// Package ecosystem served by this executable.
    let manager: PackageManagerKind
    /// Resolved executable selected for provider commands.
    let executableURL: URL
    /// Environment snapshot required to invoke the executable consistently.
    let environment: [String: String]
    /// Whether provider updates may modify this installation.
    let isWritable: Bool

    /// Identity scoped by manager and executable path.
    var id: String { "\(manager.rawValue):\(executableURL.path)" }
}

/// Package shape needed for provider-specific update commands.
nonisolated enum PackageKind: String, Codable, Hashable, Sendable {
    /// Homebrew command-line formula.
    case formula
    /// Homebrew macOS application cask.
    case cask
    /// Package installed by a Node package manager.
    case nodePackage
}

/// Why a package can or cannot be updated from CodingBuddy.
nonisolated enum PackageStatus: String, Codable, Hashable, Sendable {
    /// Installed version matches the provider's applicable target.
    case current
    /// A compatible non-major update is available.
    case updateAvailable
    /// Latest available update crosses a major-version boundary.
    case majorUpdateAvailable
    /// Provider policy intentionally prevents an update.
    case pinned
    /// Package owns its update lifecycle outside the package manager.
    case selfUpdating
    /// Installation cannot be modified by the current user.
    case notWritable
    /// Provider data is insufficient to classify the package safely.
    case unknown

    /// Whether the status represents an actionable version difference.
    var isUpdateAvailable: Bool {
        self == .updateAvailable || self == .majorUpdateAvailable
    }

    /// Localized status label for maintenance views.
    var displayName: String {
        switch self {
        case .current: String(localized: "Current")
        case .updateAvailable: String(localized: "Update available")
        case .majorUpdateAvailable: String(localized: "Major update")
        case .pinned: String(localized: "Pinned")
        case .selfUpdating: String(localized: "Self-updating")
        case .notWritable: String(localized: "Not writable")
        case .unknown: String(localized: "Unknown")
        }
    }
}

/// Normalized global package returned by any provider.
nonisolated struct InstalledPackage: Identifiable, Equatable, Hashable, Sendable {
    /// Provider that owns the installation.
    let manager: PackageManagerKind
    /// Provider-specific package shape needed for update commands.
    let kind: PackageKind
    /// Provider package identifier used on the command line.
    let name: String
    /// Version currently reported as installed.
    let installedVersion: String
    /// Highest version allowed by the current compatibility constraint.
    let wantedVersion: String?
    /// Latest version known to the provider, regardless of compatibility.
    let latestVersion: String?
    /// Whether the user installed or declared the package directly.
    let isDirect: Bool
    /// Normalized update eligibility and blocking reason.
    let status: PackageStatus
    /// Package homepage supplied by the provider.
    let homepageURL: URL?
    /// Source repository supplied by the provider.
    let repositoryURL: URL?
    /// Installation identity used to route commands to the scanned executable.
    let installationID: String

    /// Cross-provider identity for one package name and shape.
    var id: String { "\(manager.rawValue):\(kind.rawValue):\(name)" }

    /// Selects the best known target under the requested update policy.
    func targetVersion(for mode: PackageUpdateMode) -> String? {
        switch mode {
        case .compatible:
            wantedVersion ?? latestVersion
        case .latest:
            latestVersion ?? wantedVersion
        }
    }

    /// Checks both normalized eligibility and a real version transition.
    func isUpdateAvailable(for mode: PackageUpdateMode) -> Bool {
        guard status.isUpdateAvailable, let target = targetVersion(for: mode) else { return false }
        return target != installedVersion
    }
}

/// One successful provider scan.
nonisolated struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    /// Installation used to produce the scan.
    let installation: PackageManagerInstallation
    /// Packages normalized from the provider response.
    let packages: [InstalledPackage]
    /// Wall-clock time when the scan completed successfully.
    let scannedAt: Date

    /// One active snapshot per package-manager kind.
    var id: PackageManagerKind { installation.manager }
}

/// Provider-scoped failure that must not hide other snapshots.
nonisolated struct PackageProviderIssue: Identifiable, Equatable, Sendable {
    /// Provider whose scan failed.
    let manager: PackageManagerKind
    /// Non-secret diagnostic suitable for display.
    let message: String

    /// One current issue per package-manager kind.
    var id: PackageManagerKind { manager }
}

/// Target policy for Node package updates.
nonisolated enum PackageUpdateMode: String, CaseIterable, Sendable {
    /// Stay within the provider's current compatibility constraint when known.
    case compatible
    /// Prefer the newest known release even across major versions.
    case latest

    /// Localized policy label shown in update controls.
    var displayName: String {
        switch self {
        case .compatible: String(localized: "Compatible")
        case .latest: String(localized: "Latest")
        }
    }
}

/// One confirmed update operation with an exact version transition.
nonisolated struct PackageUpdatePlanItem: Identifiable, Equatable, Sendable {
    /// Installed package captured when the plan was created.
    let package: InstalledPackage
    /// Exact version selected for the update.
    let targetVersion: String
    /// Optional read-only command that previews provider changes.
    let previewCommand: CommandRequest?
    /// Mutation command executed only after confirmation.
    let command: CommandRequest

    /// Stable package identity used by preview and progress views.
    var id: String { package.id }
}

/// Immutable update preview shown before execution.
nonisolated struct PackageUpdatePlan: Equatable, Sendable {
    /// Ordered update operations approved in the preview.
    let items: [PackageUpdatePlanItem]
    /// Target-selection policy applied consistently to every item.
    let mode: PackageUpdateMode
}

/// Lifecycle of one package in a sequential update run.
nonisolated enum PackageUpdateEventState: String, Equatable, Sendable {
    /// Operation is waiting for earlier plan items.
    case queued
    /// Provider mutation command is currently executing.
    case running
    /// Provider command completed successfully.
    case succeeded
    /// Provider command completed with an error.
    case failed
    /// Operation was not executed because the run was cancelled.
    case cancelled
}

/// User-visible, non-secret update log entry.
nonisolated struct PackageUpdateEvent: Identifiable, Equatable, Sendable {
    /// Stable package identity shared with the update plan.
    let packageID: String
    /// Non-secret package label captured for progress display.
    let packageName: String
    /// Current lifecycle state of this operation.
    var state: PackageUpdateEventState
    /// Non-secret progress or failure detail suitable for display.
    var message: String

    /// Package-scoped identity for replacing progress events in place.
    var id: String { packageID }
}

/// Best-effort release information for the selected target version.
nonisolated struct PackageReleaseNotes: Equatable, Sendable {
    /// Release title supplied by the upstream source.
    let title: String
    /// Optional release description in its original text format.
    let body: String?
    /// Upstream page used to verify the release information.
    let sourceURL: URL
}
