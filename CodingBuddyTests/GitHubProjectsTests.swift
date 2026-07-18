//
//  GitHubProjectsTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Regression coverage for Project projection, drift evidence, and guarded provider boundaries.
@Suite(.serialized)
nonisolated struct GitHubProjectsTests {
    /// Stable fixture timestamp.
    private let now = Date(timeIntervalSince1970: 1_784_282_400)

    /// Missing field evidence cannot suppress an independent pull-request linkage finding.
    @Test func analyzerRunsIndependentRulesWhenLifecycleValueIsMissing() throws {
        let field = makeField()
        let item = makeItem(
            id: "ITEM1",
            kind: .pullRequest,
            state: .open,
            optionID: nil,
            linkedContent: []
        )
        let snapshot = makeSnapshot(field: field, items: [item])
        var policy = classifiedPolicy(field: field)
        policy.requiresClosingIssueForPullRequest = true

        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )

        #expect(assessment.findings.map(\.category).contains(.lifecycle))
        #expect(assessment.findings.map(\.category).contains(.linkage))
        #expect(!assessment.isProvenHealthy)
    }

    /// Arbitrary enabled workflows are not treated as proof or as actionable automation drift.
    @Test func analyzerAuditsOnlyExplicitExpectedWorkflowIDs() throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let enabled = GitHubProjectWorkflow(id: "WF1", name: "Unrelated", isEnabled: true, updatedAt: now)
        let snapshot = makeSnapshot(field: field, items: [item], workflows: [enabled])
        var policy = classifiedPolicy(field: field)

        let baseline = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )
        #expect(!baseline.findings.contains { $0.category == .automation })

        policy.expectedWorkflowIDs = ["WF2"]
        let required = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )
        #expect(required.findings.contains { $0.category == .automation })
    }

    /// Missing workflows become findings only when the workflow connection proves complete absence.
    @Test func analyzerDoesNotTreatIncompleteWorkflowReadAsDeletion() {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let complete = makeSnapshot(field: field, items: [item])
        let incomplete = GitHubProjectSnapshot(
            organization: complete.organization,
            project: complete.project,
            fields: complete.fields,
            items: complete.items,
            workflows: [],
            coverage: GitHubProjectSnapshotCoverage(
                fieldsComplete: true,
                itemsComplete: true,
                workflowsComplete: false,
                incompleteFieldValueItemIDs: [],
                incompleteRelationshipItemIDs: []
            ),
            principalID: complete.principalID,
            capturedAt: complete.capturedAt
        )
        var policy = classifiedPolicy(field: field)
        policy.expectedWorkflowIDs = ["WF-MISSING"]

        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: incomplete,
            fieldID: field.id,
            policy: policy
        )

        #expect(assessment.state == .partial)
        #expect(!assessment.findings.contains { $0.category == .automation })
        #expect(!assessment.isProvenHealthy)
    }

    /// Optional linkage and parent-completion conventions produce findings only when enabled.
    @Test func analyzerGatesTeamConventionsBehindExplicitPolicy() throws {
        let field = makeField()
        let child = GitHubProjectContentReference(
            id: "ISSUE2",
            repository: repository,
            number: 2,
            state: .closed
        )
        let parent = makeItem(
            id: "ITEM1",
            state: .open,
            optionID: "TODO",
            subIssues: [child]
        )
        let snapshot = makeSnapshot(field: field, items: [parent])
        var policy = classifiedPolicy(field: field)

        let baseline = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )
        #expect(!baseline.findings.contains { $0.category == .rollUp || $0.category == .linkage })

        policy.completeParentWhenChildrenTerminal = true
        policy.requiresRelatedItemsInProject = true
        let configured = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: policy
        )
        #expect(configured.findings.contains { $0.category == .rollUp })
        #expect(configured.findings.contains { $0.category == .linkage })
    }

    /// Missing related items are not classified as outside the Project until item pagination completes.
    @Test func analyzerSuppressesAbsenceFindingsForIncompleteItemConnection() {
        let field = makeField()
        let child = GitHubProjectContentReference(
            id: "ISSUE2",
            repository: repository,
            number: 2,
            state: .closed
        )
        let parent = makeItem(id: "ITEM1", state: .open, optionID: "TODO", subIssues: [child])
        let coverage = GitHubProjectSnapshotCoverage(
            fieldsComplete: true,
            itemsComplete: false,
            workflowsComplete: true,
            incompleteFieldValueItemIDs: [],
            incompleteRelationshipItemIDs: []
        )
        var policy = classifiedPolicy(field: field)
        policy.requiresRelatedItemsInProject = true

        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: makeSnapshot(field: field, items: [parent], coverage: coverage),
            fieldID: field.id,
            policy: policy
        )

        #expect(assessment.state == .partial)
        #expect(!assessment.findings.contains { $0.category == .linkage })
    }

    /// Unknown issue completion reasons remain evidence gaps instead of becoming healthy state.
    @Test func analyzerKeepsMissingIssueCompletionReasonFailClosed() throws {
        let field = makeField()
        let item = makeItem(
            id: "ITEM1",
            kind: .issue,
            state: .closed,
            issueStateReason: nil,
            optionID: "DONE"
        )
        let snapshot = makeSnapshot(field: field, items: [item])
        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: classifiedPolicy(field: field)
        )

        #expect(assessment.state == .partial)
        #expect(!assessment.evidenceGaps.isEmpty)
        #expect(!assessment.isProvenHealthy)
    }

    /// Unassigned items can enter a classified lane, while lifecycle contradictions stay explicit.
    @Test func moveRiskSupportsNoValueWithoutWeakeningContradictionChecks() throws {
        let field = makeField()
        let unassigned = makeItem(id: "ITEM1", state: .open, optionID: nil)
        let closed = makeItem(
            id: "ITEM2",
            state: .closed,
            issueStateReason: .completed,
            optionID: "DONE"
        )
        let snapshot = makeSnapshot(field: field, items: [unassigned, closed])
        let policy = classifiedPolicy(field: field)
        let analyzer = GitHubProjectDriftAnalyzer()

        #expect(analyzer.moveRisk(
            snapshot: snapshot,
            item: unassigned,
            fieldID: field.id,
            destinationOptionID: "TODO",
            policy: policy
        ) == .terminal)
        #expect(analyzer.moveRisk(
            snapshot: snapshot,
            item: closed,
            fieldID: field.id,
            destinationOptionID: "TODO",
            policy: policy
        ) == .contradictory)
    }

    /// Table and Board consume the exact same filtered item identities, including `No value`.
    @Test func projectionKeepsTableAndBoardIdentitySetsEqual() throws {
        let field = makeField()
        let assigned = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let unassigned = makeItem(id: "ITEM2", state: .open, optionID: nil)
        let snapshot = makeSnapshot(field: field, items: [assigned, unassigned])
        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: classifiedPolicy(field: field)
        )

        let projection = try #require(GitHubProjectBoardProjection.make(
            snapshot: snapshot,
            fieldID: field.id,
            assessment: assessment,
            filter: GitHubProjectBoardFilter()
        ))

        #expect(Set(projection.tableItemIDs) == Set(projection.boardItemIDs))
        #expect(projection.boardItemIDs.count == projection.tableItemIDs.count)
        #expect(projection.rows(columnID: GitHubProjectBoardColumn.noValueID).map(\.id) == ["ITEM2"])
    }

    /// Repository filtering keeps redacted content visible with unknown scope evidence.
    @Test func projectionDoesNotHideRedactedItemsBehindRepositoryFilter() throws {
        let field = makeField()
        let visible = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let redacted = makeItem(
            id: "ITEM2",
            kind: .redacted,
            state: .unknown,
            optionID: "TODO",
            repository: nil,
            relationCoverage: GitHubProjectRelationCoverage(
                subIssuesComplete: false,
                linkedContentComplete: false
            )
        )
        let snapshot = makeSnapshot(
            field: field,
            items: [visible, redacted],
            incompleteRelationshipItemIDs: ["ITEM2"]
        )
        let assessment = GitHubProjectDriftAnalyzer().assess(
            snapshot: snapshot,
            fieldID: field.id,
            policy: classifiedPolicy(field: field)
        )
        var filter = GitHubProjectBoardFilter()
        filter.repositoryIDs = [repository.canonicalID]

        let projection = try #require(GitHubProjectBoardProjection.make(
            snapshot: snapshot,
            fieldID: field.id,
            assessment: assessment,
            filter: filter
        ))

        #expect(projection.rows.map(\.id) == ["ITEM1", "ITEM2"])
        #expect(projection.rows.last?.scopeMembership == .unknown)
    }

    /// Field and policy digests change when any mutation-relevant definition changes.
    @Test func preflightDigestsBindFieldAndPolicyDefinitions() throws {
        let field = makeField()
        var policy = classifiedPolicy(field: field)
        let initialPolicyDigest = policy.digest
        policy.requiresClosingIssueForPullRequest = true

        let renamedField = GitHubProjectSingleSelectField(
            id: field.id,
            name: field.name,
            updatedAt: field.updatedAt,
            options: [
                GitHubProjectSingleSelectOption(
                    id: "TODO",
                    name: "Queued",
                    description: nil,
                    color: .gray
                ),
                field.options[1],
            ]
        )

        #expect(policy.digest != initialPolicyDigest)
        #expect(field.definitionDigest != renamedField.definitionDigest)
        #expect(field.definitionDigest.count == 64)
    }

    /// Set insertion order cannot change snapshot or policy evidence digests.
    @Test func evidenceDigestsCanonicalizeSetBackedValues() {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let firstCoverage = GitHubProjectSnapshotCoverage(
            fieldsComplete: true,
            itemsComplete: false,
            workflowsComplete: true,
            incompleteFieldValueItemIDs: Set(["ITEM2", "ITEM1"]),
            incompleteRelationshipItemIDs: Set(["ITEM4", "ITEM3"])
        )
        let secondCoverage = GitHubProjectSnapshotCoverage(
            fieldsComplete: true,
            itemsComplete: false,
            workflowsComplete: true,
            incompleteFieldValueItemIDs: Set(["ITEM1", "ITEM2"]),
            incompleteRelationshipItemIDs: Set(["ITEM3", "ITEM4"])
        )
        let firstSnapshot = makeSnapshot(field: field, items: [item], coverage: firstCoverage)
        let secondSnapshot = makeSnapshot(field: field, items: [item], coverage: secondCoverage)
        var firstPolicy = classifiedPolicy(field: field)
        firstPolicy.expectedWorkflowIDs = Set(["WF2", "WF1"])
        var secondPolicy = classifiedPolicy(field: field)
        secondPolicy.expectedWorkflowIDs = Set(["WF1", "WF2"])

        #expect(firstSnapshot.digest == secondSnapshot.digest)
        #expect(firstPolicy.digest == secondPolicy.digest)
        #expect(firstSnapshot.digest == "0f0414380381332b9675a6e3ed09fc0f35ee3ab99424f07c20772d760eabae46")
        #expect(firstPolicy.digest == "1576912cf4a226382f5b9778a4b1f147d6f0f5c57893886ad86fcbbe8dc8fd96")
    }

    /// A personal access token is rejected before a Project preflight can call the network.
    @Test func prepareMoveRejectsPATBeforeNetwork() async throws {
        let transport = GitHubProjectsRecordingTransport(responses: [])
        let client = GitHubProjectsClient(transport: transport)
        let field = makeField()

        await #expect(throws: GitHubProjectsError.writesNotAllowed) {
            try await client.prepareMove(
                organizationLogin: "apps3k-com",
                projectID: "PROJECT1",
                itemID: "ITEM1",
                fieldID: field.id,
                destinationOptionID: "DONE",
                policy: classifiedPolicy(field: field),
                credential: .personalAccessToken("pat-token")
            )
        }
        #expect(await transport.requestCount == 0)
    }

    /// Repeated provider cursors fail closed during Project discovery.
    @Test func discoveryRejectsCursorCycles() async throws {
        let transport = GitHubProjectsRecordingTransport(responses: [
            .ok(Self.discoveryPage(projectID: "P1", total: 3, next: "cycle")),
            .ok(Self.discoveryPage(projectID: "P2", total: 3, next: "cycle")),
        ])
        let client = GitHubProjectsClient(transport: transport, pageSize: 1)

        await #expect(throws: GitHubProjectsError.incompletePagination) {
            try await client.discoverProjects(organizationLogin: "apps3k-com", token: "token")
        }
        #expect(await transport.requestCount == 2)
    }

    /// GraphQL partial data plus a permission error is never accepted as a Project result.
    @Test func discoveryRejectsPartialPermissionErrors() async throws {
        let response = #"{"data":{"viewer":{"id":"VIEWER1"},"organization":null},"errors":[{"type":"FORBIDDEN"}]}"#
        let transport = GitHubProjectsRecordingTransport(responses: [.ok(response)])
        let client = GitHubProjectsClient(transport: transport)

        await #expect(throws: GitHubProjectsError.missingPermission) {
            try await client.discoverProjects(organizationLogin: "apps3k-com", token: "token")
        }
    }

    /// Preference persistence contains local context and policy only, never provider item snapshots.
    @MainActor
    @Test func storePersistsOnlyWorkspacePreferences() throws {
        let suite = "GitHubProjectsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GitHubProjectsStore(defaults: defaults)

        store.setOrganizationLogin("apps3k-com")

        let data = try #require(defaults.data(forKey: GitHubProjectsStore.preferencesKey))
        let decoded = try JSONDecoder().decode(GitHubProjectBoardPreferences.self, from: data)
        #expect(decoded.organizationLogin == "apps3k-com")
        #expect(!String(decoding: data, as: UTF8.self).contains("items"))
        #expect(!String(decoding: data, as: UTF8.self).contains("snapshot"))
    }

    /// Declining a terminal move revokes its one-use preflight and releases the store.
    @MainActor
    @Test func storeCancelRevokesPendingMovePreflight() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .terminal
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))

        store.requestMove(itemID: item.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }
        store.cancelPendingMove()
        try await waitUntil { await service.discardCount == 1 }

        #expect(store.pendingPreflight == nil)
        #expect(store.moveState == .idle)
        #expect(store.movesAreEnabled)
    }

    /// Authorization invalidation before execution revokes the proof without attempting a mutation.
    @MainActor
    @Test func storeCanceledConfirmationCannotApplyMove() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .terminal
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        store.requestMove(itemID: item.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }

        store.confirmPendingMove()
        store.handleGitHubAuthorizationChange(.removed)
        try await waitUntil { await service.discardCount == 1 }

        #expect(await service.applyCount == 0)
        #expect(store.moveState == .idle)
    }

    /// Policy edits cannot invalidate a preflight while leaving its move lifecycle locked.
    @MainActor
    @Test func storeRejectsPolicyEditsWhileMoveAwaitsConfirmation() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .terminal
        )
        let store = makeStore(service: service)
        try await load(store: store)
        let originalPolicy = classifiedPolicy(field: field)
        store.updatePolicy(originalPolicy)
        store.requestMove(itemID: item.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }

        var changedPolicy = originalPolicy
        changedPolicy.requiresRelatedItemsInProject = true
        store.updatePolicy(changedPolicy)

        #expect(store.preferences.policy == originalPolicy)
        #expect(store.pendingPreflight != nil)
        #expect(store.moveState == .awaitingConfirmation)
        #expect(!store.movesAreEnabled)
    }

    /// An ambiguous write blocks new moves until an exact destination readback succeeds.
    @MainActor
    @Test func storeReconcilesAmbiguousMoveWithoutRetryingMutation() async throws {
        let field = makeField()
        let source = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let destination = makeItem(id: "ITEM1", state: .open, optionID: "DONE")
        let initial = makeSnapshot(field: field, items: [source])
        let verified = makeSnapshot(field: field, items: [destination])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [initial, verified],
            prepareSnapshot: initial,
            prepareRisk: .terminal,
            applyError: .ambiguousWrite
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        store.requestMove(itemID: source.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }

        store.confirmPendingMove()
        try await waitUntil { store.moveState == .ambiguous }
        #expect(!store.movesAreEnabled)
        #expect(await service.applyCount == 1)

        store.verifyAmbiguousMove()
        try await waitUntil {
            if case .succeeded = store.moveState { return true }
            return false
        }

        #expect(store.snapshot?.items.first?.singleSelectValue(fieldID: field.id)?.optionID == "DONE")
        #expect(await service.applyCount == 1)
    }

    /// Discovery in progress disables moves until the selected Project is confirmed again.
    @MainActor
    @Test func storeDisablesMovesWhileRediscoveryIsLoading() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let list = projectList()
        let service = GitHubProjectsStoreService(
            projectList: list,
            rediscoveredProjectLists: [list],
            fetchSnapshots: [snapshot, snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .routine
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        #expect(store.movesAreEnabled)

        store.discoverProjects()

        #expect(store.discoveryState == .loading)
        #expect(!store.movesAreEnabled)
        try await waitUntil {
            let fetchCount = await service.fetchCount
            return store.snapshotState == .loaded
                && store.discoveryState == .loaded
                && fetchCount == 2
        }
        #expect(store.movesAreEnabled)
    }

    /// Rediscovery removes stale Project, policy, snapshot, and mutation state from memory and persistence.
    @MainActor
    @Test func storeRediscoveryClearsRemovedSelectedProject() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let emptyList = GitHubProjectList(
            organization: GitHubProjectOrganization(id: "ORG1", login: "apps3k-com"),
            projects: [],
            isTruncated: false
        )
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            rediscoveredProjectLists: [emptyList],
            fetchSnapshots: [snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .routine
        )
        let suite = "GitHubProjectsRediscovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(service: service, defaults: defaults)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        #expect(store.movesAreEnabled)

        store.discoverProjects()
        try await waitUntil { store.discoveryState == .loaded }

        #expect(store.projectList?.projects.isEmpty == true)
        #expect(store.preferences.selectedProjectID == nil)
        #expect(store.preferences.selectedFieldID == nil)
        #expect(store.preferences.policy == nil)
        #expect(store.snapshot == nil)
        #expect(store.assessment == nil)
        #expect(store.projection == nil)
        #expect(store.snapshotState == .idle)
        #expect(store.moveState == .idle)
        #expect(store.pendingPreflight == nil)
        #expect(!store.movesAreEnabled)

        let data = try #require(defaults.data(forKey: GitHubProjectsStore.preferencesKey))
        let persisted = try JSONDecoder().decode(GitHubProjectBoardPreferences.self, from: data)
        #expect(persisted.selectedProjectID == nil)
        #expect(persisted.selectedFieldID == nil)
        #expect(persisted.policy == nil)
    }

    /// Truncated discovery cannot prove that an absent selected Project was removed.
    @MainActor
    @Test func storeRediscoveryRetainsSelectedProjectWhenDiscoveryIsTruncated() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let truncatedList = GitHubProjectList(
            organization: GitHubProjectOrganization(id: "ORG1", login: "apps3k-com"),
            projects: [],
            isTruncated: true
        )
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            rediscoveredProjectLists: [truncatedList],
            fetchSnapshots: [snapshot, snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .routine
        )
        let store = makeStore(service: service)
        try await load(store: store)
        let policy = classifiedPolicy(field: field)
        store.updatePolicy(policy)

        store.discoverProjects()
        try await waitUntil { await service.fetchCount == 2 && store.snapshotState == .loaded }

        #expect(store.projectList?.isTruncated == true)
        #expect(store.projectList?.projects.map(\.id) == ["PROJECT1"])
        #expect(store.preferences.selectedProjectID == "PROJECT1")
        #expect(store.preferences.selectedFieldID == field.id)
        #expect(store.preferences.policy == policy)
        #expect(store.snapshot == snapshot)
    }

    /// Incomplete field coverage cannot prove that a selected field and its policy were removed.
    @MainActor
    @Test func storeRetainsPolicyWhenSelectedFieldIsAbsentFromIncompleteSnapshot() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let incomplete = GitHubProjectSnapshot(
            organization: snapshot.organization,
            project: snapshot.project,
            fields: [],
            items: snapshot.items,
            workflows: snapshot.workflows,
            coverage: GitHubProjectSnapshotCoverage(
                fieldsComplete: false,
                itemsComplete: true,
                workflowsComplete: true,
                incompleteFieldValueItemIDs: [],
                incompleteRelationshipItemIDs: []
            ),
            principalID: snapshot.principalID,
            capturedAt: snapshot.capturedAt
        )
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [snapshot, incomplete],
            prepareSnapshot: snapshot,
            prepareRisk: .routine
        )
        let store = makeStore(service: service)
        try await load(store: store)
        let policy = classifiedPolicy(field: field)
        store.updatePolicy(policy)

        store.refreshSnapshot()
        try await waitUntil { await service.fetchCount == 2 && store.snapshotState == .loaded }

        #expect(store.preferences.selectedFieldID == field.id)
        #expect(store.preferences.policy == policy)
        #expect(store.snapshot == incomplete)
        #expect(store.projection == nil)
        #expect(!store.movesAreEnabled)
    }

    /// Incomplete post-write evidence keeps an ambiguous mutation locked for later verification.
    @MainActor
    @Test func storeKeepsAmbiguousWriteLockedWhenVerificationEvidenceIsIncomplete() async throws {
        let field = makeField()
        let source = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let destination = makeItem(id: "ITEM1", state: .open, optionID: "DONE")
        let initial = makeSnapshot(field: field, items: [source])
        let verified = makeSnapshot(field: field, items: [destination])
        let missingItem = makeSnapshot(field: field, items: [])
        let incompleteValues = GitHubProjectItem(
            id: source.id,
            updatedAt: source.updatedAt,
            isArchived: source.isArchived,
            content: source.content,
            singleSelectValues: source.singleSelectValues,
            fieldValuesComplete: false
        )
        let incompleteCoverage = makeSnapshot(field: field, items: [source])
        let verificationSnapshots = [
            GitHubProjectSnapshot(
                organization: incompleteCoverage.organization,
                project: incompleteCoverage.project,
                fields: incompleteCoverage.fields,
                items: incompleteCoverage.items,
                workflows: incompleteCoverage.workflows,
                coverage: GitHubProjectSnapshotCoverage(
                    fieldsComplete: true,
                    itemsComplete: false,
                    workflowsComplete: true,
                    incompleteFieldValueItemIDs: [],
                    incompleteRelationshipItemIDs: []
                ),
                principalID: incompleteCoverage.principalID,
                capturedAt: incompleteCoverage.capturedAt
            ),
            makeSnapshot(field: field, items: [incompleteValues]),
            missingItem,
            GitHubProjectSnapshot(
                organization: initial.organization,
                project: initial.project,
                fields: [],
                items: [source],
                workflows: initial.workflows,
                coverage: initial.coverage,
                principalID: initial.principalID,
                capturedAt: initial.capturedAt
            ),
        ]

        for verification in verificationSnapshots {
            let service = GitHubProjectsStoreService(
                projectList: projectList(),
                fetchSnapshots: [initial, verification, verified],
                prepareSnapshot: initial,
                prepareRisk: .terminal,
                applyError: .ambiguousWrite
            )
            let store = makeStore(service: service)
            try await load(store: store)
            store.updatePolicy(classifiedPolicy(field: field))
            store.requestMove(itemID: source.id, destinationOptionID: "DONE")
            try await waitUntil { store.pendingPreflight != nil }
            store.confirmPendingMove()
            try await waitUntil { store.moveState == .ambiguous }

            store.verifyAmbiguousMove()
            try await waitUntil { await service.fetchCount == 2 }

            #expect(store.moveState == .ambiguous)
            #expect(!store.movesAreEnabled)
            #expect(await service.applyCount == 1)

            store.verifyAmbiguousMove()
            try await waitUntil {
                if case .succeeded = store.moveState { return true }
                return false
            }
            #expect(await service.fetchCount == 3)
            #expect(await service.applyCount == 1)
        }
    }

    /// An uncertain write survives store recreation until an exact provider readback resolves it.
    @MainActor
    @Test func storePersistsAmbiguousWriteAcrossRestart() async throws {
        let field = makeField()
        let source = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let destination = makeItem(id: "ITEM1", state: .open, optionID: "DONE")
        let initial = makeSnapshot(field: field, items: [source])
        let verified = makeSnapshot(field: field, items: [destination])
        let suite = "GitHubProjectsAmbiguousRestart-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstService = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [initial],
            prepareSnapshot: initial,
            prepareRisk: .terminal,
            applyError: .ambiguousWrite
        )
        let firstStore = makeStore(service: firstService, defaults: defaults)
        try await load(store: firstStore)
        firstStore.updatePolicy(classifiedPolicy(field: field))
        firstStore.requestMove(itemID: source.id, destinationOptionID: "DONE")
        try await waitUntil { firstStore.pendingPreflight != nil }
        firstStore.confirmPendingMove()
        try await waitUntil { firstStore.moveState == .ambiguous }
        #expect(defaults.data(forKey: GitHubProjectsStore.ambiguousMoveKey)?.isEmpty == false)

        let recoveryService = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [verified],
            prepareSnapshot: verified,
            prepareRisk: .routine
        )
        let recoveredStore = makeStore(service: recoveryService, defaults: defaults)
        #expect(recoveredStore.moveState == .ambiguous)
        #expect(!recoveredStore.movesAreEnabled)

        recoveredStore.verifyAmbiguousMove()
        try await waitUntil {
            if case .succeeded = recoveredStore.moveState { return true }
            return false
        }
        #expect(defaults.data(forKey: GitHubProjectsStore.ambiguousMoveKey)?.isEmpty == true)

        let restartedStore = makeStore(service: recoveryService, defaults: defaults)
        #expect(restartedStore.moveState == .idle)
    }

    /// Credential changes clear private snapshots but never unlock an unreconciled provider write.
    @MainActor
    @Test func storeAuthorizationChangePreservesAmbiguousWriteLock() async throws {
        let field = makeField()
        let source = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let initial = makeSnapshot(field: field, items: [source])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [initial],
            prepareSnapshot: initial,
            prepareRisk: .terminal,
            applyError: .ambiguousWrite
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        store.requestMove(itemID: source.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }
        store.confirmPendingMove()
        try await waitUntil { store.moveState == .ambiguous }

        store.handleGitHubAuthorizationChange(.removed)

        #expect(store.moveState == .ambiguous)
        #expect(!store.movesAreEnabled)
        #expect(store.snapshot == nil)
        #expect(store.preferences.selectedProjectID == nil)
        #expect(await service.applyCount == 1)
    }

    /// A deterministic pre-write failure releases provisional ambiguity and permits a fresh preflight.
    @MainActor
    @Test func storeDeterministicApplyFailureDoesNotLeaveHiddenWriteLock() async throws {
        let field = makeField()
        let source = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let initial = makeSnapshot(field: field, items: [source])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [initial],
            prepareSnapshot: initial,
            prepareRisk: .terminal,
            applyError: .driftDetected
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))
        store.requestMove(itemID: source.id, destinationOptionID: "DONE")
        try await waitUntil { store.pendingPreflight != nil }

        store.confirmPendingMove()
        try await waitUntil { store.moveState == .drifted }

        #expect(store.movesAreEnabled)
        #expect(await service.applyCount == 1)
    }

    /// Credential removal clears every provider-backed row and persisted provider selection.
    @MainActor
    @Test func storeAuthorizationRemovalClearsPrivateProjectState() async throws {
        let field = makeField()
        let item = makeItem(id: "ITEM1", state: .open, optionID: "TODO")
        let snapshot = makeSnapshot(field: field, items: [item])
        let service = GitHubProjectsStoreService(
            projectList: projectList(),
            fetchSnapshots: [snapshot],
            prepareSnapshot: snapshot,
            prepareRisk: .routine
        )
        let store = makeStore(service: service)
        try await load(store: store)
        store.updatePolicy(classifiedPolicy(field: field))

        store.handleGitHubAuthorizationChange(.removed)

        #expect(store.projectList == nil)
        #expect(store.snapshot == nil)
        #expect(store.assessment == nil)
        #expect(store.projection == nil)
        #expect(store.preferences.selectedProjectID == nil)
        #expect(store.preferences.selectedFieldID == nil)
        #expect(store.preferences.policy == nil)
        #expect(store.discoveryState == .idle)
        #expect(store.snapshotState == .idle)
        #expect(store.moveState == .idle)
    }

    /// Stable repository fixture.
    private var repository: GitHubRepositoryRef {
        GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy")
    }

    /// One discovered Project list fixture.
    private func projectList() -> GitHubProjectList {
        GitHubProjectList(
            organization: GitHubProjectOrganization(id: "ORG1", login: "apps3k-com"),
            projects: [GitHubProjectSummary(
                id: "PROJECT1",
                number: 13,
                title: "CodingBuddy",
                url: URL(string: "https://github.com/orgs/apps3k-com/projects/13")!,
                isClosed: false,
                viewerCanUpdate: true,
                updatedAt: now
            )],
            isTruncated: false
        )
    }

    /// Creates a store with an in-memory GitHub App credential.
    @MainActor
    private func makeStore(
        service: GitHubProjectsStoreService,
        defaults: UserDefaults? = nil
    ) -> GitHubProjectsStore {
        let credential = GitHubCredential(
            source: .githubAppDeviceFlow,
            accessToken: "device-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: nil,
            refreshTokenExpiresAt: nil
        )
        return GitHubProjectsStore(
            client: service,
            credentialCoordinator: GitHubCredentialCoordinator(
                tokenStore: GitHubProjectsCredentialStore(credential: credential),
                oauthClient: nil
            ),
            defaults: defaults ?? UserDefaults(suiteName: "GitHubProjectsStore-\(UUID().uuidString)")!
        )
    }

    /// Loads discovery and the selected Project through public store methods.
    @MainActor
    private func load(store: GitHubProjectsStore) async throws {
        store.setOrganizationLogin("apps3k-com")
        store.discoverProjects()
        try await waitUntil { store.discoveryState == .loaded }
        store.selectProject(id: "PROJECT1")
        try await waitUntil { store.snapshotState == .loaded }
    }

    /// Waits for an observable state transition without wall-clock sleeps.
    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw GitHubProjectsStoreTestError.timedOut
    }

    /// Complete field fixture with active and terminal semantics.
    private func makeField() -> GitHubProjectSingleSelectField {
        GitHubProjectSingleSelectField(
            id: "STATUS",
            name: "Status",
            updatedAt: now,
            options: [
                GitHubProjectSingleSelectOption(
                    id: "TODO",
                    name: "Todo",
                    description: nil,
                    color: .gray
                ),
                GitHubProjectSingleSelectOption(
                    id: "DONE",
                    name: "Done",
                    description: nil,
                    color: .green
                ),
            ]
        )
    }

    /// Fully classified policy fixture.
    private func classifiedPolicy(field: GitHubProjectSingleSelectField) -> GitHubProjectDriftPolicy {
        var policy = GitHubProjectDriftPolicy.empty(projectID: "PROJECT1", fieldID: field.id)
        policy.roleByOptionID = ["TODO": .inProgress, "DONE": .done]
        return policy
    }

    /// One normalized Project item fixture.
    private func makeItem(
        id: String,
        kind: GitHubProjectContentKind = .issue,
        state: GitHubProjectContentState,
        issueStateReason: GitHubProjectIssueStateReason? = nil,
        optionID: String?,
        repository: GitHubRepositoryRef? = GitHubRepositoryRef(owner: "apps3k-com", name: "CodingBuddy"),
        parent: GitHubProjectContentReference? = nil,
        subIssues: [GitHubProjectContentReference] = [],
        linkedContent: [GitHubProjectContentReference] = [],
        relationCoverage: GitHubProjectRelationCoverage = .notApplicable
    ) -> GitHubProjectItem {
        GitHubProjectItem(
            id: id,
            updatedAt: now,
            isArchived: false,
            content: GitHubProjectItemContent(
                id: kind == .redacted ? nil : "CONTENT-\(id)",
                kind: kind,
                title: "Item \(id)",
                number: kind == .issue || kind == .pullRequest ? Int(id.filter(\.isNumber)) : nil,
                url: kind == .redacted ? nil : URL(string: "https://github.com/apps3k-com/CodingBuddy/issues/1"),
                repository: repository,
                state: state,
                issueStateReason: issueStateReason,
                isDraftPullRequest: false,
                updatedAt: now,
                terminalAt: state.isTerminal ? now : nil,
                parent: parent,
                subIssues: subIssues,
                linkedContent: linkedContent,
                relationCoverage: relationCoverage
            ),
            singleSelectValues: optionID.map {
                [GitHubProjectSingleSelectValue(
                    fieldID: "STATUS",
                    optionID: $0,
                    name: $0,
                    updatedAt: now
                )]
            } ?? [],
            fieldValuesComplete: true
        )
    }

    /// Complete Project snapshot fixture.
    private func makeSnapshot(
        field: GitHubProjectSingleSelectField,
        items: [GitHubProjectItem],
        workflows: [GitHubProjectWorkflow] = [],
        incompleteRelationshipItemIDs: Set<String> = [],
        coverage: GitHubProjectSnapshotCoverage? = nil
    ) -> GitHubProjectSnapshot {
        GitHubProjectSnapshot(
            organization: GitHubProjectOrganization(id: "ORG1", login: "apps3k-com"),
            project: GitHubProjectSummary(
                id: "PROJECT1",
                number: 13,
                title: "CodingBuddy",
                url: URL(string: "https://github.com/orgs/apps3k-com/projects/13")!,
                isClosed: false,
                viewerCanUpdate: true,
                updatedAt: now
            ),
            fields: [field],
            items: items,
            workflows: workflows,
            coverage: coverage ?? GitHubProjectSnapshotCoverage(
                fieldsComplete: true,
                itemsComplete: true,
                workflowsComplete: true,
                incompleteFieldValueItemIDs: [],
                incompleteRelationshipItemIDs: incompleteRelationshipItemIDs
            ),
            principalID: "VIEWER1",
            capturedAt: now
        )
    }

    /// One deterministic organization Project discovery page.
    private static func discoveryPage(projectID: String, total: Int, next: String?) -> String {
        let hasNext = next != nil ? "true" : "false"
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return #"{"data":{"viewer":{"id":"VIEWER1"},"organization":{"id":"ORG1","login":"apps3k-com","projectsV2":{"totalCount":\#(total),"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":\#(cursor)},"nodes":[{"id":"\#(projectID)","number":13,"title":"Project \#(projectID)","url":"https://github.com/orgs/apps3k-com/projects/13","closed":false,"updatedAt":"2026-07-17T10:00:00Z","viewerCanUpdate":true}]}}}}"#
    }
}

