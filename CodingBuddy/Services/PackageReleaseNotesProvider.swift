//
//  PackageReleaseNotesProvider.swift
//  CodingBuddy
//

import Foundation

/// Lazy release-note boundary used by the selected package inspector.
nonisolated protocol ReleaseNotesProviding: Sendable {
    func releaseNotes(for package: InstalledPackage, targetVersion: String) async -> PackageReleaseNotes?
}

/// Resolves GitHub releases first and otherwise returns a useful external source link.
nonisolated struct GitHubPackageReleaseNotesProvider: ReleaseNotesProviding {
    let transport: any GitHubTransport
    let apiBaseURL: URL
    let locator: any ExecutableLocating
    let runner: any CommandRunning

    init(
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        locator: any ExecutableLocating = PackageExecutableLocator(),
        runner: any CommandRunning = FoundationCommandRunner()
    ) {
        self.transport = transport
        self.apiBaseURL = apiBaseURL
        self.locator = locator
        self.runner = runner
    }

    func releaseNotes(for package: InstalledPackage, targetVersion: String) async -> PackageReleaseNotes? {
        let registryMetadata = await registryMetadata(for: package)
        let repositoryURL = package.repositoryURL ?? registryMetadata?.repositoryURL
        let homepageURL = package.homepageURL ?? registryMetadata?.homepageURL

        if let repository = repositoryURL,
           let identity = GitHubRepositoryIdentity(url: repository) {
            for tag in ["v\(targetVersion)", targetVersion] {
                if let notes = await githubRelease(identity: identity, tag: tag) { return notes }
            }
            return PackageReleaseNotes(
                title: String(localized: "No version-specific release notes found"),
                body: nil,
                sourceURL: identity.browserURL
            )
        }
        if let fallback = repositoryURL ?? homepageURL {
            return PackageReleaseNotes(
                title: String(localized: "No version-specific release notes found"),
                body: nil,
                sourceURL: fallback
            )
        }
        return nil
    }

    private func registryMetadata(for package: InstalledPackage) async -> PackageRegistryMetadata? {
        guard package.repositoryURL == nil,
              package.manager == .npm || package.manager == .pnpm,
              let installation = locator.installation(for: package.manager),
              installation.id == package.installationID,
              let result = try? await runner.run(CommandRequest(
                executableURL: installation.executableURL,
                arguments: ["view", package.name, "repository", "homepage", "--json"],
                environment: installation.environment,
                timeout: 30
              )) else {
            return nil
        }
        return try? JSONDecoder().decode(PackageRegistryMetadata.self, from: result.standardOutput)
    }

    private func githubRelease(identity: GitHubRepositoryIdentity, tag: String) async -> PackageReleaseNotes? {
        let url = apiBaseURL
            .appending(path: "repos")
            .appending(path: identity.owner)
            .appending(path: identity.repository)
            .appending(path: "releases")
            .appending(path: "tags")
            .appending(path: tag)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await transport.data(for: request), response.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubPackageRelease.self, from: data),
              let sourceURL = URL(string: release.htmlURL) else {
            return nil
        }
        return PackageReleaseNotes(
            title: release.name?.isEmpty == false ? release.name! : release.tagName,
            body: release.body.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
            },
            sourceURL: sourceURL
        )
    }
}

private nonisolated struct GitHubRepositoryIdentity {
    let owner: String
    let repository: String

    init?(url: URL) {
        var value = url.absoluteString
        value = value.replacingOccurrences(of: "git+", with: "")
        value = value.replacingOccurrences(of: "git://", with: "https://")
        value = value.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
        guard let normalized = URL(string: value), normalized.host?.lowercased() == "github.com" else { return nil }
        let parts = normalized.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        owner = parts[0]
        repository = parts[1].replacingOccurrences(of: ".git", with: "")
    }

    var browserURL: URL { URL(string: "https://github.com/\(owner)/\(repository)")! }
}

private nonisolated struct GitHubPackageRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
    }
}

private nonisolated struct PackageRegistryMetadata: Decodable {
    let repository: RegistryRepository?
    let homepage: String?

    var repositoryURL: URL? { repository?.value.flatMap(URL.init(string:)) }
    var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }
}

private nonisolated enum RegistryRepository: Decodable {
    case url(String)

    var value: String? {
        switch self { case .url(let value): value }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .url(value)
            return
        }
        let object = try container.decode([String: String].self)
        self = .url(object["url"] ?? "")
    }
}
