//
//  GitHubProjectsModels.swift
//  CodingBuddy
//

import CryptoKit
import Foundation

/// Display mode for one authoritative GitHub Project snapshot.
nonisolated enum GitHubProjectViewMode: String, CaseIterable, Codable, Sendable {
    /// Dense native table view.
    case table
    /// Horizontal field-backed Kanban view.
    case board

    /// Localized label used by the segmented control.
    var displayName: String {
        switch self {
        case .table: String(localized: "Table")
        case .board: String(localized: "Board")
        }
    }
}

/// GitHub organization that owns Projects visible to the current credential.
nonisolated struct GitHubProjectOrganization: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Organization GraphQL node ID.
    let id: String
    /// GitHub login used for discovery and display.
    let login: String

    /// Stable organization identity.
    var idForPersistence: String { id }
}

/// Lightweight project descriptor used by the organization picker.
nonisolated struct GitHubProjectSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Project GraphQL node ID.
    let id: String
    /// Project number within the owner scope.
    let number: Int
    /// Project title.
    let title: String
    /// Browser URL.
    let url: URL
    /// Whether GitHub marks the project closed.
    let isClosed: Bool
    /// Whether the current viewer may update project items.
    let viewerCanUpdate: Bool
    /// Last server-side project update.
    let updatedAt: Date

    /// Search predicate used without creating a local project database.
    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || String(number).localizedCaseInsensitiveContains(query)
    }
}

/// Complete or deliberately bounded project discovery result.
nonisolated struct GitHubProjectList: Equatable, Sendable {
    /// Organization resolved by GitHub.
    let organization: GitHubProjectOrganization
    /// Projects returned in server order.
    let projects: [GitHubProjectSummary]
    /// Whether a configured bound stopped before GitHub's final page.
    let isTruncated: Bool
}

/// GitHub color token attached to a single-select option.
nonisolated enum GitHubProjectOptionColor: String, Codable, CaseIterable, Sendable {
    /// GitHub gray token.
    case gray = "GRAY"
    /// GitHub blue token.
    case blue = "BLUE"
    /// GitHub green token.
    case green = "GREEN"
    /// GitHub yellow token.
    case yellow = "YELLOW"
    /// GitHub orange token.
    case orange = "ORANGE"
    /// GitHub red token.
    case red = "RED"
    /// GitHub pink token.
    case pink = "PINK"
    /// GitHub purple token.
    case purple = "PURPLE"
}

/// One selectable column value from a ProjectV2 single-select field.
nonisolated struct GitHubProjectSingleSelectOption: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable option ID required by mutations.
    let id: String
    /// User-configured option name.
    let name: String
    /// Optional explanatory text configured on GitHub.
    let description: String?
    /// GitHub semantic color token.
    let color: GitHubProjectOptionColor
}

/// ProjectV2 field whose options can back a native Kanban board.
nonisolated struct GitHubProjectSingleSelectField: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL field ID required by mutations.
    let id: String
    /// User-configured field name.
    let name: String
    /// Last server-side field definition update.
    let updatedAt: Date
    /// Options in GitHub-defined order.
    let options: [GitHubProjectSingleSelectOption]

    /// Stable digest binding confirmations to the complete option definition.
    var definitionDigest: String {
        stableGitHubProjectDigest(self)
    }
}

/// Observable GitHub Project workflow metadata used only as automation evidence.
nonisolated struct GitHubProjectWorkflow: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable GraphQL workflow ID.
    let id: String
    /// User-visible workflow name.
    let name: String
    /// Whether GitHub reports the workflow enabled.
    let isEnabled: Bool
    /// Last server-side workflow update.
    let updatedAt: Date
}

/// Kind of content attached to a ProjectV2 item.
nonisolated enum GitHubProjectContentKind: String, Codable, Sendable {
    /// Repository issue.
    case issue
    /// Repository pull request.
    case pullRequest
    /// Project-local draft issue.
    case draftIssue
    /// Content hidden or removed by GitHub.
    case redacted

    /// Localized compact label.
    var displayName: String {
        switch self {
        case .issue: String(localized: "Issue")
        case .pullRequest: String(localized: "Pull Request")
        case .draftIssue: String(localized: "Draft issue")
        case .redacted: String(localized: "Unavailable item")
        }
    }
}

