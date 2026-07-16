//
//  PackageReleaseNotesProvider.swift
//  CodingBuddy
//

import Foundation

/// Lazy release-note boundary used by the selected package inspector.
nonisolated protocol ReleaseNotesProviding: Sendable {
    /// Resolves notes or a useful source link for one exact package target version.
    func releaseNotes(for package: InstalledPackage, targetVersion: String) async -> PackageReleaseNotes?
}

/// Resolves GitHub releases first and otherwise returns a useful external source link.
nonisolated struct GitHubPackageReleaseNotesProvider: ReleaseNotesProviding {
    /// HTTP boundary used for GitHub release requests.
    let transport: any GitHubTransport
    /// Base URL for GitHub-compatible release endpoints.
    let apiBaseURL: URL
    /// Locator used to find npm or pnpm for registry metadata fallback.
    let locator: any ExecutableLocating
    /// Runner used only for read-only registry metadata queries.
    let runner: any CommandRunning

    /// Creates a release-note provider with injectable network and command boundaries.
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

    /// Tries version-specific GitHub releases before returning a repository or homepage fallback.
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
    /// GitHub account or organization that owns the repository.
    let owner: String
    /// Repository name without a trailing `.git` suffix.
    let repository: String

    /// Normalizes supported GitHub URL and SSH-like forms into an owner/repository identity.
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

    /// Canonical browser URL for the repository.
    var browserURL: URL { URL(string: "https://github.com/\(owner)/\(repository)")! }
}

private nonisolated struct GitHubPackageRelease: Decodable {
    /// Release tag returned by GitHub.
    let tagName: String
    /// Optional human-readable release name.
    let name: String?
    /// Optional Markdown release body.
    let body: String?
    /// Browser URL for the release.
    let htmlURL: String

    /// Maps GitHub's release response keys.
    enum CodingKeys: String, CodingKey {
        /// Tag key exposed as `tagName`.
        case tagName = "tag_name"
        /// Keys whose JSON and Swift names are identical.
        case name, body
        /// Browser-link key exposed as `htmlURL`.
        case htmlURL = "html_url"
    }
}

private nonisolated struct PackageRegistryMetadata: Decodable {
    /// Repository metadata returned by npm-compatible registries.
    let repository: RegistryRepository?
    /// Optional package homepage text.
    let homepage: String?

    /// Parsed repository URL when the metadata contains a valid URL string.
    var repositoryURL: URL? { repository?.value.flatMap(URL.init(string:)) }
    /// Parsed homepage URL when the metadata contains a valid URL string.
    var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }
}

private nonisolated enum RegistryRepository: Decodable {
    /// Normalized repository URL text.
    case url(String)

    /// Underlying repository URL text.
    var value: String? {
        switch self { case .url(let value): value }
    }

    /// Decodes repository metadata represented as a URL string or an object with a `url` field.
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
