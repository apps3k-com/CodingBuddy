//
//  RepoReadinessGuidance.swift
//  CodingBuddy
//

import Foundation

/// Deterministic explainable guidance for repository readiness checks.
nonisolated enum RepoReadinessGuidance {
    /// Stable route owned by `RepoReadinessView` for opening the selected repository.
    static let revealRepositoryActionID = "repo-readiness.action.reveal-repository"

    /// Builds guidance from stable check and status values, never localized title text.
    static func guidance(for item: RepoReadinessItem) -> Guidance {
        Guidance(
            id: "repo-readiness.guidance.\(item.code.rawValue).\(item.status.rawValue)",
            explanation: item.detail,
            relevance: relevance(for: item.code),
            consequence: consequence(for: item.status),
            recommendedAction: recommendedAction(for: item.code, status: item.status),
            alternatives: [],
            technicalEvidence: evidence(for: item),
            glossaryTerms: glossaryTerms(for: item.code)
        )
    }

    /// Explains why each readiness signal matters independently of its localized title.
    private static func relevance(for code: RepoReadinessCheckCode) -> String {
        switch code {
        case .governance:
            String(
                localized: "Repo readiness guidance relevance governance",
                defaultValue:
                    "Repository-specific agent instructions define ownership, safety rules, and validation expectations before code changes begin."
            )
        case .readme:
            String(
                localized: "Repo readiness guidance relevance readme",
                defaultValue:
                    "A README gives contributors and coding agents a shared starting point for the project's purpose and setup."
            )
        case .buildAndTestDocumentation:
            String(
                localized: "Repo readiness guidance relevance build and test documentation",
                defaultValue:
                    "Documented commands make validation repeatable and reduce guesses about how the repository is built and tested."
            )
        case .contributionWorkflow:
            String(
                localized: "Repo readiness guidance relevance contribution workflow",
                defaultValue:
                    "A documented contribution workflow keeps issue, branch, review, and validation steps consistent."
            )
        case .githubTemplates:
            String(
                localized: "Repo readiness guidance relevance GitHub templates",
                defaultValue:
                    "Issue and pull request templates preserve the context that implementers and reviewers need for repeatable handoffs."
            )
        case .featureFlagDocumentation:
            String(
                localized: "Repo readiness guidance relevance feature flag documentation",
                defaultValue:
                    "Feature flag documentation shows which behavior is gated, how mature it is, and how rollout is controlled."
            )
        case .setupAndHooks:
            String(
                localized: "Repo readiness guidance relevance setup and hooks",
                defaultValue:
                    "A discoverable setup path helps local checks and Git hooks run consistently for each contributor."
            )
        case .ciWorkflow:
            String(
                localized: "Repo readiness guidance relevance CI workflow",
                defaultValue:
                    "CI provides an independent build or test signal before changes are merged."
            )
        case .repositoryState:
            String(
                localized: "Repo readiness guidance relevance repository state",
                defaultValue:
                    "Git operation markers can indicate an interrupted or active operation that should be understood before new changes begin."
            )
        }
    }

    /// Describes the consequence of the observed outcome without assuming scanner details.
    private static func consequence(for status: RepoReadinessStatus) -> String {
        switch status {
        case .pass:
            String(
                localized: "Repo readiness guidance consequence pass",
                defaultValue:
                    "This check is healthy, so it does not currently add uncertainty to repository setup or workflow."
            )
        case .warn:
            String(
                localized: "Repo readiness guidance consequence warning",
                defaultValue:
                    "The partial or ambiguous signal can lead contributors and coding agents to make inconsistent assumptions until it is reviewed."
            )
        case .fail:
            String(
                localized: "Repo readiness guidance consequence failure",
                defaultValue:
                    "This state can block reliable work or leave contributors and coding agents without a required safeguard until it is resolved."
            )
        }
    }

    /// Returns either an honest healthy state or the one read-only navigation action.
    private static func recommendedAction(
        for code: RepoReadinessCheckCode,
        status: RepoReadinessStatus
    ) -> RecommendedAction {
        switch status {
        case .pass:
            RecommendedAction(
                id: "repo-readiness.action.\(code.rawValue).not-needed",
                title: String(
                    localized: "Repo readiness guidance no action title",
                    defaultValue: "No action needed"
                ),
                expectedResult: String(
                    localized: "Repo readiness guidance no action expected result",
                    defaultValue: "This readiness check remains healthy."
                ),
                effort: .low,
                safetyClass: .readOnly,
                availability: .notNeeded(
                    reason: String(
                        localized: "Repo readiness guidance no action reason",
                        defaultValue: "The repository currently has the expected signal for this check."
                    )
                )
            )
        case .warn, .fail:
            RecommendedAction(
                id: revealRepositoryActionID,
                title: String(localized: "Reveal in Finder"),
                expectedResult: String(
                    localized: "Repo readiness guidance reveal repository expected result",
                    defaultValue:
                        "The selected repository opens in Finder so you can inspect or edit its files."
                ),
                effort: .low,
                safetyClass: .readOnly,
                availability: .available
            )
        }
    }

    /// Includes only bounded, display-safe scanner metadata in a stable order.
    private static func evidence(for item: RepoReadinessItem) -> [TechnicalEvidence] {
        [
            TechnicalEvidence(
                id: "repo-readiness.evidence.check",
                label: String(localized: "Check"),
                sanitizedValue: item.code.rawValue
            ),
            TechnicalEvidence(
                id: "repo-readiness.evidence.status",
                label: String(localized: "Status"),
                sanitizedValue: item.status.rawValue
            ),
            TechnicalEvidence(
                id: "repo-readiness.evidence.source",
                label: String(localized: "Source"),
                sanitizedValue: sanitizedSource(item.source)
            ),
        ]
    }

    /// Attaches only terms that accurately describe the scanner's signal.
    private static func glossaryTerms(for code: RepoReadinessCheckCode) -> [DeveloperTerm] {
        switch code {
        case .ciWorkflow:
            [.ci]
        case .governance,
             .readme,
             .buildAndTestDocumentation,
             .contributionWorkflow,
             .githubTemplates,
             .featureFlagDocumentation,
             .setupAndHooks,
             .repositoryState:
            []
        }
    }

    /// Removes control characters and bounds repository-provided path metadata.
    private static func sanitizedSource(_ source: String) -> String {
        let withoutControls = source
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
        let collapsedWhitespace = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let maximumLength = 240

        guard collapsedWhitespace.count > maximumLength else { return collapsedWhitespace }
        return String(collapsedWhitespace.prefix(maximumLength - 3)) + "..."
    }
}
