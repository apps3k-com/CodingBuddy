import Foundation

/// Stable result states for one repository readiness check.
nonisolated enum RepoReadinessStatus: String, CaseIterable, Sendable {
    /// The repository has the expected local signal.
    case pass

    /// The repository has a partial or ambiguous local signal.
    case warn

    /// The repository is missing the expected local signal.
    case fail

    /// Human-readable status label.
    var displayName: String {
        switch self {
        case .pass:
            String(localized: "Pass")
        case .warn:
            String(localized: "Warn")
        case .fail:
            String(localized: "Fail")
        }
    }
}

/// Deterministic checklist codes used by the Repo Readiness scanner.
nonisolated enum RepoReadinessCheckCode: String, CaseIterable, Sendable {
    /// Root-level agent governance files such as AGENTS.md or CLAUDE.md.
    case governance

    /// Repository overview documentation.
    case readme

    /// Documented local build and test commands.
    case buildAndTestDocumentation

    /// Contribution, issue, branch, PR, and test workflow documentation.
    case contributionWorkflow

    /// GitHub issue and pull request templates.
    case githubTemplates

    /// Feature flag documentation for Swift app repositories.
    case featureFlagDocumentation

    /// One-time setup script and git hook activation.
    case setupAndHooks

    /// GitHub Actions workflow for build or test automation.
    case ciWorkflow

    /// Lightweight repository state indicators read from .git without invoking git.
    case repositoryState
}

/// One read-only agentic-coding readiness check for a selected repository.
nonisolated struct RepoReadinessItem: Identifiable, Equatable, Hashable, Sendable {
    /// Stable machine-readable check code.
    let code: RepoReadinessCheckCode

    /// Pass, warning, or failure state for the check.
    let status: RepoReadinessStatus

    /// Localized one-line check title.
    let title: String

    /// Localized one-sentence explanation of the observed state.
    let detail: String

    /// Repository-relative source path or area that produced the result.
    let source: String

    /// Localized one-sentence remediation hint.
    let remediationHint: String

    /// Stable identifier for SwiftUI table selection.
    var id: String { code.rawValue }

    /// Whether the result should count in warning badges.
    var isProblem: Bool { status != .pass }

    /// Returns true when the item matches a free-text filter.
    func matches(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        return [
            code.rawValue,
            status.rawValue,
            status.displayName,
            title,
            detail,
            source,
            remediationHint
        ]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(trimmed)
    }
}
