//
//  PackageProviders.swift
//  CodingBuddy
//

import Foundation

/// Internal provider contract for global package inventory and updates.
nonisolated protocol PackageProvider: Sendable {
    /// Package manager represented by this provider.
    var manager: PackageManagerKind { get }
    /// Reads one concrete installation and returns its normalized global package inventory.
    func scan(installation: PackageManagerInstallation) async throws -> ProviderSnapshot
    /// Builds the exact mutating command for the selected package target.
    func updateRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest
    /// Builds a non-mutating preview command when the package manager supports one.
    func previewRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest?
}

nonisolated extension PackageProvider {
    /// Indicates by default that a provider has no native preview command.
    func previewRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest? { nil }
}

/// Provider failures safe to expose without raw environment or command data.
nonisolated enum PackageProviderError: LocalizedError, Equatable, Sendable {
    /// The package manager returned data that could not be normalized safely.
    case invalidResponse(PackageManagerKind)
    /// A package was passed to a provider for a different manager.
    case unsupportedPackage(PackageManagerKind)
    /// No exact version target is available for the requested update mode.
    case unavailableTarget

    /// Localized, user-safe explanation that omits raw command output and environment data.
    var errorDescription: String? {
        switch self {
        case .invalidResponse(let manager):
            String(format: String(localized: "CodingBuddy could not read the %@ package list."), manager.displayName)
        case .unsupportedPackage(let manager):
            String(format: String(localized: "The package cannot be updated with %@."), manager.displayName)
        case .unavailableTarget:
            String(localized: "No target version is available for this package.")
        }
    }
}

/// Homebrew formula and cask provider using documented JSON commands.
nonisolated struct HomebrewPackageProvider: PackageProvider {
    /// Homebrew manager identity used in normalized package models.
    let manager = PackageManagerKind.homebrew
    /// Command runner used for read-only inventory and generated update requests.
    let runner: any CommandRunning

    /// Creates a Homebrew provider with an injectable command runner.
    init(runner: any CommandRunning = FoundationCommandRunner()) {
        self.runner = runner
    }

    /// Reads installed and outdated formulae and casks without triggering Homebrew auto-update.
    func scan(installation: PackageManagerInstallation) async throws -> ProviderSnapshot {
        let environment = installation.environment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1"]) { _, new in new }
        let info = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["info", "--json=v2", "--installed"],
            environment: environment,
            timeout: 120
        ))
        let outdated = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["outdated", "--json=v2"],
            environment: environment,
            timeout: 120
        ))

        guard let infoDocument = try? JSONDecoder().decode(BrewInfoDocument.self, from: info.standardOutput),
              let outdatedDocument = try? JSONDecoder().decode(BrewOutdatedDocument.self, from: outdated.standardOutput) else {
            throw PackageProviderError.invalidResponse(manager)
        }

        let formulaUpdates = Dictionary(uniqueKeysWithValues: outdatedDocument.formulae.map { ($0.name, $0) })
        let caskUpdates = Dictionary(uniqueKeysWithValues: outdatedDocument.casks.map { ($0.name, $0) })
        let packages = infoDocument.formulae.map { formula in
            let installed = formula.installed.last
            let update = formulaUpdates[formula.name]
            return InstalledPackage(
                manager: manager,
                kind: .formula,
                name: formula.name,
                installedVersion: installed?.version ?? "?",
                wantedVersion: update?.currentVersion,
                latestVersion: update?.currentVersion,
                isDirect: installed?.installedOnRequest ?? false,
                status: status(
                    installation: installation,
                    hasUpdate: update != nil,
                    isMajor: false,
                    isPinned: formula.pinned ?? false,
                    isSelfUpdating: false
                ),
                homepageURL: URL(string: formula.homepage ?? ""),
                repositoryURL: githubRepositoryURL(from: formula.homepage),
                installationID: installation.id
            )
        } + infoDocument.casks.map { cask in
            let update = caskUpdates[cask.token]
            return InstalledPackage(
                manager: manager,
                kind: .cask,
                name: cask.token,
                installedVersion: cask.installed.last ?? cask.version ?? "?",
                wantedVersion: update?.currentVersion,
                latestVersion: update?.currentVersion,
                isDirect: true,
                status: status(
                    installation: installation,
                    hasUpdate: update != nil,
                    isMajor: false,
                    isPinned: cask.pinned ?? false,
                    isSelfUpdating: cask.autoUpdates ?? false
                ),
                homepageURL: URL(string: cask.homepage ?? ""),
                repositoryURL: githubRepositoryURL(from: cask.homepage),
                installationID: installation.id
            )
        }

        return ProviderSnapshot(
            installation: installation,
            packages: packages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            scannedAt: Date()
        )
    }

    /// Builds a Homebrew upgrade request for a formula or cask.
    func updateRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest {
        guard package.manager == manager else { throw PackageProviderError.unsupportedPackage(manager) }
        var arguments = ["upgrade"]
        if package.kind == .cask { arguments.append("--cask") }
        arguments.append(package.name)
        return CommandRequest(
            executableURL: installation.executableURL,
            arguments: arguments,
            environment: installation.environment,
            timeout: 600
        )
    }

    /// Builds Homebrew's dry-run upgrade request for the selected formula or cask.
    func previewRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest? {
        guard package.manager == manager else { throw PackageProviderError.unsupportedPackage(manager) }
        var arguments = ["upgrade", "--dry-run"]
        if package.kind == .cask { arguments.append("--cask") }
        arguments.append(package.name)
        return CommandRequest(
            executableURL: installation.executableURL,
            arguments: arguments,
            environment: installation.environment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1"]) { _, new in new },
            timeout: 120
        )
    }

    private func status(
        installation: PackageManagerInstallation,
        hasUpdate: Bool,
        isMajor: Bool,
        isPinned: Bool,
        isSelfUpdating: Bool
    ) -> PackageStatus {
        if isPinned { return .pinned }
        if isSelfUpdating { return .selfUpdating }
        if !installation.isWritable { return .notWritable }
        if hasUpdate { return isMajor ? .majorUpdateAvailable : .updateAvailable }
        return .current
    }
}

