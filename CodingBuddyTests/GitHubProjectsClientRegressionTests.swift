//
//  GitHubProjectsClientRegressionTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

/// Focused regressions for cancellation, mutation correlation, and snapshot budgets.
@Suite(.serialized)
struct GitHubProjectsClientRegressionTests {
    /// A task cancellation must not become a retryable network failure.
    @Test func readPreservesTaskCancellation() async {
        let transport = RegressionGitHubTransport(responses: [.taskCancellation])
        let client = GitHubProjectsClient(transport: transport)

        await #expect(throws: CancellationError.self) {
            try await client.discoverProjects(organizationLogin: "apps3k-com", token: "token")
        }
    }

    /// URLSession's cancellation error must have the same cancellation semantics.
    @Test func readPreservesURLSessionCancellation() async {
        let transport = RegressionGitHubTransport(responses: [.urlSessionCancellation])
        let client = GitHubProjectsClient(transport: transport)

        await #expect(throws: CancellationError.self) {
            try await client.discoverProjects(organizationLogin: "apps3k-com", token: "token")
        }
    }

    /// Nested item connections are reserved before the item request reaches the transport.
    @Test func itemBudgetIncludesEveryBoundedNestedConnection() async {
        let transport = RegressionGitHubTransport(responses: [
            .ok(Self.baseResponse),
            .ok(Self.emptyFieldsResponse),
            .ok(Self.emptyWorkflowsResponse),
        ])
        let client = GitHubProjectsClient(
            transport: transport,
            pageSize: 1,
            nestedPageSize: 2,
            maximumSnapshotNodes: 9
        )

        await #expect(throws: GitHubProjectsError.snapshotBudgetExceeded) {
            try await client.fetchSnapshot(
                organizationLogin: "apps3k-com",
                projectID: "PROJECT1",
                token: "token"
            )
        }
        #expect(await transport.requestCount == 3)
    }

    /// The derived default budget covers three maximally sized item pages without weakening explicit caps.
    @Test func defaultItemBudgetSupportsMoreThanOneHundredItems() async throws {
        let transport = RegressionGitHubTransport(responses: [
            .ok(Self.baseResponse),
            .ok(Self.emptyFieldsResponse),
            .ok(Self.emptyWorkflowsResponse),
            .ok(Self.itemsPageResponse(startIndex: 1, count: 50, hasNextPage: true, endCursor: "cursor-1")),
            .ok(Self.itemsPageResponse(startIndex: 51, count: 50, hasNextPage: true, endCursor: "cursor-2")),
            .ok(Self.itemsPageResponse(startIndex: 101, count: 1, hasNextPage: false, endCursor: nil)),
            .ok(Self.baseResponse),
        ])
        let client = GitHubProjectsClient(transport: transport)

        let snapshot = try await client.fetchSnapshot(
            organizationLogin: "apps3k-com",
            projectID: "PROJECT1",
            token: "token"
        )

        #expect(snapshot.items.count == 101)
        #expect(snapshot.coverage.isComplete)
        #expect(await transport.requestCount == 7)
    }

    /// Missing nullable relationship connections stay visibly incomplete for their applicable content type.
    @Test func nullableRelationshipConnectionsNeverImplyCompleteEmptyEvidence() async throws {
        let responses = [
            Self.issueItemsResponse(includeSubIssues: false, includeClosingPullRequests: true),
            Self.issueItemsResponse(includeSubIssues: true, includeClosingPullRequests: false),
            Self.pullRequestItemsResponse(includeClosingIssues: false),
        ]

        for itemsResponse in responses {
            let transport = RegressionGitHubTransport(responses: [
                .ok(Self.baseResponse),
                .ok(Self.emptyFieldsResponse),
                .ok(Self.emptyWorkflowsResponse),
                .ok(itemsResponse),
                .ok(Self.baseResponse),
            ])
            let snapshot = try await GitHubProjectsClient(
                transport: transport,
                pageSize: 1,
                nestedPageSize: 1
            ).fetchSnapshot(
                organizationLogin: "apps3k-com",
                projectID: "PROJECT1",
                token: "token"
            )

            #expect(!snapshot.coverage.isComplete)
            #expect(snapshot.coverage.incompleteRelationshipItemIDs == ["ITEM1"])
        }
    }

    /// A missing correlation echo leaves an otherwise successful write ambiguous.
    @Test func mutationRejectsMissingClientMutationID() async throws {
        let context = try await preparedMove(
            destinationOptionID: nil,
            terminalResponses: [.ok(Self.clearMutationResponse(clientMutationID: nil))]
        )

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// A mismatched correlation echo cannot be accepted as this client's write.
    @Test func mutationRejectsMismatchedClientMutationID() async throws {
        let context = try await preparedMove(terminalResponses: [
            .ok(Self.updateMutationResponse(clientMutationID: "another-mutation")),
        ])

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// Cancellation while sending a mutation remains ambiguous because GitHub may have applied it.
    @Test func mutationCancellationRemainsAmbiguous() async throws {
        let context = try await preparedMove(terminalResponses: [.urlSessionCancellation])

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// Cancellation during authoritative readback remains ambiguous after an acknowledged mutation.
    @Test func mutationReadbackCancellationRemainsAmbiguous() async throws {
        let context = try await preparedMove(terminalResponses: [
            .ok(Self.updateMutationResponse(clientMutationID: "mutation-expected")),
            .taskCancellation,
        ])

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// Nullable selected-value properties retain the item while marking its field evidence incomplete.
    @Test func nullableSingleSelectValueEvidenceDoesNotAbortSnapshot() async throws {
        let nullablePayloads = [
            Self.itemsResponse.replacingOccurrences(of: #""optionId":"TODO""#, with: #""optionId":null"#),
            Self.itemsResponse.replacingOccurrences(of: #""name":"Todo""#, with: #""name":null"#),
        ]

        for itemsResponse in nullablePayloads {
            let transport = RegressionGitHubTransport(responses: [
                .ok(Self.baseResponse),
                .ok(Self.fieldsResponse),
                .ok(Self.emptyWorkflowsResponse),
                .ok(itemsResponse),
                .ok(Self.baseResponse),
            ])
            let snapshot = try await GitHubProjectsClient(
                transport: transport,
                pageSize: 1,
                nestedPageSize: 1
            ).fetchSnapshot(
                organizationLogin: "apps3k-com",
                projectID: "PROJECT1",
                token: "token"
            )

            #expect(snapshot.items.map(\.id) == ["ITEM1"])
            #expect(snapshot.items[0].singleSelectValues.isEmpty)
            #expect(!snapshot.items[0].fieldValuesComplete)
            #expect(snapshot.coverage.incompleteFieldValueItemIDs == ["ITEM1"])
            #expect(!snapshot.coverage.isComplete)

            var policy = GitHubProjectDriftPolicy.empty(projectID: "PROJECT1", fieldID: "STATUS")
            policy.roleByOptionID = ["TODO": .inProgress, "DONE": .done]
            let assessment = GitHubProjectDriftAnalyzer().assess(
                snapshot: snapshot,
                fieldID: "STATUS",
                policy: policy
            )
            #expect(assessment.state == .partial)
            #expect(!assessment.findings.contains {
                $0.title == String(localized: "Lifecycle field needs attention")
            })
        }
    }

    /// Clearing a field remains ambiguous when readback evidence is partial even though both option IDs are nil.
    @Test func clearReadbackRejectsIncompleteSnapshotEvidence() async throws {
        let context = try await preparedMove(
            destinationOptionID: nil,
            terminalResponses: [
                .ok(Self.clearMutationResponse(clientMutationID: "mutation-expected")),
                .ok(Self.baseResponse),
                .ok(Self.fieldsResponse),
                .ok(Self.emptyWorkflowsResponse),
                .ok(Self.issueItemsResponse(
                    includeSubIssues: false,
                    includeClosingPullRequests: true,
                    selectedOptionID: nil
                )),
                .ok(Self.baseResponse),
            ]
        )

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// Clearing a removed field cannot be verified from an otherwise complete nil readback.
    @Test func clearReadbackRejectsVanishedField() async throws {
        let context = try await preparedMove(
            destinationOptionID: nil,
            terminalResponses: [
                .ok(Self.clearMutationResponse(clientMutationID: "mutation-expected")),
                .ok(Self.baseResponse),
                .ok(Self.emptyFieldsResponse),
                .ok(Self.emptyWorkflowsResponse),
                .ok(Self.issueItemsResponse(
                    includeSubIssues: true,
                    includeClosingPullRequests: true,
                    selectedOptionID: nil
                )),
                .ok(Self.baseResponse),
            ]
        )

        await #expect(throws: GitHubProjectsError.ambiguousWrite) {
            try await context.client.applyMove(
                credential: Self.credential,
                preflight: context.preflight,
                policy: context.policy
            )
        }
    }

    /// Creates a client with one issued preflight and scripted responses after its freshness read.
    private func preparedMove(
        destinationOptionID: String? = "DONE",
        terminalResponses: [RegressionGitHubTransport.Response]
    ) async throws -> (
        client: GitHubProjectsClient,
        preflight: GitHubProjectMovePreflight,
        policy: GitHubProjectDriftPolicy
    ) {
        let responses = Self.snapshotResponses + Self.snapshotResponses + terminalResponses
        let transport = RegressionGitHubTransport(responses: responses)
        let client = GitHubProjectsClient(
            transport: transport,
            pageSize: 1,
            nestedPageSize: 1,
            makeMutationID: { "mutation-expected" },
            makePreflightID: { "preflight-expected" }
        )
        var policy = GitHubProjectDriftPolicy.empty(projectID: "PROJECT1", fieldID: "STATUS")
        policy.roleByOptionID = ["TODO": .inProgress, "DONE": .done]
        let result = try await client.prepareMove(
            organizationLogin: "apps3k-com",
            projectID: "PROJECT1",
            itemID: "ITEM1",
            fieldID: "STATUS",
            destinationOptionID: destinationOptionID,
            policy: policy,
            credential: Self.credential
        )
        return (client, result.preflight, policy)
    }

    /// GitHub App credential accepted by guarded writes.
    private static let credential = GitHubCredential(
        source: .githubAppDeviceFlow,
        accessToken: "device-token",
        refreshToken: nil,
        accessTokenExpiresAt: nil,
        refreshTokenExpiresAt: nil
    )

    /// One complete snapshot's response sequence.
    private static let snapshotResponses: [RegressionGitHubTransport.Response] = [
        .ok(baseResponse),
        .ok(fieldsResponse),
        .ok(emptyWorkflowsResponse),
        .ok(itemsResponse),
        .ok(baseResponse),
    ]

    /// Stable Project identity used at both ends of a snapshot.
    private static let baseResponse = #"{"data":{"viewer":{"id":"VIEWER1"},"node":{"id":"PROJECT1","number":13,"title":"CodingBuddy","url":"https://github.com/orgs/apps3k-com/projects/13","closed":false,"updatedAt":"2026-07-17T10:00:00Z","viewerCanUpdate":true,"owner":{"id":"ORG1","login":"apps3k-com"}}}}"#

    /// Complete single-select field definition.
    private static let fieldsResponse = #"{"data":{"node":{"id":"PROJECT1","fields":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"ProjectV2SingleSelectField","id":"STATUS","name":"Status","updatedAt":"2026-07-17T10:00:00Z","options":[{"id":"TODO","name":"Todo","description":null,"color":"GRAY"},{"id":"DONE","name":"Done","description":null,"color":"GREEN"}]}]}}}}"#

    /// Empty field page used by the budget boundary test.
    private static let emptyFieldsResponse = #"{"data":{"node":{"id":"PROJECT1","fields":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#

    /// Complete empty workflow page.
    private static let emptyWorkflowsResponse = #"{"data":{"node":{"id":"PROJECT1","workflows":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#

    /// One complete item with bounded field and relationship evidence.
    private static let itemsResponse = #"{"data":{"node":{"id":"PROJECT1","items":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"ITEM1","updatedAt":"2026-07-17T10:00:00Z","isArchived":false,"fieldValues":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","optionId":"TODO","name":"Todo","updatedAt":"2026-07-17T10:00:00Z","field":{"id":"STATUS"}}]},"content":{"__typename":"Issue","id":"ISSUE1","number":110,"title":"Project board","url":"https://github.com/apps3k-com/CodingBuddy/issues/110","state":"OPEN","stateReason":null,"updatedAt":"2026-07-17T10:00:00Z","closedAt":null,"repository":{"nameWithOwner":"apps3k-com/CodingBuddy"},"parent":null,"subIssues":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"closedByPullRequestsReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}]}}}}"#

    /// Builds one Project item page containing complete draft issues and no nested nodes.
    private static func itemsPageResponse(
        startIndex: Int,
        count: Int,
        hasNextPage: Bool,
        endCursor: String?
    ) -> String {
        let nodes = (startIndex..<(startIndex + count)).map { index in
            """
            {"id":"ITEM\(index)","updatedAt":"2026-07-17T10:00:00Z","isArchived":false,"fieldValues":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"content":{"__typename":"DraftIssue","id":"DRAFT\(index)","title":"Item \(index)","updatedAt":"2026-07-17T10:00:00Z"}}
            """
        }.joined(separator: ",")
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        return """
        {"data":{"node":{"id":"PROJECT1","items":{"totalCount":101,"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor)},"nodes":[\(nodes)]}}}}
        """
    }

    /// Builds one issue item while independently omitting nullable relationship connections.
    private static func issueItemsResponse(
        includeSubIssues: Bool,
        includeClosingPullRequests: Bool,
        selectedOptionID: String? = nil
    ) -> String {
        let fieldValues: String
        if let selectedOptionID {
            fieldValues = """
            {"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"ProjectV2ItemFieldSingleSelectValue","optionId":"\(selectedOptionID)","name":"\(selectedOptionID)","updatedAt":"2026-07-17T10:00:00Z","field":{"id":"STATUS"}}]}
            """
        } else {
            fieldValues = #"{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}"#
        }
        let subIssues = includeSubIssues
            ? #","subIssues":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}"#
            : ""
        let closingPullRequests = includeClosingPullRequests
            ? #","closedByPullRequestsReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}"#
            : ""
        return """
        {"data":{"node":{"id":"PROJECT1","items":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"ITEM1","updatedAt":"2026-07-17T10:00:00Z","isArchived":false,"fieldValues":\(fieldValues),"content":{"__typename":"Issue","id":"ISSUE1","number":110,"title":"Project board","url":"https://github.com/apps3k-com/CodingBuddy/issues/110","state":"OPEN","stateReason":null,"updatedAt":"2026-07-17T10:00:00Z","closedAt":null,"repository":{"nameWithOwner":"apps3k-com/CodingBuddy"},"parent":null\(subIssues)\(closingPullRequests)}}]}}}}
        """
    }

    /// Builds one pull-request item with an optionally absent closing-issues connection.
    private static func pullRequestItemsResponse(includeClosingIssues: Bool) -> String {
        let closingIssues = includeClosingIssues
            ? #","closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}"#
            : ""
        return """
        {"data":{"node":{"id":"PROJECT1","items":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"ITEM1","updatedAt":"2026-07-17T10:00:00Z","isArchived":false,"fieldValues":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"content":{"__typename":"PullRequest","id":"PR1","number":116,"title":"Projects board","url":"https://github.com/apps3k-com/CodingBuddy/pull/116","state":"OPEN","isDraft":false,"updatedAt":"2026-07-17T10:00:00Z","closedAt":null,"mergedAt":null,"repository":{"nameWithOwner":"apps3k-com/CodingBuddy"}\(closingIssues)}}]}}}}
        """
    }

    /// Builds a mutation result with an optional correlation echo.
    private static func updateMutationResponse(clientMutationID: String?) -> String {
        let correlation = clientMutationID.map { ",\"clientMutationId\":\"\($0)\"" } ?? ""
        return "{\"data\":{\"updateProjectV2ItemFieldValue\":{\"projectV2Item\":{\"id\":\"ITEM1\"}\(correlation)}}}"
    }

    /// Builds a clear-mutation result with an optional correlation echo.
    private static func clearMutationResponse(clientMutationID: String?) -> String {
        let correlation = clientMutationID.map { ",\"clientMutationId\":\"\($0)\"" } ?? ""
        return "{\"data\":{\"clearProjectV2ItemFieldValue\":{\"projectV2Item\":{\"id\":\"ITEM1\"}\(correlation)}}}"
    }
}

/// Actor-backed transport with explicit cancellation variants.
private actor RegressionGitHubTransport: GitHubTransport {
    /// One deterministic transport outcome.
    enum Response: Sendable {
        /// Successful JSON response.
        case ok(String)
        /// Swift concurrency cancellation.
        case taskCancellation
        /// URLSession cancellation.
        case urlSessionCancellation
    }

    /// Remaining responses.
    private var responses: [Response]
    /// Number of requests received.
    private(set) var requestCount = 0

    /// Creates a queued transport.
    init(responses: [Response]) {
        self.responses = responses
    }

    /// Returns or throws the next scripted result.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        switch responses.removeFirst() {
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
        case .taskCancellation:
            throw CancellationError()
        case .urlSessionCancellation:
            throw URLError(.cancelled)
        }
    }
}
