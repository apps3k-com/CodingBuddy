//
//  LegacyMigration.swift
//  CodingBuddy
//

import Foundation

/// One-time hand-over from the app's previous identity (EnvVarBuddy):
/// UserDefaults lived in the old bundle-id domain and backups in the old
/// Application Support folder.
nonisolated enum LegacyMigration {
    static let legacyDefaultsDomain = "apps3k.EnvVarBuddy"

    /// Runs both migrations against the real environment. Idempotent: keys
    /// already present stay untouched, the folder moves only into a vacancy.
    static func run() {
        let legacy = UserDefaults.standard.persistentDomain(forName: legacyDefaultsDomain) ?? [:]
        migrateDefaults(from: legacy)

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateSupportDirectory(
            from: support.appendingPathComponent("EnvVarBuddy", isDirectory: true),
            to: support.appendingPathComponent("CodingBuddy", isDirectory: true)
        )
    }

    /// Copies every legacy value whose key is still unset in the new domain —
    /// settings, flag overrides and window state survive the bundle-id change.
    static func migrateDefaults(from legacy: [String: Any], into defaults: UserDefaults = .standard) {
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Moves the old support folder (backups) to the new name, but never over
    /// an existing one.
    static func migrateSupportDirectory(from old: URL, to new: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.createDirectory(
            at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: old, to: new)
    }
}