/// Normalized lifecycle state of item content.
nonisolated enum GitHubProjectContentState: String, Codable, Sendable {
    /// Issue or pull request is open.
    case open
    /// Issue or pull request is closed without merge evidence.
    case closed
    /// Pull request was merged.
    case merged
    /// Draft issue has no repository lifecycle.
    case draft
    /// GitHub did not expose enough content to classify state.
    case unknown

    /// Whether the content has reached a repository terminal state.
    var isTerminal: Bool {
        self == .closed || self == .merged
    }

    /// Localized state label.
    var displayName: String {
        switch self {
        case .open: String(localized: "Open")
        case .closed: String(localized: "Closed")
        case .merged: String(localized: "Merged")
        case .draft: String(localized: "Draft")
        case .unknown: String(localized: "Unknown")
        }
    }
}

/// GitHub's reason for the current issue state, when available.
nonisolated enum GitHubProjectIssueStateReason: String, Codable, Sendable {
    /// Work was completed successfully.
    case completed = "COMPLETED"
    /// Work was deliberately closed without completion.
    case notPlanned = "NOT_PLANNED"
    /// GitHub identified the issue as a duplicate.
    case duplicate = "DUPLICATE"
    /// The issue was reopened after a terminal transition.
    case reopened = "REOPENED"
}

/// Stable reference used to compare parent, child, issue, and pull-request linkage.
nonisolated struct GitHubProjectContentReference: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// GraphQL content node ID.
    let id: String
    /// Repository identity when content is repository-backed.
    let repository: GitHubRepositoryRef
    /// Issue or pull-request number.
    let number: Int
    /// Current repository lifecycle state.
    let state: GitHubProjectContentState

    /// Compact `owner/repo#number` display identity.
    var displayName: String { "\(repository.displayName)#\(number)" }
}

/// Coverage of nested relationship connections on one content node.
nonisolated struct GitHubProjectRelationCoverage: Codable, Equatable, Sendable {
    /// Whether all child issues were returned.
    let subIssuesComplete: Bool
    /// Whether all issue-closing or PR-closing references were returned.
    let linkedContentComplete: Bool

    /// Whether every relationship required by the drift auditor is available.
    var isComplete: Bool { subIssuesComplete && linkedContentComplete }

    /// Coverage for content that has no relationship connections.
    static let notApplicable = GitHubProjectRelationCoverage(
        subIssuesComplete: true,
        linkedContentComplete: true
    )
}

/// Repository or draft content rendered by both Project table and board.
nonisolated struct GitHubProjectItemContent: Codable, Equatable, Sendable {
    /// GraphQL node ID, absent only for redacted content.
    let id: String?
    /// Content kind.
    let kind: GitHubProjectContentKind
    /// User-visible title.
    let title: String
    /// Repository number for issues and pull requests.
    let number: Int?
    /// Browser URL when GitHub exposes one.
    let url: URL?
    /// Repository identity for issues and pull requests.
    let repository: GitHubRepositoryRef?
    /// Normalized lifecycle state.
    let state: GitHubProjectContentState
    /// Issue-only state reason; absent when GitHub does not expose one.
    let issueStateReason: GitHubProjectIssueStateReason?
    /// Whether an open pull request is still draft.
    let isDraftPullRequest: Bool
    /// Last content update from GitHub.
    let updatedAt: Date?
    /// Terminal transition timestamp when GitHub exposes it.
    let terminalAt: Date?
    /// Parent issue relation when present.
    let parent: GitHubProjectContentReference?
    /// Known child issue relations.
    let subIssues: [GitHubProjectContentReference]
    /// Known closing issues or closing pull requests.
    let linkedContent: [GitHubProjectContentReference]
    /// Completeness of bounded nested relationship reads.
    let relationCoverage: GitHubProjectRelationCoverage

    /// Human-readable repository and number fallback.
    var referenceLabel: String {
        guard let repository, let number else { return kind.displayName }
        return "\(repository.displayName)#\(number)"
    }
}