/// Localization and accessibility contracts for the GitHub Projects workspace.
nonisolated struct GitHubProjectsLocalizationTests {
    /// Repository root derived without touching user configuration.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// New production sources that own Project-facing copy.
    private var sourceURLs: [URL] {
        [
            "CodingBuddy/Models/GitHubProjectsModels.swift",
            "CodingBuddy/Services/GitHubProjectBoardProjection.swift",
            "CodingBuddy/Services/GitHubProjectDriftAnalyzer.swift",
            "CodingBuddy/Services/GitHubProjectsClient.swift",
            "CodingBuddy/Stores/GitHubProjectsStore.swift",
            "CodingBuddy/Views/GitHubProjectsView.swift",
        ].map { repositoryRoot.appendingPathComponent($0) }
    }

    /// Every statically keyed Project string has a non-empty German translation.
    @Test func projectInterfaceCopyHasGermanTranslations() throws {
        let strings = try catalogStrings()
        let keys = try extractedStaticKeys()

        #expect(!keys.isEmpty)
        for key in keys {
            let entry = try #require(strings[key], "Missing catalog key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            #expect(unit["state"] as? String == "translated")
            #expect((unit["value"] as? String)?.isEmpty == false)
        }
    }

    /// Dynamic VoiceOver formats preserve every typed placeholder in German.
    @Test func projectAccessibilityFormatsPreservePlaceholders() throws {
        let strings = try catalogStrings()
        for key in ["%lld items", "%@, %@", "%lld drift findings"] {
            let entry = try #require(strings[key])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let german = try #require(localizations["de"] as? [String: Any])
            let unit = try #require(german["stringUnit"] as? [String: Any])
            let value = try #require(unit["value"] as? String)
            #expect(value.components(separatedBy: "%lld").count == key.components(separatedBy: "%lld").count)
            #expect(value.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count)
        }
    }

    /// Extracts direct localized and SwiftUI string keys, excluding interpolated source literals.
    private func extractedStaticKeys() throws -> Set<String> {
        let patterns = [
            #"String\(localized:\s*\"([^\"]+)\""#,
            #"(?:Text|Label|Button|Link|ContentUnavailableView|Section|Picker|TextField|Menu|Toggle|navigationTitle|help|accessibilityLabel|accessibilityHint)\(\s*\"([^\"]+)\""#,
        ]
        var keys: Set<String> = []
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for pattern in patterns {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                for match in expression.matches(in: source, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                    let key = String(source[keyRange])
                    if !key.contains(#"\("#) { keys.insert(key) }
                }
            }
        }
        return keys
    }

    /// Decodes the source-language String Catalog.
    private func catalogStrings() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("CodingBuddy/Localizable.xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: [String: Any]])
    }
}

