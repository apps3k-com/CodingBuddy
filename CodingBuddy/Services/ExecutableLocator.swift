//
//  ExecutableLocator.swift
//  CodingBuddy
//

import Foundation

/// Finds one active, executable installation for each supported manager.
nonisolated protocol ExecutableLocating: Sendable {
    /// Returns the first verified executable for a manager, or `nil` when none is available.
    func installation(for manager: PackageManagerKind) -> PackageManagerInstallation?
}

/// UserDefaults keys for explicit package-manager executable overrides.
nonisolated enum PackageExecutablePreference {
    /// Produces the stable defaults key used for one manager's explicit path override.
    static func key(for manager: PackageManagerKind) -> String {
        "packageMaintenance.executable.\(manager.rawValue)"
    }
}

/// Deterministic executable discovery without invoking a login shell.
nonisolated struct PackageExecutableLocator: ExecutableLocating, @unchecked Sendable {
    /// Preference source for explicit executable overrides.
    let defaults: UserDefaults
    /// File-system dependency used to validate candidates and discover managed versions.
    let fileManager: FileManager
    /// Home directory used to construct user-scoped candidate paths.
    let homeDirectory: URL
    /// Captured process environment used to construct manager-specific launch environments.
    let processEnvironment: [String: String]

    /// Creates a locator with injectable environment and file-system dependencies.
    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.processEnvironment = processEnvironment
    }

    /// Selects the first executable candidate and returns the environment needed to invoke it.
    func installation(for manager: PackageManagerKind) -> PackageManagerInstallation? {
        for url in candidateURLs(for: manager) where isExecutableFile(url) {
            return PackageManagerInstallation(
                manager: manager,
                executableURL: url,
                environment: environment(for: manager, executableURL: url),
                isWritable: fileManager.isWritableFile(atPath: url.path)
                    || fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path)
            )
        }
        return nil
    }

    private func candidateURLs(for manager: PackageManagerKind) -> [URL] {
        var paths: [String] = []
        if let custom = defaults.string(forKey: PackageExecutablePreference.key(for: manager)), !custom.isEmpty {
            paths.append((custom as NSString).expandingTildeInPath)
        }
        paths.append(contentsOf: standardPaths(for: manager))
        paths.append(contentsOf: versionManagerPaths(for: manager))

        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private func standardPaths(for manager: PackageManagerKind) -> [String] {
        switch manager {
        case .homebrew:
            ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"]
        case .npm:
            ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", homeDirectory.appending(path: ".local/bin/npm").path]
        case .pnpm:
            [
                homeDirectory.appending(path: "Library/pnpm/pnpm").path,
                "/opt/homebrew/bin/pnpm",
                "/usr/local/bin/pnpm",
                homeDirectory.appending(path: ".local/share/pnpm/pnpm").path,
            ]
        }
    }

    private func versionManagerPaths(for manager: PackageManagerKind) -> [String] {
        guard manager != .homebrew else { return [] }
        let executableName = manager.rawValue
        let roots = [homeDirectory.appending(path: ".nvm/versions/node")]
        return roots.flatMap { root in
            let versions = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return versions
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                .map { $0.appending(path: "bin/\(executableName)").path }
        }
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    private func environment(for manager: PackageManagerKind, executableURL: URL) -> [String: String] {
        guard manager == .pnpm else { return [:] }
        let pnpmHome: String
        if let configured = processEnvironment["PNPM_HOME"], !configured.isEmpty {
            pnpmHome = configured
        } else if fileManager.fileExists(atPath: homeDirectory.appending(path: "Library/pnpm").path) {
            pnpmHome = homeDirectory.appending(path: "Library/pnpm").path
        } else if executableURL.path.contains("/Library/pnpm/") {
            pnpmHome = homeDirectory.appending(path: "Library/pnpm").path
        } else {
            pnpmHome = executableURL.deletingLastPathComponent().path
        }
        let currentPath = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ["PNPM_HOME": pnpmHome, "PATH": "\(pnpmHome):\(currentPath)"]
    }
}
