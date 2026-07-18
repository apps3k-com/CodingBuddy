//
//  GitHubProjectDriftAnalyzer.swift
//  CodingBuddy
//

import Foundation

/// Analysis interface used by the observable Project board store.
nonisolated protocol GitHubProjectDriftAnalyzing: Sendable {
    /// Audits one complete Project snapshot against an explicit field policy.
    func assess(
        snapshot: GitHubProjectSnapshot,
        fieldID: String,
        policy: GitHubProjectDriftPolicy
    ) -> GitHubProjectDriftAssessment

    /// Classifies the confirmation risk of one exact field move.
    func moveRisk(
        snapshot: GitHubProjectSnapshot,
        item: GitHubProjectItem,
        fieldID: String,
        destinationOptionID: String?,
        policy: GitHubProjectDriftPolicy
    ) -> GitHubProjectMoveRisk
}

/// Deterministic, fail-closed Project lifecycle and relationship auditor.
nonisolated struct GitHubProjectDriftAnalyzer: GitHubProjectDriftAnalyzing {
    /// Creates the stateless analyzer.
    init() {}

    /// Audits known evidence while preserving every reason an all-clear result is unavailable.
    func assess(
        snapshot: GitHubProjectSnapshot,
        fieldID: String,
        policy: GitHubProjectDriftPolicy
    ) -> GitHubProjectDriftAssessment {
        guard let field = snapshot.fields.first(where: { $0.id == fieldID }),
              policy.projectID == snapshot.project.id,
              policy.fieldID == fieldID else {
            return GitHubProjectDriftAssessment(
                state: .configurationRequired,
                findings: [],
                unclassifiedOptionIDs: [],
                evidenceGaps: [String(localized: "The selected project field is unavailable or has changed.")]
            )
        }

        let validOptionIDs = Set(field.options.map(\.id))
        let mappedOptionIDs = Set(policy.roleByOptionID.keys)
        let unclassifiedOptionIDs = validOptionIDs.subtracting(mappedOptionIDs)
        let removedOptionIDs = mappedOptionIDs.subtracting(validOptionIDs)
        var findings: [GitHubProjectDriftFinding] = []
        var evidenceGaps = coverageGaps(snapshot.coverage)
        let contentItemIDs = Dictionary(
            snapshot.items.compactMap { item in
                item.content.id.map { ($0, item.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        for item in snapshot.items where !item.isArchived {
            let matchingValues = item.singleSelectValues.filter { $0.fieldID == fieldID }
            var role: GitHubProjectLifecycleRole?
            if !item.fieldValuesComplete {
                role = nil
            } else if matchingValues.count != 1 {
                let explanation = matchingValues.isEmpty
                    ? String(format: String(localized: "%@ has no value for %@."), item.content.referenceLabel, field.name)
                    : String(format: String(localized: "%@ returned more than one value for %@."), item.content.referenceLabel, field.name)
                findings.append(finding(
                    category: .lifecycle,
                    severity: .warning,
                    item: item,
                    suffix: "field-value",
                    title: String(localized: "Lifecycle field needs attention"),
                    explanation: explanation
                ))
            } else if let value = matchingValues.first,
                      !validOptionIDs.contains(value.optionID) {
                findings.append(finding(
                    category: .lifecycle,
                    severity: .warning,
                    item: item,
                    suffix: "removed-option",
                    title: String(localized: "Project option no longer exists"),
                    explanation: String(
                        format: String(localized: "%@ still references the removed option %@."),
                        item.content.referenceLabel,
                        value.name
                    )
                ))
            } else if let value = matchingValues.first,
                      let mappedRole = policy.roleByOptionID[value.optionID] {
                role = mappedRole
                findings.append(contentsOf: lifecycleFindings(
                    item: item,
                    value: value,
                    role: mappedRole
                ))
            }

            if let role {
                findings.append(contentsOf: rollUpFindings(
                    item: item,
                    role: role,
                    contentItemIDs: contentItemIDs,
                    itemsComplete: snapshot.coverage.itemsComplete,
                    policy: policy
                ))
            }
            findings.append(contentsOf: linkageFindings(
                item: item,
                contentItemIDs: contentItemIDs,
                itemsComplete: snapshot.coverage.itemsComplete,
                policy: policy
            ))

            if !item.fieldValuesComplete {
                evidenceGaps.append(String(
                    format: String(localized: "Not every field value was available for %@."),
                    item.content.referenceLabel
                ))
            }
            if !item.content.relationCoverage.isComplete {
                evidenceGaps.append(String(
                    format: String(localized: "Not every relationship was available for %@."),
                    item.content.referenceLabel
                ))
            }
            if item.content.kind == .issue,
               item.content.state == .closed,
               item.content.issueStateReason == nil {
                evidenceGaps.append(String(
                    format: String(localized: "The issue completion reason is unavailable for %@."),
                    item.content.referenceLabel
                ))
            }
        }

        let automationFindings = automationFindings(snapshot: snapshot, policy: policy)
        findings.append(contentsOf: automationFindings)
        if !policy.expectedWorkflowIDs.isEmpty,
           snapshot.items.allSatisfy(\.isArchived),
           hasMissingExpectedWorkflow(snapshot: snapshot, policy: policy) {
            evidenceGaps.append(String(localized: "Required automation is missing, but no active Project item can own the finding."))
        }

        if !unclassifiedOptionIDs.isEmpty {
            evidenceGaps.append(String(
                format: String(localized: "%lld field options still need a lifecycle role."),
                Int64(unclassifiedOptionIDs.count)
            ))
        }
        if !removedOptionIDs.isEmpty {
            evidenceGaps.append(String(localized: "The selected project field is unavailable or has changed."))
        }
        let state: GitHubProjectDriftAssessmentState
        if !policy.completelyClassifies(field) {
            state = .configurationRequired
        } else if snapshot.coverage.isComplete && unclassifiedOptionIDs.isEmpty && evidenceGaps.isEmpty {
            state = .complete
        } else {
            state = .partial
        }

        return GitHubProjectDriftAssessment(
            state: state,
            findings: findings.sorted(by: findingOrder),
            unclassifiedOptionIDs: unclassifiedOptionIDs,
            evidenceGaps: Array(Set(evidenceGaps)).sorted()
        )
    }

    /// Classifies moves conservatively from current content and explicit option semantics.
    func moveRisk(
        snapshot: GitHubProjectSnapshot,
        item: GitHubProjectItem,
        fieldID: String,
        destinationOptionID: String?,
        policy: GitHubProjectDriftPolicy
    ) -> GitHubProjectMoveRisk {
        guard snapshot.coverage.isComplete,
              item.fieldValuesComplete,
              item.content.relationCoverage.isComplete,
              let field = snapshot.fields.first(where: { $0.id == fieldID }),
              policy.projectID == snapshot.project.id,
              policy.fieldID == fieldID,
              policy.completelyClassifies(field) else {
            return .unknown
        }
        let sourceOptionID = item.singleSelectValue(fieldID: fieldID)?.optionID
        let sourceRole = sourceOptionID.flatMap { policy.roleByOptionID[$0] }
        guard sourceOptionID != destinationOptionID else { return .routine }
        guard let destinationOptionID else {
            return sourceOptionID == nil ? .unknown : .terminal
        }
        guard field.options.contains(where: { $0.id == destinationOptionID }),
              let destinationRole = policy.roleByOptionID[destinationOptionID] else {
            return .unknown
        }

        switch item.content.state {
        case .open:
            if !destinationRole.isActive { return .contradictory }
        case .closed, .merged:
            if destinationRole.isActive { return .contradictory }
        case .draft, .unknown:
            return .unknown
        }
        if sourceRole?.isActive == false || !destinationRole.isActive || sourceRole == nil {
            return .terminal
        }
        return .routine
    }

    /// Produces content-versus-lane findings from explicit option semantics.
    private func lifecycleFindings(
        item: GitHubProjectItem,
        value: GitHubProjectSingleSelectValue,
        role: GitHubProjectLifecycleRole
    ) -> [GitHubProjectDriftFinding] {
        var findings: [GitHubProjectDriftFinding] = []
        switch item.content.state {
        case .closed where role.isActive,
             .merged where role.isActive:
            findings.append(finding(
                category: .lifecycle,
                severity: .critical,
                item: item,
                suffix: value.optionID,
                title: String(localized: "Terminal work remains active"),
                explanation: String(
                    format: String(localized: "%@ is %@ but remains in the active %@ lane."),
                    item.content.referenceLabel,
                    item.content.state.displayName,
                    value.name
                )
            ))
        case .open where !role.isActive:
            findings.append(finding(
                category: .reverse,
                severity: .critical,
                item: item,
                suffix: value.optionID,
                title: String(localized: "Active work remains terminal"),
                explanation: String(
                    format: String(localized: "%@ is open but remains in the terminal %@ lane."),
                    item.content.referenceLabel,
                    value.name
                )
            ))
        default:
            break
        }

        if item.content.kind == .issue,
           item.content.state == .closed,
           let reason = item.content.issueStateReason,
           (reason == .completed && role == .canceled)
            || (reason != .completed && role == .done) {
            findings.append(finding(
                category: .lifecycle,
                severity: .warning,
                item: item,
                suffix: "completion-reason-\(value.optionID)",
                title: String(localized: "Issue completion reason conflicts with the lane"),
                explanation: String(
                    format: String(localized: "%@ was closed with reason %@ but remains in %@."),
                    item.content.referenceLabel,
                    reason.rawValue,
                    value.name
                )
            ))
        }
        return findings
    }

    /// Detects known related content that is absent from the authoritative project snapshot.
    private func linkageFindings(
        item: GitHubProjectItem,
        contentItemIDs: [String: String],
        itemsComplete: Bool,
        policy: GitHubProjectDriftPolicy
    ) -> [GitHubProjectDriftFinding] {
        var findings: [GitHubProjectDriftFinding] = []
        if policy.requiresClosingIssueForPullRequest,
           item.content.kind == .pullRequest,
           item.content.linkedContent.isEmpty,
           item.content.relationCoverage.linkedContentComplete {
            findings.append(finding(
                category: .linkage,
                severity: .warning,
                item: item,
                suffix: "missing-closing-issue",
                title: String(localized: "Pull request does not close an issue"),
                explanation: String(
                    format: String(localized: "%@ has no closing issue relationship."),
                    item.content.referenceLabel
                )
            ))
        }
        guard policy.requiresRelatedItemsInProject, itemsComplete else { return findings }
        var references = item.content.linkedContent
        if let parent = item.content.parent { references.append(parent) }
        var seen = Set<String>()
        findings.append(contentsOf: references.compactMap { reference in
            guard seen.insert(reference.id).inserted,
                  contentItemIDs[reference.id] == nil else { return nil }
            return finding(
                category: .linkage,
                severity: .notice,
                item: item,
                suffix: reference.id,
                title: String(localized: "Related work is outside this project"),
                explanation: String(
                    format: String(localized: "%@ references %@, which is not a visible item in this project."),
                    item.content.referenceLabel,
                    reference.displayName
                )
            )
        })
        return findings
    }

    /// Detects parent completion that contradicts known child completion.
    private func rollUpFindings(
        item: GitHubProjectItem,
        role: GitHubProjectLifecycleRole,
        contentItemIDs: [String: String],
        itemsComplete: Bool,
        policy: GitHubProjectDriftPolicy
    ) -> [GitHubProjectDriftFinding] {
        let children = item.content.subIssues
        guard !children.isEmpty else { return [] }
        var findings: [GitHubProjectDriftFinding] = []
        let activeChildren = children.filter { !$0.state.isTerminal }
        if !role.isActive, let first = activeChildren.first {
            findings.append(finding(
                category: .rollUp,
                severity: .critical,
                item: item,
                suffix: first.id,
                title: String(localized: "Parent completed before its children"),
                explanation: String(
                    format: String(localized: "%@ is terminal while child %@ is still active."),
                    item.content.referenceLabel,
                    first.displayName
                )
            ))
        }
        if policy.completeParentWhenChildrenTerminal,
           role.isActive,
           item.content.relationCoverage.subIssuesComplete,
           children.allSatisfy(\.state.isTerminal) {
            findings.append(finding(
                category: .rollUp,
                severity: .warning,
                item: item,
                suffix: "all-terminal",
                title: String(localized: "Parent may be ready to complete"),
                explanation: String(
                    format: String(localized: "All %lld known children of %@ are terminal, but the parent remains active."),
                    Int64(children.count),
                    item.content.referenceLabel
                )
            ))
        }

        guard policy.requiresRelatedItemsInProject, itemsComplete else { return findings }
        let missingChildren = children.filter { contentItemIDs[$0.id] == nil }
        findings.append(contentsOf: missingChildren.prefix(1).map { child in
            finding(
                category: .linkage,
                severity: .notice,
                item: item,
                suffix: child.id,
                title: String(localized: "Child issue is outside this project"),
                explanation: String(
                    format: String(localized: "%@ tracks child %@, which is not a visible project item."),
                    item.content.referenceLabel,
                    child.displayName
                )
            )
        })
        return findings
    }

    /// Reports only workflows explicitly required by stable provider ID.
    private func automationFindings(
        snapshot: GitHubProjectSnapshot,
        policy: GitHubProjectDriftPolicy
    ) -> [GitHubProjectDriftFinding] {
        guard !policy.expectedWorkflowIDs.isEmpty else { return [] }
        let workflowsByID = Dictionary(uniqueKeysWithValues: snapshot.workflows.map { ($0.id, $0) })
        return policy.expectedWorkflowIDs.sorted().compactMap { workflowID in
            if let workflow = workflowsByID[workflowID] {
                guard !workflow.isEnabled else { return nil }
            } else if !snapshot.coverage.workflowsComplete {
                return nil
            }
            guard let item = snapshot.items.first(where: { !$0.isArchived }) else { return nil }
            return finding(
                category: .automation,
                severity: .warning,
                item: item,
                suffix: workflowID,
                title: String(localized: "Required project automation is unavailable"),
                explanation: String(
                    format: String(localized: "Required workflow %@ is missing or disabled."),
                    workflowID
                )
            )
        }
    }

    /// Whether at least one explicitly required workflow is absent or disabled.
    private func hasMissingExpectedWorkflow(
        snapshot: GitHubProjectSnapshot,
        policy: GitHubProjectDriftPolicy
    ) -> Bool {
        let workflowsByID = Dictionary(uniqueKeysWithValues: snapshot.workflows.map { ($0.id, $0) })
        return policy.expectedWorkflowIDs.contains { workflowID in
            if let workflow = workflowsByID[workflowID] { return !workflow.isEnabled }
            return snapshot.coverage.workflowsComplete
        }
    }

    /// Converts snapshot coverage proof into localized evidence gaps.
    private func coverageGaps(_ coverage: GitHubProjectSnapshotCoverage) -> [String] {
        var gaps: [String] = []
        if !coverage.fieldsComplete { gaps.append(String(localized: "The project field list is incomplete.")) }
        if !coverage.itemsComplete { gaps.append(String(localized: "The project item list is incomplete.")) }
        if !coverage.workflowsComplete { gaps.append(String(localized: "The project workflow list is incomplete.")) }
        if !coverage.incompleteFieldValueItemIDs.isEmpty {
            gaps.append(String(
                format: String(localized: "%lld items have incomplete field values."),
                Int64(coverage.incompleteFieldValueItemIDs.count)
            ))
        }
        if !coverage.incompleteRelationshipItemIDs.isEmpty {
            gaps.append(String(
                format: String(localized: "%lld items have incomplete relationship evidence."),
                Int64(coverage.incompleteRelationshipItemIDs.count)
            ))
        }
        return gaps
    }

    /// Creates a stable finding identity from immutable provider IDs.
    private func finding(
        category: GitHubProjectDriftCategory,
        severity: GitHubProjectDriftSeverity,
        item: GitHubProjectItem,
        suffix: String,
        title: String,
        explanation: String
    ) -> GitHubProjectDriftFinding {
        GitHubProjectDriftFinding(
            id: "\(item.id):\(category.rawValue):\(suffix)",
            category: category,
            severity: severity,
            itemID: item.id,
            title: title,
            explanation: explanation
        )
    }

    /// Orders high-severity findings first without depending on localized text.
    private func findingOrder(
        _ lhs: GitHubProjectDriftFinding,
        _ rhs: GitHubProjectDriftFinding
    ) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.category != rhs.category { return lhs.category.rawValue < rhs.category.rawValue }
        return lhs.id < rhs.id
    }
}