/// Single-select value currently attached to one project item.
nonisolated struct GitHubProjectSingleSelectValue: Codable, Equatable, Sendable {
    /// Field GraphQL node ID.
    let fieldID: String
    /// Selected option ID.
    let optionID: String
    /// Selected option name returned with the item.
    let name: String
    /// Last update of this exact field value.
    let updatedAt: Date
}

/// One ProjectV2 item shared by the table, board, filters, and drift auditor.
nonisolated struct GitHubProjectItem: Identifiable, Codable, Equatable, Sendable {
    /// Project item GraphQL node ID required by mutations.
    let id: String
    /// Server-side project item update timestamp.
    let updatedAt: Date
    /// Whether GitHub has archived the item.
    let isArchived: Bool
    /// Attached issue, pull request, draft, or redacted placeholder.
    let content: GitHubProjectItemContent
    /// All single-select values returned within the bounded item read.
    let singleSelectValues: [GitHubProjectSingleSelectValue]
    /// Whether all item field values were returned.
    let fieldValuesComplete: Bool

    /// Returns the exact field value, rejecting duplicate values as ambiguous.
    func singleSelectValue(fieldID: String) -> GitHubProjectSingleSelectValue? {
        let matches = singleSelectValues.filter { $0.fieldID == fieldID }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Stable digest binding a mutation preflight to content, relations, and field values.
    var evidenceDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Evidence showing whether a Project snapshot can support a healthy conclusion.
nonisolated struct GitHubProjectSnapshotCoverage: Codable, Equatable, Sendable {
    /// Whether every single-select field was fetched.
    let fieldsComplete: Bool
    /// Whether every non-archived project item was fetched.
    let itemsComplete: Bool
    /// Whether every project workflow was fetched.
    let workflowsComplete: Bool
    /// Item IDs with truncated or ambiguous field-value evidence.
    let incompleteFieldValueItemIDs: Set<String>
    /// Item IDs with truncated nested relationship evidence.
    let incompleteRelationshipItemIDs: Set<String>

    /// Whether all evidence required by the drift auditor is complete.
    var isComplete: Bool {
        fieldsComplete
            && itemsComplete
            && workflowsComplete
            && incompleteFieldValueItemIDs.isEmpty
            && incompleteRelationshipItemIDs.isEmpty
    }
}

/// Immutable ProjectV2 read used by every UI representation and analysis.
nonisolated struct GitHubProjectSnapshot: Codable, Equatable, Sendable {
    /// Organization that owns the project.
    let organization: GitHubProjectOrganization
    /// Exact project metadata captured with the item set.
    let project: GitHubProjectSummary
    /// All discovered single-select fields.
    let fields: [GitHubProjectSingleSelectField]
    /// All project items in GitHub order.
    let items: [GitHubProjectItem]
    /// Project workflow metadata.
    let workflows: [GitHubProjectWorkflow]
    /// Snapshot coverage proof.
    let coverage: GitHubProjectSnapshotCoverage
    /// GitHub viewer who performed the read.
    let principalID: String
    /// Local capture time.
    let capturedAt: Date

    /// Stable digest excluding local capture time.
    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(DigestPayload(
            organization: organization,
            project: project,
            fields: fields,
            items: items,
            workflows: workflows,
            coverage: DigestCoverage(coverage),
            principalID: principalID
        )) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Repositories represented by non-redacted content.
    var repositories: [GitHubRepositoryRef] {
        var seen = Set<String>()
        return items.compactMap(\.content.repository).filter { seen.insert($0.canonicalID).inserted }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// User-assigned semantic role for a field option.
nonisolated enum GitHubProjectLifecycleRole: String, CaseIterable, Codable, Sendable {
    /// Work accepted but not committed to immediate execution.
    case backlog
    /// Work selected for upcoming execution.
    case ready
    /// Work actively being implemented.
    case inProgress
    /// Work undergoing review or validation.
    case review
    /// Reviewed work waiting only for merge.
    case readyToMerge
    /// Successfully completed work.
    case done
    /// Deliberately canceled work.
    case canceled

    /// Whether the role represents an active lifecycle stage.
    var isActive: Bool { self != .done && self != .canceled }

    /// Localized role label.
    var displayName: String {
        switch self {
        case .backlog: String(localized: "Backlog")
        case .ready:
            String(localized: "GitHub Project lifecycle role ready", defaultValue: "Ready")
        case .inProgress: String(localized: "In progress")
        case .review: String(localized: "In review")
        case .readyToMerge: String(localized: "Ready to merge")
        case .done:
            String(localized: "GitHub Project lifecycle role done", defaultValue: "Done")
        case .canceled: String(localized: "Canceled")
        }
    }
}

/// Local semantic mapping used to interpret an arbitrary GitHub field safely.
nonisolated struct GitHubProjectDriftPolicy: Codable, Equatable, Sendable {
    /// Project node ID this policy belongs to.
    let projectID: String
    /// Single-select field node ID this policy belongs to.
    let fieldID: String
    /// Explicit semantic role by stable option ID.
    var roleByOptionID: [String: GitHubProjectLifecycleRole]
    /// Whether known parent, child, and closing relationships must also be project items.
    var requiresRelatedItemsInProject: Bool = false
    /// Whether every pull request must expose at least one closing issue relation.
    var requiresClosingIssueForPullRequest: Bool = false
    /// Whether an active parent with only terminal children should be reported.
    var completeParentWhenChildrenTerminal: Bool = false
    /// Workflow IDs that this project policy explicitly requires to be enabled.
    var expectedWorkflowIDs: Set<String> = []

    /// Creates an unclassified policy that cannot produce a healthy conclusion.
    static func empty(projectID: String, fieldID: String) -> GitHubProjectDriftPolicy {
        GitHubProjectDriftPolicy(projectID: projectID, fieldID: fieldID, roleByOptionID: [:])
    }

    /// Whether every current option has an explicit role and no removed option remains mapped.
    func completelyClassifies(_ field: GitHubProjectSingleSelectField) -> Bool {
        Set(roleByOptionID.keys) == Set(field.options.map(\.id))
    }

    /// Removes provider references only when the corresponding read proved complete coverage.
    func removingUnavailableReferences(
        currentOptionIDs: Set<String>,
        currentWorkflowIDs: Set<String>,
        fieldsComplete: Bool,
        workflowsComplete: Bool
    ) -> GitHubProjectDriftPolicy {
        var policy = self
        if fieldsComplete {
            policy.roleByOptionID = policy.roleByOptionID.filter { currentOptionIDs.contains($0.key) }
        }
        if workflowsComplete {
            policy.expectedWorkflowIDs.formIntersection(currentWorkflowIDs)
        }
        return policy
    }

    /// Stable digest binding a move confirmation to the exact local semantics.
    var digest: String {
        stableGitHubProjectDigest(PolicyDigestPayload(self))
    }
}

/// Deterministic class of Project planning drift.
nonisolated enum GitHubProjectDriftCategory: String, Codable, CaseIterable, Sendable {
    /// Content lifecycle and selected lane disagree.
    case lifecycle
    /// Active content remains in a terminal lane after reversal or reopening.
    case reverse
    /// Parent, child, issue, or pull-request linkage is missing from the project.
    case linkage
    /// Parent and known child completion state disagree.
    case rollUp
    /// An explicitly required workflow is unavailable or disabled.
    case automation

    /// Localized category label.
    var displayName: String {
        switch self {
        case .lifecycle: String(localized: "Lifecycle")
        case .reverse: String(localized: "Reverse transition")
        case .linkage: String(localized: "Linkage")
        case .rollUp: String(localized: "Roll-up")
        case .automation: String(localized: "Automation")
        }
    }
}

/// Operational severity of one drift finding.
nonisolated enum GitHubProjectDriftSeverity: Int, Codable, Comparable, Sendable {
    /// Informational relationship that deserves review.
    case notice = 0
    /// Likely stale planning state.
    case warning = 1
    /// Direct terminal/active contradiction.
    case critical = 2

    /// Comparable conformance for deterministic sorting.
    static func < (lhs: GitHubProjectDriftSeverity, rhs: GitHubProjectDriftSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Localized severity label.
    var displayName: String {
        switch self {
        case .notice: String(localized: "Notice")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }
}

/// One explainable finding tied to an exact Project item.
nonisolated struct GitHubProjectDriftFinding: Identifiable, Codable, Equatable, Sendable {
    /// Stable finding identity within a snapshot.
    let id: String
    /// Finding class.
    let category: GitHubProjectDriftCategory
    /// Operational severity.
    let severity: GitHubProjectDriftSeverity
    /// Project item that owns the finding.
    let itemID: String
    /// Concise localized title.
    let title: String
    /// Localized evidence explanation.
    let explanation: String
}

/// Confidence state for one drift analysis.
nonisolated enum GitHubProjectDriftAssessmentState: String, Codable, Sendable {
    /// Snapshot and explicit role mapping prove a complete assessment.
    case complete
    /// Known findings are useful, but missing evidence prevents an all-clear result.
    case partial
    /// The selected field still needs explicit option-role classification.
    case configurationRequired
}

/// Findings plus proof describing whether an all-clear result is justified.
nonisolated struct GitHubProjectDriftAssessment: Codable, Equatable, Sendable {
    /// Confidence state.
    let state: GitHubProjectDriftAssessmentState
    /// Deterministically ordered findings.
    let findings: [GitHubProjectDriftFinding]
    /// Option IDs not yet mapped to lifecycle semantics.
    let unclassifiedOptionIDs: Set<String>
    /// Human-readable evidence gaps.
    let evidenceGaps: [String]

    /// True only when complete evidence found no drift.
    var isProvenHealthy: Bool { state == .complete && findings.isEmpty }
}

/// Exact move requested for one Project item.
nonisolated struct GitHubProjectMoveIntent: Codable, Equatable, Sendable {
    /// Organization login used to re-resolve the project owner.
    let organizationLogin: String
    /// Project node ID.
    let projectID: String
    /// Item node ID.
    let itemID: String
    /// Single-select field node ID.
    let fieldID: String
    /// Destination option ID, or `nil` to clear the field.
    let destinationOptionID: String?
}

/// Confirmation level derived from content state and explicit lifecycle roles.
nonisolated enum GitHubProjectMoveRisk: String, Codable, Sendable {
    /// Movement between non-terminal roles.
    case routine
    /// Movement into or out of a terminal role.
    case terminal
    /// Movement would create an active/terminal contradiction.
    case contradictory
    /// Missing semantic or relationship evidence prevents low-risk classification.
    case unknown

    /// Whether the UI must ask for an explicit confirmation.
    var requiresConfirmation: Bool { self != .routine }
}

/// One-use proof binding a future mutation to fresh Project state.
nonisolated struct GitHubProjectMovePreflight: Codable, Equatable, Sendable {
    /// Unpredictable nonce registered in the issuing client.
    let nonce: String
    /// Exact move authorized by this proof.
    let intent: GitHubProjectMoveIntent
    /// GitHub principal that performed the preflight read.
    let principalID: String
    /// Field value observed immediately before confirmation.
    let sourceOptionID: String?
    /// Item update timestamp observed at preflight.
    let itemUpdatedAt: Date
    /// Full target-item evidence digest observed at preflight.
    let itemEvidenceDigest: String
    /// Field definition update timestamp observed at preflight.
    let fieldUpdatedAt: Date
    /// Complete field definition digest observed at preflight.
    let fieldDefinitionDigest: String
    /// Exact local drift semantics used for risk classification.
    let policyDigest: String
    /// Risk level shown to the user.
    let risk: GitHubProjectMoveRisk
    /// Time the preflight completed.
    let capturedAt: Date
}

/// Receipt for an accepted Project field mutation.
nonisolated struct GitHubProjectMutationReceipt: Codable, Equatable, Sendable {
    /// Exact Project item returned by the mutation.
    let itemID: String
    /// Client correlation ID echoed by GitHub when available.
    let clientMutationID: String?
    /// Destination option verified by a post-write read, or `nil` after a verified clear.
    let verifiedOptionID: String?
}

/// Local-only Project workspace context; authoritative GitHub items are never persisted.
nonisolated struct GitHubProjectBoardPreferences: Codable, Equatable, Sendable {
    /// Last organization login entered by the user.
    var organizationLogin = ""
    /// Last selected Project node ID.
    var selectedProjectID: String?
    /// Last selected single-select field node ID.
    var selectedFieldID: String?
    /// Last display mode.
    var viewMode = GitHubProjectViewMode.table
    /// Last local display filters.
    var filter = GitHubProjectBoardFilter()
    /// Explicit lifecycle and drift semantics for the selected field.
    var policy: GitHubProjectDriftPolicy?
}

/// Codable digest payload excluding local snapshot capture time.
private nonisolated struct DigestPayload: Codable {
    /// Project owner.
    let organization: GitHubProjectOrganization
    /// Project metadata.
    let project: GitHubProjectSummary
    /// Single-select field definitions.
    let fields: [GitHubProjectSingleSelectField]
    /// Project items.
    let items: [GitHubProjectItem]
    /// Workflow metadata.
    let workflows: [GitHubProjectWorkflow]
    /// Snapshot coverage.
    let coverage: DigestCoverage
    /// Viewer identity.
    let principalID: String
}

/// Canonical snapshot coverage used only for stable digest generation.
private nonisolated struct DigestCoverage: Codable {
    /// Whether every single-select field was fetched.
    let fieldsComplete: Bool
    /// Whether every non-archived project item was fetched.
    let itemsComplete: Bool
    /// Whether every project workflow was fetched.
    let workflowsComplete: Bool
    /// Canonically ordered item IDs with incomplete field values.
    let incompleteFieldValueItemIDs: [String]
    /// Canonically ordered item IDs with incomplete relationships.
    let incompleteRelationshipItemIDs: [String]

    /// Canonicalizes set-backed coverage without changing the runtime model.
    init(_ coverage: GitHubProjectSnapshotCoverage) {
        fieldsComplete = coverage.fieldsComplete
        itemsComplete = coverage.itemsComplete
        workflowsComplete = coverage.workflowsComplete
        incompleteFieldValueItemIDs = coverage.incompleteFieldValueItemIDs.sorted()
        incompleteRelationshipItemIDs = coverage.incompleteRelationshipItemIDs.sorted()
    }
}

/// Canonical policy payload used only for stable digest generation.
private nonisolated struct PolicyDigestPayload: Codable {
    /// Project node ID.
    let projectID: String
    /// Lifecycle field node ID.
    let fieldID: String
    /// Option semantics keyed by stable provider ID.
    let roleByOptionID: [String: GitHubProjectLifecycleRole]
    /// Related-item membership convention.
    let requiresRelatedItemsInProject: Bool
    /// Pull-request closing-issue convention.
    let requiresClosingIssueForPullRequest: Bool
    /// Parent roll-up convention.
    let completeParentWhenChildrenTerminal: Bool
    /// Canonically ordered required workflow IDs.
    let expectedWorkflowIDs: [String]

    /// Canonicalizes set-backed policy evidence without changing persisted preferences.
    init(_ policy: GitHubProjectDriftPolicy) {
        projectID = policy.projectID
        fieldID = policy.fieldID
        roleByOptionID = policy.roleByOptionID
        requiresRelatedItemsInProject = policy.requiresRelatedItemsInProject
        requiresClosingIssueForPullRequest = policy.requiresClosingIssueForPullRequest
        completeParentWhenChildrenTerminal = policy.completeParentWhenChildrenTerminal
        expectedWorkflowIDs = policy.expectedWorkflowIDs.sorted()
    }
}

/// Produces deterministic SHA-256 evidence for local and provider-backed Codable values.
private nonisolated func stableGitHubProjectDigest<Value: Encodable>(_ value: Value) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    guard let data = try? encoder.encode(value) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
