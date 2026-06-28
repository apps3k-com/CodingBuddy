import Foundation

/// Scans a selected repository for deterministic local-only agentic-coding readiness signals.
nonisolated struct RepoReadinessScanner: Sendable {
    /// Maximum text bytes read from one candidate file.
    static let maxReadableTextBytes = 128 * 1024

    /// Maximum shallow documentation files considered for command/workflow text.
    static let maxDocumentationFileCount = 40

    /// Root folder selected by the user.
    let repositoryURL: URL

    /// Filesystem access used for deterministic local metadata inspection.
    private var fileManager: FileManager { .default }

    /// Creates a scanner for a repository root.
    init(repositoryURL: URL) {
        self.repositoryURL = repositoryURL.standardizedFileURL
    }

    /// Returns checklist rows in a deterministic order.
    func items() -> [RepoReadinessItem] {
        [
            governanceItem(),
            readmeItem(),
            buildAndTestDocumentationItem(),
            contributionWorkflowItem(),
            githubTemplatesItem(),
            featureFlagDocumentationItem(),
            setupAndHooksItem(),
            ciWorkflowItem(),
            repositoryStateItem()
        ]
    }

    /// Checks whether root-level agent governance exists.
    private func governanceItem() -> RepoReadinessItem {
        let agents = textState(for: "AGENTS.md")
        let claude = textState(for: "CLAUDE.md")

        if agents == .nonEmpty {
            return item(
                .governance,
                .pass,
                title: String(localized: "Agent governance file"),
                detail: String(localized: "AGENTS.md is present at the repository root."),
                source: "AGENTS.md",
                remediation: String(localized: "Keep agent rules current as repository workflow decisions change.")
            )
        }

        if claude == .nonEmpty {
            return item(
                .governance,
                .warn,
                title: String(localized: "Agent governance file"),
                detail: String(localized: "CLAUDE.md is present, but AGENTS.md is missing."),
                source: "CLAUDE.md",
                remediation: String(localized: "Add AGENTS.md or mirror the shared agent instructions there.")
            )
        }

        if agents == .empty || claude == .empty {
            return item(
                .governance,
                .warn,
                title: String(localized: "Agent governance file"),
                detail: String(localized: "A governance file exists but has no readable guidance."),
                source: agents == .empty ? "AGENTS.md" : "CLAUDE.md",
                remediation: String(localized: "Document the local agent rules, ownership boundaries, and safety requirements.")
            )
        }

        return item(
            .governance,
            .fail,
            title: String(localized: "Agent governance file"),
            detail: String(localized: "No AGENTS.md or CLAUDE.md file was found at the repository root."),
            source: "AGENTS.md",
            remediation: String(localized: "Add an agent governance file that explains repo-specific coding rules.")
        )
    }

    /// Checks whether a README exists and has readable content.
    private func readmeItem() -> RepoReadinessItem {
        let paths = ["README.md", "README", "Readme.md"]
        if let nonEmptyPath = paths.first(where: { textState(for: $0) == .nonEmpty }) {
            return item(
                .readme,
                .pass,
                title: String(localized: "README"),
                detail: String(localized: "A non-empty README is present."),
                source: nonEmptyPath,
                remediation: String(localized: "Keep the README aligned with the current project purpose and setup path.")
            )
        }

        if let emptyPath = paths.first(where: { textState(for: $0) == .empty }) {
            return item(
                .readme,
                .warn,
                title: String(localized: "README"),
                detail: String(localized: "A README exists but is empty."),
                source: emptyPath,
                remediation: String(localized: "Fill in the README with the project purpose, setup, and primary workflows.")
            )
        }

        return item(
            .readme,
            .fail,
            title: String(localized: "README"),
            detail: String(localized: "No README file was found."),
            source: "README.md",
            remediation: String(localized: "Add a README that orients agents and humans before they change code.")
        )
    }

    /// Checks whether local build and test commands are documented.
    private func buildAndTestDocumentationItem() -> RepoReadinessItem {
        let commandMatches = documentationTexts().compactMap { path, text -> (String, Bool, Bool)? in
            let hasBuild = containsAny(Self.buildCommandTokens, in: text)
            let hasTest = containsAny(Self.testCommandTokens, in: text)
            guard hasBuild || hasTest else { return nil }
            return (path, hasBuild, hasTest)
        }

        if let fullMatch = commandMatches.first(where: { $0.1 && $0.2 }) {
            return item(
                .buildAndTestDocumentation,
                .pass,
                title: String(localized: "Build and test commands"),
                detail: String(localized: "Documented build and test commands were found."),
                source: fullMatch.0,
                remediation: String(localized: "Keep documented commands runnable from a fresh checkout.")
            )
        }

        let hasBuild = commandMatches.contains { $0.1 }
        let hasTest = commandMatches.contains { $0.2 }
        if hasBuild || hasTest {
            return item(
                .buildAndTestDocumentation,
                .warn,
                title: String(localized: "Build and test commands"),
                detail: String(localized: "Only part of the local build/test workflow is documented."),
                source: commandMatches.first?.0 ?? "README.md",
                remediation: String(localized: "Document both the build command and the test command agents should run.")
            )
        }

        return item(
            .buildAndTestDocumentation,
            .fail,
            title: String(localized: "Build and test commands"),
            detail: String(localized: "No documented local build or test command was found."),
            source: "README.md",
            remediation: String(localized: "Add copy-pasteable build and test commands to README or developer docs.")
        )
    }

    /// Checks whether contribution workflow documentation exists and covers the core loop.
    private func contributionWorkflowItem() -> RepoReadinessItem {
        let candidates = [
            "CONTRIBUTING.md",
            ".github/CONTRIBUTING.md",
            "docs/CONTRIBUTING.md",
            "docs/wiki/Conventions.md",
            "docs/wiki/Development-Setup.md"
        ]

        var partialMatchPath: String?

        for path in candidates {
            guard let text = lowercasedText(for: path) else { continue }
            let hasIssue = containsAny(["issue", "ticket", "backlog"], in: text)
            let hasPullRequest = containsAny(["pull request", "pr ", "merge request"], in: text)
            let hasBranchOrTest = containsAny(["branch", "test", "ci"], in: text)

            if hasIssue && hasPullRequest && hasBranchOrTest {
                return item(
                    .contributionWorkflow,
                    .pass,
                    title: String(localized: "Contribution workflow"),
                    detail: String(localized: "Contribution docs cover issues, review, and validation workflow."),
                    source: path,
                    remediation: String(localized: "Keep workflow docs aligned with the current branching and review process.")
                )
            }

            partialMatchPath = partialMatchPath ?? path
        }

        if let partialMatchPath {
            return item(
                .contributionWorkflow,
                .warn,
                title: String(localized: "Contribution workflow"),
                detail: String(localized: "Contribution docs exist but do not cover the full issue-to-PR workflow."),
                source: partialMatchPath,
                remediation: String(localized: "Document how to start work, validate it, and submit it for review.")
            )
        }

        return item(
            .contributionWorkflow,
            .fail,
            title: String(localized: "Contribution workflow"),
            detail: String(localized: "No contribution workflow document was found."),
            source: "CONTRIBUTING.md",
            remediation: String(localized: "Add contributing docs that explain issue, branch, test, and PR expectations.")
        )
    }

    /// Checks whether GitHub issue and pull request templates exist.
    private func githubTemplatesItem() -> RepoReadinessItem {
        let issueTemplatePaths = shallowFiles(in: ".github/ISSUE_TEMPLATE", allowedExtensions: ["md", "yml", "yaml"])
        let pullRequestTemplatePaths = pullRequestTemplatePaths()

        if !issueTemplatePaths.isEmpty && !pullRequestTemplatePaths.isEmpty {
            return item(
                .githubTemplates,
                .pass,
                title: String(localized: "GitHub templates"),
                detail: String(localized: "Issue and pull request templates are present."),
                source: ".github",
                remediation: String(localized: "Keep templates focused on the information reviewers and agents need.")
            )
        }

        if !issueTemplatePaths.isEmpty || !pullRequestTemplatePaths.isEmpty {
            return item(
                .githubTemplates,
                .warn,
                title: String(localized: "GitHub templates"),
                detail: String(localized: "Only one of issue or pull request templates was found."),
                source: !issueTemplatePaths.isEmpty ? ".github/ISSUE_TEMPLATE" : pullRequestTemplatePaths.first ?? ".github",
                remediation: String(localized: "Add the missing template so issues and PRs carry consistent context.")
            )
        }

        return item(
            .githubTemplates,
            .fail,
            title: String(localized: "GitHub templates"),
            detail: String(localized: "No GitHub issue or pull request template was found."),
            source: ".github",
            remediation: String(localized: "Add GitHub issue and pull request templates for repeatable agent handoffs.")
        )
    }

    /// Checks whether Swift feature flag conventions are documented when the repo looks like a Swift app.
    private func featureFlagDocumentationItem() -> RepoReadinessItem {
        let paths = boundedRepositoryPaths(maxDepth: 5, maxCount: 1_500)
        let hasSwiftAppSignal = paths.contains { path in
            path == "Package.swift" || path.hasSuffix(".xcodeproj") || path.hasSuffix("/FeatureFlags.swift") || path == "FeatureFlags.swift"
        }

        guard hasSwiftAppSignal else {
            return item(
                .featureFlagDocumentation,
                .pass,
                title: String(localized: "Feature flag documentation"),
                detail: String(localized: "No Swift app feature flag convention was detected."),
                source: "docs/FEATURE_FLAGS.md",
                remediation: String(localized: "Add feature flag documentation when repository features become flag-gated.")
            )
        }

        if textState(for: "docs/FEATURE_FLAGS.md") == .nonEmpty {
            return item(
                .featureFlagDocumentation,
                .pass,
                title: String(localized: "Feature flag documentation"),
                detail: String(localized: "Swift app feature flag documentation is present."),
                source: "docs/FEATURE_FLAGS.md",
                remediation: String(localized: "Keep the flag registry synchronized with feature flag code.")
            )
        }

        return item(
            .featureFlagDocumentation,
            .warn,
            title: String(localized: "Feature flag documentation"),
            detail: String(localized: "Swift app structure was detected without feature flag documentation."),
            source: "docs/FEATURE_FLAGS.md",
            remediation: String(localized: "Document feature flags, maturity, and rollout expectations in docs/FEATURE_FLAGS.md.")
        )
    }

    /// Checks whether one-time setup and hook activation are discoverable.
    private func setupAndHooksItem() -> RepoReadinessItem {
        let setupState = textState(for: "scripts/setup.sh")
        let setupText = lowercasedText(for: "scripts/setup.sh") ?? ""
        let hookFiles = shallowFiles(in: ".githooks", allowedExtensions: nil)
        let setupMentionsHooks = containsAny(["hook", "hookspath", "pre-push", "pre-commit", "commit-msg"], in: setupText)

        if setupState == .nonEmpty && (!hookFiles.isEmpty || setupMentionsHooks) {
            return item(
                .setupAndHooks,
                .pass,
                title: String(localized: "Setup script and hooks"),
                detail: String(localized: "A setup script and hook activation signal are present."),
                source: "scripts/setup.sh",
                remediation: String(localized: "Keep setup idempotent so agents and contributors can rerun it safely.")
            )
        }

        if setupState == .nonEmpty {
            return item(
                .setupAndHooks,
                .warn,
                title: String(localized: "Setup script and hooks"),
                detail: String(localized: "A setup script exists but no hook activation signal was found."),
                source: "scripts/setup.sh",
                remediation: String(localized: "Document or wire up git hook activation in the setup script.")
            )
        }

        return item(
            .setupAndHooks,
            .fail,
            title: String(localized: "Setup script and hooks"),
            detail: String(localized: "No one-time setup script was found."),
            source: "scripts/setup.sh",
            remediation: String(localized: "Add a setup script that prepares local checks and hooks without network-only assumptions.")
        )
    }

    /// Checks whether GitHub Actions has an obvious build or test workflow.
    private func ciWorkflowItem() -> RepoReadinessItem {
        let workflowPaths = shallowFiles(in: ".github/workflows", allowedExtensions: ["yml", "yaml"])

        guard !workflowPaths.isEmpty else {
            return item(
                .ciWorkflow,
                .fail,
                title: String(localized: "CI workflow"),
                detail: String(localized: "No GitHub Actions workflow was found."),
                source: ".github/workflows",
                remediation: String(localized: "Add CI that runs the repository build and test checks.")
            )
        }

        for path in workflowPaths {
            guard let text = lowercasedText(for: path) else { continue }
            if containsAny(Self.buildCommandTokens + Self.testCommandTokens, in: text) {
                return item(
                    .ciWorkflow,
                    .pass,
                    title: String(localized: "CI workflow"),
                    detail: String(localized: "A GitHub Actions workflow appears to run build or test checks."),
                    source: path,
                    remediation: String(localized: "Keep CI aligned with the local commands documented for contributors.")
                )
            }
        }

        return item(
            .ciWorkflow,
            .warn,
            title: String(localized: "CI workflow"),
            detail: String(localized: "GitHub Actions workflows exist, but no obvious build or test command was found."),
            source: ".github/workflows",
            remediation: String(localized: "Add build or test execution to CI, or document why another workflow provides validation.")
        )
    }

    /// Checks lightweight .git state indicators without invoking git.
    private func repositoryStateItem() -> RepoReadinessItem {
        let gitDirectory: URL
        switch resolvedGitDirectory() {
        case .directory(let url):
            gitDirectory = url
        case .missing:
            return item(
                .repositoryState,
                .warn,
                title: String(localized: "Repository state"),
                detail: String(localized: "No .git entry was found in the selected folder."),
                source: ".git",
                remediation: String(localized: "Select the repository root or initialize Git before relying on repo-state checks.")
            )
        case .unresolvedFile:
            return item(
                .repositoryState,
                .warn,
                title: String(localized: "Repository state"),
                detail: String(localized: "The .git file could not be resolved to a local Git directory."),
                source: ".git",
                remediation: String(localized: "Keep the .git file in standard gitdir format or select the primary worktree root.")
            )
        }

        if fileExists("index.lock", in: gitDirectory) {
            return item(
                .repositoryState,
                .fail,
                title: String(localized: "Repository state"),
                detail: String(localized: "A Git index lock file is present."),
                source: ".git/index.lock",
                remediation: String(localized: "Resolve the interrupted Git operation before asking agents to modify the repo.")
            )
        }

        let inProgressMarkers = [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply"
        ]

        if let marker = inProgressMarkers.first(where: { fileExists($0, in: gitDirectory) || directoryExists($0, in: gitDirectory) }) {
            return item(
                .repositoryState,
                .warn,
                title: String(localized: "Repository state"),
                detail: String(localized: "A Git merge, rebase, cherry-pick, or revert marker is present."),
                source: ".git/\(marker)",
                remediation: String(localized: "Finish or abort the in-progress Git operation before starting agent work.")
            )
        }

        return item(
            .repositoryState,
            .pass,
            title: String(localized: "Repository state"),
            detail: String(localized: "No lightweight .git lock or in-progress operation marker was found."),
            source: ".git",
            remediation: String(localized: "Refresh this check after branch changes or interrupted Git operations.")
        )
    }

    /// Creates one checklist item.
    private func item(
        _ code: RepoReadinessCheckCode,
        _ status: RepoReadinessStatus,
        title: String,
        detail: String,
        source: String,
        remediation: String
    ) -> RepoReadinessItem {
        RepoReadinessItem(
            code: code,
            status: status,
            title: title,
            detail: detail,
            source: source,
            remediationHint: remediation
        )
    }

    /// Local resolution state for the selected repository's Git metadata directory.
    private enum GitDirectoryResolution: Sendable {
        case missing
        case unresolvedFile
        case directory(URL)
    }

    /// Resolves `.git` when it is either a directory or a standard worktree/submodule gitdir file.
    private func resolvedGitDirectory() -> GitDirectoryResolution {
        let gitURL = url(for: ".git")
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return .missing
        }

        if isDirectory.boolValue {
            return .directory(gitURL)
        }

        guard let text = rawTextFile(at: gitURL, maxBytes: 4 * 1024) else {
            return .unresolvedFile
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("gitdir:") else {
            return .unresolvedFile
        }

        let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return .unresolvedFile
        }

        let gitDirectoryURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : repositoryURL.appendingPathComponent(rawPath)
        let standardizedURL = gitDirectoryURL.standardizedFileURL

        guard directoryExists(standardizedURL) else {
            return .unresolvedFile
        }

        return .directory(standardizedURL)
    }

    /// Build-command tokens that are deterministic local readiness signals.
    private static let buildCommandTokens = [
        "xcodebuild",
        "swift build",
        "npm run build",
        "pnpm build",
        "yarn build",
        "make build",
        "just build",
        "cargo build",
        "go build",
        "gradle build",
        "mvn"
    ]

    /// Test-command tokens that are deterministic local readiness signals.
    private static let testCommandTokens = [
        "xcodebuild test",
        "swift test",
        "npm test",
        "npm run test",
        "pnpm test",
        "yarn test",
        "make test",
        "just test",
        "cargo test",
        "go test",
        "gradle test",
        "mvn test",
        "pytest"
    ]

    /// Small candidate docs/configs to inspect for command and workflow text.
    private func documentationTexts() -> [(path: String, text: String)] {
        documentationCandidatePaths()
            .compactMap { path in
                guard let text = lowercasedText(for: path) else { return nil }
                return (path, text)
            }
    }

    /// Returns bounded, sorted candidate documentation paths.
    private func documentationCandidatePaths() -> [String] {
        var paths = [
            "README.md",
            "README",
            "Readme.md",
            "CONTRIBUTING.md",
            "DEVELOPMENT.md",
            "Package.swift",
            "Makefile",
            "Justfile",
            "docs/FEATURE_FLAGS.md"
        ]

        paths.append(contentsOf: shallowFiles(in: "docs", allowedExtensions: ["md"]))
        paths.append(contentsOf: shallowFiles(in: "docs/wiki", allowedExtensions: ["md"]))

        let sortedPaths = Array(Set(paths)).sorted()
        return Array(sortedPaths.prefix(Self.maxDocumentationFileCount))
    }

    /// Returns known pull request template files and shallow template-directory entries.
    private func pullRequestTemplatePaths() -> [String] {
        var paths = [
            ".github/pull_request_template.md",
            ".github/PULL_REQUEST_TEMPLATE.md",
            "pull_request_template.md",
            "PULL_REQUEST_TEMPLATE.md"
        ].filter(fileExists)

        paths.append(contentsOf: shallowFiles(in: ".github/PULL_REQUEST_TEMPLATE", allowedExtensions: ["md"]))
        return paths.sorted()
    }

    /// Text file state used by checklist rules.
    private func textState(for relativePath: String) -> TextState {
        guard let text = text(for: relativePath) else { return .missing }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .nonEmpty
    }

    /// Reads a bounded UTF-8-ish text file, returning nil for missing, directories, or oversized files.
    private func text(for relativePath: String) -> String? {
        rawTextFile(at: url(for: relativePath), maxBytes: Self.maxReadableTextBytes)
    }

    /// Reads a bounded regular text file without following symlinks.
    private func rawTextFile(at url: URL, maxBytes: Int) -> String? {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        guard !isSymbolicLink(url) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= maxBytes
        else { return nil }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
    }

    /// Reads lowercased bounded text.
    private func lowercasedText(for relativePath: String) -> String? {
        text(for: relativePath)?.lowercased()
    }

    /// Returns sorted shallow files under a directory.
    private func shallowFiles(in relativeDirectory: String, allowedExtensions: Set<String>?) -> [String] {
        let directoryURL = url(for: relativeDirectory)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        return urls
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { return false }
                guard let allowedExtensions else { return true }
                return allowedExtensions.contains(url.pathExtension.lowercased())
            }
            .map { "\(relativeDirectory)/\($0.lastPathComponent)" }
            .sorted()
    }

    /// Returns bounded repository-relative paths for structural detection.
    private func boundedRepositoryPaths(maxDepth: Int, maxCount: Int) -> [String] {
        var results: [String] = []
        collectRepositoryPaths(from: repositoryURL, prefix: "", depthRemaining: maxDepth, maxCount: maxCount, results: &results)
        return results.sorted()
    }

    /// Recursively collects bounded paths while skipping heavyweight generated directories.
    private func collectRepositoryPaths(
        from directoryURL: URL,
        prefix: String,
        depthRemaining: Int,
        maxCount: Int,
        results: inout [String]
    ) {
        guard depthRemaining >= 0, results.count < maxCount else { return }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard results.count < maxCount else { return }
            let name = url.lastPathComponent
            guard !Self.skippedDirectoryNames.contains(name) else { continue }

            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            results.append(relativePath)

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true, depthRemaining > 0 {
                collectRepositoryPaths(
                    from: url,
                    prefix: relativePath,
                    depthRemaining: depthRemaining - 1,
                    maxCount: maxCount,
                    results: &results
                )
            }
        }
    }

    /// Directories intentionally skipped during bounded structural scans.
    private static let skippedDirectoryNames: Set<String> = [
        ".git",
        ".build",
        "build",
        "DerivedData",
        "node_modules"
    ]

    /// Resolves one repository-relative path under the selected root.
    private func url(for relativePath: String) -> URL {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(repositoryURL) { url, pathComponent in
                url.appendingPathComponent(String(pathComponent))
            }
    }

    /// Returns true for any present filesystem entry.
    private func fileExists(_ relativePath: String) -> Bool {
        fileExists(url(for: relativePath))
    }

    /// Returns true for any present directory.
    private func directoryExists(_ relativePath: String) -> Bool {
        directoryExists(url(for: relativePath))
    }

    /// Returns true for any present regular file under a directory URL.
    private func fileExists(_ relativePath: String, in directoryURL: URL) -> Bool {
        fileExists(directoryURL.appendingPathComponent(relativePath))
    }

    /// Returns true for any present directory under a directory URL.
    private func directoryExists(_ relativePath: String, in directoryURL: URL) -> Bool {
        directoryExists(directoryURL.appendingPathComponent(relativePath))
    }

    /// Returns true for any present regular file URL without following symlinks.
    private func fileExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    /// Returns true for any present directory URL.
    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Returns true when a URL itself is a symbolic link.
    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Case-insensitive token lookup; callers pass lowercased text.
    private func containsAny(_ tokens: [String], in lowercasedText: String) -> Bool {
        tokens.contains { lowercasedText.contains($0) }
    }

    /// Bounded text file states.
    private enum TextState: Sendable {
        case missing
        case empty
        case nonEmpty
    }
}