/// npm global package provider.
nonisolated struct NPMPackageProvider: PackageProvider {
    /// npm manager identity used in normalized package models.
    let manager = PackageManagerKind.npm
    /// Command runner used to query npm's global inventory.
    let runner: any CommandRunning

    /// Creates an npm provider with an injectable command runner.
    init(runner: any CommandRunning = FoundationCommandRunner()) {
        self.runner = runner
    }

    /// Reads npm's globally installed and outdated packages, accepting its documented status codes.
    func scan(installation: PackageManagerInstallation) async throws -> ProviderSnapshot {
        let installedResult = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["ls", "--global", "--depth=0", "--json"],
            environment: installation.environment,
            timeout: 120,
            acceptedExitCodes: [0, 1]
        ))
        let outdatedResult = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["outdated", "--global", "--json"],
            environment: installation.environment,
            timeout: 120,
            acceptedExitCodes: [0, 1]
        ))

        guard let installed = try? JSONDecoder().decode(NodeInstalledRoot.self, from: installedResult.standardOutput),
              let outdated = decodeNPMOutdated(outdatedResult) else {
            throw PackageProviderError.invalidResponse(manager)
        }
        return ProviderSnapshot(
            installation: installation,
            packages: nodePackages(
                manager: manager,
                installed: installed.dependencies ?? [:],
                outdated: outdated,
                installation: installation
            ),
            scannedAt: Date()
        )
    }

    /// Builds an exact global npm install request for the selected target version.
    func updateRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest {
        guard package.manager == manager else { throw PackageProviderError.unsupportedPackage(manager) }
        guard let target = package.targetVersion(for: mode) else { throw PackageProviderError.unavailableTarget }
        return CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["install", "--global", "\(package.name)@\(target)"],
            environment: installation.environment,
            timeout: 600
        )
    }
}

/// pnpm global package provider with an explicit PNPM_HOME environment.
nonisolated struct PNPMPackageProvider: PackageProvider {
    /// pnpm manager identity used in normalized package models.
    let manager = PackageManagerKind.pnpm
    /// Command runner used to query pnpm's global inventory.
    let runner: any CommandRunning

    /// Creates a pnpm provider with an injectable command runner.
    init(runner: any CommandRunning = FoundationCommandRunner()) {
        self.runner = runner
    }

    /// Reads pnpm's global roots and outdated metadata using the installation environment.
    func scan(installation: PackageManagerInstallation) async throws -> ProviderSnapshot {
        let installedResult = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["list", "--global", "--depth", "0", "--json"],
            environment: installation.environment,
            timeout: 120
        ))
        let outdatedResult = try await runner.run(CommandRequest(
            executableURL: installation.executableURL,
            arguments: ["outdated", "--global", "--format", "json"],
            environment: installation.environment,
            timeout: 120,
            acceptedExitCodes: [0, 1]
        ))

        guard let roots = decodePNPMRoots(installedResult.standardOutput),
              let outdated = decodePNPMOutdated(outdatedResult) else {
            throw PackageProviderError.invalidResponse(manager)
        }
        let dependencies = roots.reduce(into: [String: NodeInstalledPackage]()) { result, root in
            result.merge(root.dependencies ?? [:]) { current, _ in current }
            result.merge(root.devDependencies ?? [:]) { current, _ in current }
            result.merge(root.optionalDependencies ?? [:]) { current, _ in current }
        }
        return ProviderSnapshot(
            installation: installation,
            packages: nodePackages(
                manager: manager,
                installed: dependencies,
                outdated: outdated,
                installation: installation
            ),
            scannedAt: Date()
        )
    }

    /// Builds a global pnpm update request, adding `--latest` only for latest-mode plans.
    func updateRequest(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        installation: PackageManagerInstallation
    ) throws -> CommandRequest {
        guard package.manager == manager else { throw PackageProviderError.unsupportedPackage(manager) }
        var arguments = ["update", "--global"]
        if mode == .latest { arguments.append("--latest") }
        arguments.append(package.name)
        return CommandRequest(
            executableURL: installation.executableURL,
            arguments: arguments,
            environment: installation.environment,
            timeout: 600
        )
    }
}