/// Test-only timeout marker.
private enum GitHubProjectsStoreTestError: Error {
    /// Expected observable state was not reached.
    case timedOut
}

/// Scripted Project service for store state-machine tests.
private actor GitHubProjectsStoreService: GitHubProjectsServing {
    /// Discovery fixtures returned in order, retaining the final value for later calls.
    private var projectLists: [GitHubProjectList]
    /// Snapshot sequence consumed by explicit fetches.
    private var fetchSnapshots: [GitHubProjectSnapshot]
    /// Snapshot returned by preflight.
    let prepareSnapshot: GitHubProjectSnapshot
    /// Risk returned by preflight.
    let prepareRisk: GitHubProjectMoveRisk
    /// Optional mutation failure.
    let applyError: GitHubProjectsError?
    /// Number of discarded proofs.
    private(set) var discardCount = 0
    /// Number of attempted mutations.
    private(set) var applyCount = 0
    /// Number of consumed snapshot reads.
    private(set) var fetchCount = 0

    /// Creates a deterministic store service.
    init(
        projectList: GitHubProjectList,
        rediscoveredProjectLists: [GitHubProjectList] = [],
        fetchSnapshots: [GitHubProjectSnapshot],
        prepareSnapshot: GitHubProjectSnapshot,
        prepareRisk: GitHubProjectMoveRisk,
        applyError: GitHubProjectsError? = nil
    ) {
        self.projectLists = [projectList] + rediscoveredProjectLists
        self.fetchSnapshots = fetchSnapshots
        self.prepareSnapshot = prepareSnapshot
        self.prepareRisk = prepareRisk
        self.applyError = applyError
    }

    /// Returns scripted discovery.
    func discoverProjects(organizationLogin: String, token: String) async throws -> GitHubProjectList {
        guard let projectList = projectLists.first else {
            throw GitHubProjectsError.projectUnavailable
        }
        if projectLists.count > 1 {
            projectLists.removeFirst()
        }
        return projectList
    }

    /// Consumes one scripted snapshot.
    func fetchSnapshot(
        organizationLogin: String,
        projectID: String,
        token: String
    ) async throws -> GitHubProjectSnapshot {
        guard !fetchSnapshots.isEmpty else { throw GitHubProjectsError.projectUnavailable }
        fetchCount += 1
        return fetchSnapshots.removeFirst()
    }

    /// Returns a policy-bound one-use proof fixture.
    func prepareMove(
        organizationLogin: String,
        projectID: String,
        itemID: String,
        fieldID: String,
        destinationOptionID: String?,
        policy: GitHubProjectDriftPolicy,
        credential: GitHubCredential
    ) async throws -> (snapshot: GitHubProjectSnapshot, preflight: GitHubProjectMovePreflight) {
        let item = try #require(prepareSnapshot.items.first { $0.id == itemID })
        let field = try #require(prepareSnapshot.fields.first { $0.id == fieldID })
        return (
            prepareSnapshot,
            GitHubProjectMovePreflight(
                nonce: "store-preflight",
                intent: GitHubProjectMoveIntent(
                    organizationLogin: organizationLogin,
                    projectID: projectID,
                    itemID: itemID,
                    fieldID: fieldID,
                    destinationOptionID: destinationOptionID
                ),
                principalID: prepareSnapshot.principalID,
                sourceOptionID: item.singleSelectValue(fieldID: fieldID)?.optionID,
                itemUpdatedAt: item.updatedAt,
                itemEvidenceDigest: item.evidenceDigest,
                fieldUpdatedAt: field.updatedAt,
                fieldDefinitionDigest: field.definitionDigest,
                policyDigest: policy.digest,
                risk: prepareRisk,
                capturedAt: prepareSnapshot.capturedAt
            )
        )
    }

    /// Records proof revocation.
    func discard(preflight: GitHubProjectMovePreflight) async {
        discardCount += 1
    }

    /// Records one mutation and returns or throws the scripted outcome.
    func applyMove(
        credential: GitHubCredential,
        preflight: GitHubProjectMovePreflight,
        policy: GitHubProjectDriftPolicy
    ) async throws -> (snapshot: GitHubProjectSnapshot, receipt: GitHubProjectMutationReceipt) {
        applyCount += 1
        if let applyError { throw applyError }
        return (
            prepareSnapshot,
            GitHubProjectMutationReceipt(
                itemID: preflight.intent.itemID,
                clientMutationID: "mutation-1",
                verifiedOptionID: preflight.intent.destinationOptionID
            )
        )
    }
}

