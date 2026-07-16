//
//  PackageMaintenanceModels.swift
//  CodingBuddy
//

import Foundation

/// Package managers supported by workstation maintenance v1.
nonisolated enum PackageManagerKind: String, CaseIterable, Codable, Hashable, Sendable {
    case homebrew
    case npm
    case pnpm

    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .pnpm: "pnpm"
        }
    }

    var systemImage: String {
        switch self {
        case .homebrew: "mug"
        case .npm, .pnpm: "shippingbox"
        }
    }
}

/// One active command-line installation selected for a package manager.
nonisolated struct PackageManagerInstallation: Identifiable, Equatable, Hashable, Sendable {
    let manager: PackageManagerKind
    let executableURL: URL
    let environment: [String: String]
    let isWritable: Bool

    var id: String { "\(manager.rawValue):\(executableURL.path)" }
}

/// Package shape needed for provider-specific update commands.
nonisolated enum PackageKind: String, Codable, Hashable, Sendable {
    case formula
    case cask
    case nodePackage
}

/// Why a package can or cannot be updated from CodingBuddy.
nonisolated enum PackageStatus: String, Codable, Hashable, Sendable {
    case current
    case updateAvailable
    case majorUpdateAvailable
    case pinned
    case selfUpdating
    case notWritable
    case unknown

    var isUpdateAvailable: Bool {
        self == .updateAvailable || self == .majorUpdateAvailable
    }

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
    let manager: PackageManagerKind
    let kind: PackageKind
    let name: String
    let installedVersion: String
    let wantedVersion: String?
    let latestVersion: String?
    let isDirect: Bool
    let status: PackageStatus
    let homepageURL: URL?
    let repositoryURL: URL?
    let installationID: String

    var id: String { "\(manager.rawValue):\(kind.rawValue):\(name)" }

    func targetVersion(for mode: PackageUpdateMode) -> String? {
        switch mode {
        case .compatible:
            wantedVersion ?? latestVersion
        case .latest:
            latestVersion ?? wantedVersion
        }
    }

    func isUpdateAvailable(for mode: PackageUpdateMode) -> Bool {
        guard status.isUpdateAvailable, let target = targetVersion(for: mode) else { return false }
        return target != installedVersion
    }
}

/// One successful provider scan.
nonisolated struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    let installation: PackageManagerInstallation
    let packages: [InstalledPackage]
    let scannedAt: Date

    var id: PackageManagerKind { installation.manager }
}

/// Provider-scoped failure that must not hide other snapshots.
nonisolated struct PackageProviderIssue: Identifiable, Equatable, Sendable {
    let manager: PackageManagerKind
    let message: String

    var id: PackageManagerKind { manager }
}

/// Target policy for Node package updates.
nonisolated enum PackageUpdateMode: String, CaseIterable, Sendable {
    case compatible
    case latest

    var displayName: String {
        switch self {
        case .compatible: String(localized: "Compatible")
        case .latest: String(localized: "Latest")
        }
    }
}

/// One confirmed update operation with an exact version transition.
nonisolated struct PackageUpdatePlanItem: Identifiable, Equatable, Sendable {
    let package: InstalledPackage
    let targetVersion: String
    let previewCommand: CommandRequest?
    let command: CommandRequest

    var id: String { package.id }
}

/// Immutable update preview shown before execution.
nonisolated struct PackageUpdatePlan: Equatable, Sendable {
    let items: [PackageUpdatePlanItem]
    let mode: PackageUpdateMode
}

/// Lifecycle of one package in a sequential update run.
nonisolated enum PackageUpdateEventState: String, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// User-visible, non-secret update log entry.
nonisolated struct PackageUpdateEvent: Identifiable, Equatable, Sendable {
    let packageID: String
    let packageName: String
    var state: PackageUpdateEventState
    var message: String

    var id: String { packageID }
}

/// Best-effort release information for the selected target version.
nonisolated struct PackageReleaseNotes: Equatable, Sendable {
    let title: String
    let body: String?
    let sourceURL: URL
}