private nonisolated func nodePackages(
    manager: PackageManagerKind,
    installed: [String: NodeInstalledPackage],
    outdated: [String: NodeOutdatedPackage],
    installation: PackageManagerInstallation
) -> [InstalledPackage] {
    installed.map { name, package in
        let update = outdated[name]
        let installedVersion = package.version ?? update?.current ?? "?"
        let isMajor = update.map {
            guard let currentMajor = semanticMajor(in: installedVersion),
                  let latestMajor = semanticMajor(in: $0.latest) else { return false }
            return latestMajor > currentMajor
        } ?? false
        let status: PackageStatus
        if !installation.isWritable {
            status = .notWritable
        } else if update != nil {
            status = isMajor ? .majorUpdateAvailable : .updateAvailable
        } else {
            status = .current
        }
        return InstalledPackage(
            manager: manager,
            kind: .nodePackage,
            name: name,
            installedVersion: installedVersion,
            wantedVersion: update?.wanted,
            latestVersion: update?.latest,
            isDirect: true,
            status: status,
            homepageURL: URL(string: package.homepage ?? ""),
            repositoryURL: package.repositoryURL,
            installationID: installation.id
        )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private nonisolated func semanticMajor(in version: String) -> Int? {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    let numeric = trimmed.first == "v" ? trimmed.dropFirst() : Substring(trimmed)
    let component = numeric.prefix { $0.isNumber }
    return component.isEmpty ? nil : Int(component)
}

private nonisolated func decodePNPMRoots(_ data: Data) -> [NodeInstalledRoot]? {
    if let roots = try? JSONDecoder().decode([NodeInstalledRoot].self, from: data) { return roots }
    if let root = try? JSONDecoder().decode(NodeInstalledRoot.self, from: data) { return [root] }
    return nil
}

private nonisolated func decodeNPMOutdated(_ result: CommandResult) -> [String: NodeOutdatedPackage]? {
    if result.standardOutput.isEmpty {
        return result.exitCode == 0 ? [:] : nil
    }
    return try? JSONDecoder().decode([String: NodeOutdatedPackage].self, from: result.standardOutput)
}

private nonisolated func decodePNPMOutdated(_ result: CommandResult) -> [String: NodeOutdatedPackage]? {
    let data = result.standardOutput
    if data.isEmpty { return result.exitCode == 0 ? [:] : nil }
    if let dictionary = try? JSONDecoder().decode([String: NodeOutdatedPackage].self, from: data) {
        return dictionary
    }
    if let array = try? JSONDecoder().decode([PNPMOutdatedPackage].self, from: data) {
        return Dictionary(uniqueKeysWithValues: array.map {
            ($0.name, NodeOutdatedPackage(current: $0.current, wanted: $0.wanted, latest: $0.latest))
        })
    }
    return nil
}

private nonisolated func githubRepositoryURL(from value: String?) -> URL? {
    guard let value, let url = URL(string: value), url.host?.lowercased() == "github.com" else { return nil }
    return url
}

private nonisolated struct BrewInfoDocument: Decodable {
    /// Installed Homebrew formula records.
    let formulae: [BrewFormula]
    /// Installed Homebrew cask records.
    let casks: [BrewCask]

    /// Decodes absent formula or cask collections as empty inventories.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([BrewFormula].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([BrewCask].self, forKey: .casks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case formulae, casks }
}

private nonisolated struct BrewFormula: Decodable {
    /// Canonical Homebrew formula name.
    let name: String
    /// Upstream project homepage reported by Homebrew.
    let homepage: String?
    /// Installed versions reported for the formula.
    let installed: [BrewInstalledVersion]
    /// Whether Homebrew reports the formula as pinned.
    let pinned: Bool?

    /// Decodes optional formula metadata without requiring installed-version entries.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        installed = try container.decodeIfPresent([BrewInstalledVersion].self, forKey: .installed) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
    }

    private enum CodingKeys: String, CodingKey { case name, homepage, installed, pinned }
}

private nonisolated struct BrewInstalledVersion: Decodable {
    /// Installed formula version string.
    let version: String
    /// Whether the user explicitly requested this installation.
    let installedOnRequest: Bool?

    /// Maps Homebrew's snake-case installed-version keys.
    enum CodingKeys: String, CodingKey {
        /// Installed version key.
        case version
        /// Explicit-installation key exposed as `installedOnRequest`.
        case installedOnRequest = "installed_on_request"
    }
}

private nonisolated struct BrewCask: Decodable {
    /// Canonical Homebrew cask token.
    let token: String
    /// Current cask definition version.
    let version: String?
    /// Upstream project homepage reported by Homebrew.
    let homepage: String?
    /// Installed cask version strings.
    let installed: [String]
    /// Whether the cask delegates updates to the installed application.
    let autoUpdates: Bool?
    /// Whether Homebrew reports the cask as pinned.
    let pinned: Bool?

    /// Maps Homebrew cask keys used by the inventory normalizer.
    enum CodingKeys: String, CodingKey {
        /// Keys whose JSON and Swift names are identical.
        case token, version, homepage, installed, pinned
        /// Auto-update key exposed as `autoUpdates`.
        case autoUpdates = "auto_updates"
    }

    /// Decodes Homebrew's cask `installed` field in either array or scalar form.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        if let versions = try? container.decode([String].self, forKey: .installed) {
            installed = versions
        } else if let version = try? container.decode(String.self, forKey: .installed) {
            installed = [version]
        } else {
            installed = []
        }
        autoUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoUpdates)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
    }
}