/// Thread-safe in-memory credential backend for Project store tests.
private final class GitHubProjectsCredentialStore: GitHubTokenStore, @unchecked Sendable {
    /// Lock protecting the credential fixture.
    private let lock = NSLock()
    /// Current credential fixture.
    private var credential: GitHubCredential?

    /// Creates a credential backend.
    init(credential: GitHubCredential?) {
        self.credential = credential
    }

    /// Returns the access token.
    func loadToken() throws -> String? { lock.withLock { credential?.accessToken } }
    /// Saves a PAT fixture.
    func saveToken(_ token: String) throws { lock.withLock { credential = .personalAccessToken(token) } }
    /// Clears the fixture.
    func deleteToken() throws { lock.withLock { credential = nil } }
    /// Returns the complete credential.
    func loadCredential() throws -> GitHubCredential? { lock.withLock { credential } }
    /// Replaces the complete credential.
    func saveCredential(_ credential: GitHubCredential) throws {
        lock.withLock { self.credential = credential }
    }
}

/// Actor-backed scripted transport for Project GraphQL boundary tests.
private actor GitHubProjectsRecordingTransport: GitHubTransport {
    /// One scripted HTTP result.
    enum Response: Sendable {
        /// Successful response body.
        case ok(String)
        /// Transport failure.
        case failure(URLError)
    }

    /// Remaining scripted responses.
    private var responses: [Response]
    /// Requests observed by the transport.
    private(set) var requests: [URLRequest] = []

    /// Creates a deterministic response queue.
    init(responses: [Response]) {
        self.responses = responses
    }

    /// Number of observed network calls.
    var requestCount: Int { requests.count }

    /// Records and resolves one request.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        switch response {
        case .ok(let body):
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        case .failure(let error):
            throw error
        }
    }
}