private nonisolated struct BrewOutdatedDocument: Decodable {
    /// Formulae with updates reported by Homebrew.
    let formulae: [BrewOutdatedPackage]
    /// Casks with updates reported by Homebrew.
    let casks: [BrewOutdatedPackage]

    /// Decodes absent outdated collections as empty update sets.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([BrewOutdatedPackage].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([BrewOutdatedPackage].self, forKey: .casks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case formulae, casks }
}

private nonisolated struct BrewOutdatedPackage: Decodable {
    /// Formula name or cask token with an available update.
    let name: String
    /// Target version currently offered by Homebrew.
    let currentVersion: String

    /// Maps Homebrew's outdated-package response keys.
    enum CodingKeys: String, CodingKey {
        /// Package identity key.
        case name
        /// Available-version key exposed as `currentVersion`.
        case currentVersion = "current_version"
    }
}

private nonisolated struct NodeInstalledRoot: Decodable {
    /// Runtime dependencies installed under the global root.
    let dependencies: [String: NodeInstalledPackage]?
    /// Development dependencies installed under the global root.
    let devDependencies: [String: NodeInstalledPackage]?
    /// Optional dependencies installed under the global root.
    let optionalDependencies: [String: NodeInstalledPackage]?
}

private nonisolated struct NodeInstalledPackage: Decodable {
    /// Installed package version.
    let version: String?
    /// Package homepage from registry metadata.
    let homepage: String?
    /// Package repository in either string or object form.
    let repository: NodeRepository?

    /// Parsed repository URL when registry metadata contains a valid URL string.
    var repositoryURL: URL? { repository?.url.flatMap(URL.init(string:)) }
}

private nonisolated enum NodeRepository: Decodable {
    /// Normalized repository URL text from either supported registry representation.
    case value(String)

    /// Underlying repository URL text.
    var url: String? {
        switch self { case .value(let value): value }
    }

    /// Decodes repository metadata represented as a string or an object with a `url` field.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .value(value)
            return
        }
        let object = try container.decode([String: String].self)
        self = .value(object["url"] ?? "")
    }
}

private nonisolated struct NodeOutdatedPackage: Decodable {
    /// Version currently installed.
    let current: String
    /// Highest version satisfying the current dependency range.
    let wanted: String
    /// Latest version published by the registry.
    let latest: String
}

private nonisolated struct PNPMOutdatedPackage: Decodable {
    /// Package name in pnpm's array-shaped outdated response.
    let name: String
    /// Version currently installed.
    let current: String
    /// Highest version satisfying the current dependency range.
    let wanted: String
    /// Latest version published by the registry.
    let latest: String
}
