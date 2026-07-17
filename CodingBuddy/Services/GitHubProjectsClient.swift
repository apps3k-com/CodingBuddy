//
//  GitHubProjectsClient.swift
//  CodingBuddy
//

import Foundation

/// Read and mutation interface consumed by the GitHub Projects board store.
nonisolated protocol GitHubProjectsServing: Sendable {
    /// Discovers Projects owned by one organization.
    func discoverProjects(organizationLogin: String, token: String) async throws -> GitHubProjectList

    /// Loads one internally consistent, bounded ProjectV2 snapshot.
    func fetchSnapshot(
        organizationLogin: String,
        projectID: String,
        token: String
    ) async throws -> GitHubProjectSnapshot

    /// Re-fetches authoritative evidence and issues a one-use move preflight.
    func prepareMove(
        organizationLogin: String,
        projectID: String,
        itemID: String,
        fieldID: String,
        destinationOptionID: String?,
        policy: GitHubProjectDriftPolicy,
        credential: GitHubCredential
    ) async throws -> (snapshot: GitHubProjectSnapshot, preflight: GitHubProjectMovePreflight)

    /// Revokes a preflight declined by the user.
    func discard(preflight: GitHubProjectMovePreflight) async

    /// Applies and verifies one exact field move.
    func applyMove(
        credential: GitHubCredential,
        preflight: GitHubProjectMovePreflight,
        policy: GitHubProjectDriftPolicy
    ) async throws -> (snapshot: GitHubProjectSnapshot, receipt: GitHubProjectMutationReceipt)
}

/// Native GraphQL client for ProjectV2 discovery, snapshots, and guarded field moves.
nonisolated struct GitHubProjectsClient: GitHubProjectsServing {
    /// Injectable HTTP transport.
    let transport: any GitHubTransport
    /// GitHub GraphQL endpoint.
    let graphQLEndpoint: URL
    /// Maximum pages accepted for a top-level connection.
    let pageLimit: Int
    /// Nodes requested per top-level page.
    let pageSize: Int
    /// Nodes requested for bounded nested item relationships and field values.
    let nestedPageSize: Int
    /// Maximum accepted bytes in one provider response.
    let maximumResponseBytes: Int
    /// Maximum GraphQL reads across one snapshot.
    let maximumSnapshotRequests: Int
    /// Maximum pessimistically reserved nodes across one snapshot.
    let maximumSnapshotNodes: Int
    /// Maximum aggregate bytes across one snapshot.
    let maximumSnapshotBytes: Int
    /// Clock used for deterministic captures.
    private let now: @Sendable () -> Date
    /// Client mutation identifier source.
    private let makeMutationID: @Sendable () -> String
    /// One-use preflight nonce source.
    private let makePreflightID: @Sendable () -> String
    /// Drift analyzer shared with the UI store.
    private let analyzer: any GitHubProjectDriftAnalyzing
    /// Nonce ledger preventing replay or cross-action reuse.
    private let preflightLedger: GitHubProjectPreflightLedger
    /// Aggregate budget inherited by nested snapshot reads.
    @TaskLocal private static var activeSnapshotBudget: GitHubProjectSnapshotBudget?

    /// Creates a production client with injectable bounds and deterministic hooks.
    init(
        transport: any GitHubTransport = URLSessionGitHubTransport(),
        graphQLEndpoint: URL = URL(string: "https://api.github.com/graphql")!,
        pageLimit: Int = 100,
        pageSize: Int = 50,
        nestedPageSize: Int = 100,
        maximumResponseBytes: Int = 10 * 1_024 * 1_024,
        maximumSnapshotRequests: Int = 320,
        maximumSnapshotNodes: Int? = nil,
        maximumSnapshotBytes: Int = 64 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        makeMutationID: @escaping @Sendable () -> String = { UUID().uuidString },
        makePreflightID: @escaping @Sendable () -> String = { UUID().uuidString },
        analyzer: any GitHubProjectDriftAnalyzing = GitHubProjectDriftAnalyzer()
    ) {
        self.transport = transport
        self.graphQLEndpoint = graphQLEndpoint
        self.pageLimit = max(1, pageLimit)
        self.pageSize = min(max(1, pageSize), 100)
        self.nestedPageSize = min(max(1, nestedPageSize), 100)
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
        self.maximumSnapshotRequests = max(1, maximumSnapshotRequests)
        self.maximumSnapshotNodes = max(
            1,
            maximumSnapshotNodes ?? Self.defaultSnapshotNodeBudget(
                pageLimit: self.pageLimit,
                pageSize: self.pageSize,
                nestedPageSize: self.nestedPageSize
            )
        )
        self.maximumSnapshotBytes = max(1_024, maximumSnapshotBytes)
        self.now = now
        self.makeMutationID = makeMutationID
        self.makePreflightID = makePreflightID
        self.analyzer = analyzer
        self.preflightLedger = GitHubProjectPreflightLedger()
    }

    /// Discovers organization-owned Projects without persisting issue or project data.
    func discoverProjects(organizationLogin: String, token: String) async throws -> GitHubProjectList {
        let login = try validatedOrganizationLogin(organizationLogin)
        let token = try validatedToken(token)
        var after: String?
        var tracker = GitHubProjectPageTracker(pageLimit: pageLimit)
        var organization: GitHubProjectOrganization?
        var projects: [GitHubProjectSummary] = []
        var isTruncated = false

        repeat {
            let data: DiscoveryData = try await query(
                query: Self.discoveryQuery,
                variables: PageVariables(login: login, first: pageSize, after: after),
                token: token,
                estimatedNodes: pageSize,
                usesSnapshotBudget: false
            )
            guard let node = data.organization,
                  !node.id.isEmpty,
                  !node.login.isEmpty else {
                throw GitHubProjectsError.organizationUnavailable
            }
            let resolvedOrganization = GitHubProjectOrganization(id: node.id, login: node.login)
            if let organization, organization != resolvedOrganization {
                throw GitHubProjectsError.driftDetected
            }
            organization = resolvedOrganization
            let mapped = try node.projects.nodes.map { try $0.summary }
            projects.append(contentsOf: mapped)
            switch try tracker.consume(
                nodeIDs: mapped.map(\.id),
                rawNodeCount: node.projects.nodes.count,
                totalCount: node.projects.totalCount,
                pageInfo: node.projects.pageInfo
            ) {
            case .next(let cursor): after = cursor
            case .done: after = nil
            case .truncated:
                isTruncated = true
                after = nil
            }
        } while after != nil

        guard let organization else { throw GitHubProjectsError.organizationUnavailable }
        return GitHubProjectList(
            organization: organization,
            projects: projects,
            isTruncated: isTruncated
        )
    }

    /// Loads every top-level Project connection and rejects metadata drift during the read.
    func fetchSnapshot(
        organizationLogin: String,
        projectID: String,
        token: String
    ) async throws -> GitHubProjectSnapshot {
        let login = try validatedOrganizationLogin(organizationLogin)
        let projectID = try validatedNodeID(projectID)
        let token = try validatedToken(token)
        let budget = GitHubProjectSnapshotBudget(
            maximumRequests: maximumSnapshotRequests,
            maximumNodes: maximumSnapshotNodes,
            maximumBytes: maximumSnapshotBytes
        )
        return try await Self.$activeSnapshotBudget.withValue(budget) {
            let initial = try await fetchBase(projectID: projectID, token: token)
            guard initial.organization.login.caseInsensitiveCompare(login) == .orderedSame else {
                throw GitHubProjectsError.projectUnavailable
            }
            let fieldsResult = try await fetchFields(projectID: projectID, token: token)
            let workflowsResult = try await fetchWorkflows(projectID: projectID, token: token)
            let itemsResult = try await fetchItems(projectID: projectID, token: token)
            let final = try await fetchBase(projectID: projectID, token: token)
            guard final == initial else { throw GitHubProjectsError.driftDetected }

            let incompleteFieldValues = Set(itemsResult.items.filter { !$0.fieldValuesComplete }.map(\.id))
            let incompleteRelationships = Set(itemsResult.items.filter {
                !$0.content.relationCoverage.isComplete
            }.map(\.id))
            return GitHubProjectSnapshot(
                organization: initial.organization,
                project: initial.project,
                fields: fieldsResult.fields,
                items: itemsResult.items,
                workflows: workflowsResult.workflows,
                coverage: GitHubProjectSnapshotCoverage(
                    fieldsComplete: fieldsResult.isComplete,
                    itemsComplete: itemsResult.isComplete,
                    workflowsComplete: workflowsResult.isComplete,
                    incompleteFieldValueItemIDs: incompleteFieldValues,
                    incompleteRelationshipItemIDs: incompleteRelationships
                ),
                principalID: initial.principalID,
                capturedAt: now()
            )
        }
    }

    /// Re-fetches complete evidence, validates the target, and registers a one-use proof.
    func prepareMove(
        organizationLogin: String,
        projectID: String,
        itemID: String,
        fieldID: String,
        destinationOptionID: String?,
        policy: GitHubProjectDriftPolicy,
        credential: GitHubCredential
    ) async throws -> (snapshot: GitHubProjectSnapshot, preflight: GitHubProjectMovePreflight) {
        let token = try requireWriteCredential(credential)
        let snapshot = try await fetchSnapshot(
            organizationLogin: organizationLogin,
            projectID: projectID,
            token: token
        )
        guard snapshot.coverage.isComplete,
              snapshot.project.viewerCanUpdate,
              let item = snapshot.items.first(where: { $0.id == itemID }),
              !item.isArchived,
              !item.evidenceDigest.isEmpty,
              let field = snapshot.fields.first(where: { $0.id == fieldID }),
              policy.completelyClassifies(field) else {
            throw GitHubProjectsError.incompleteSnapshot
        }
        if let destinationOptionID,
           !field.options.contains(where: { $0.id == destinationOptionID }) {
            throw GitHubProjectsError.invalidMutation
        }
        let sourceOptionID = item.singleSelectValue(fieldID: fieldID)?.optionID
        guard sourceOptionID != destinationOptionID else { throw GitHubProjectsError.invalidMutation }
        let risk = analyzer.moveRisk(
            snapshot: snapshot,
            item: item,
            fieldID: fieldID,
            destinationOptionID: destinationOptionID,
            policy: policy
        )
        guard risk != .unknown else { throw GitHubProjectsError.incompleteSnapshot }
        let nonce = makePreflightID()
        guard !nonce.isEmpty else { throw GitHubProjectsError.invalidMutation }
        let preflight = GitHubProjectMovePreflight(
            nonce: nonce,
            intent: GitHubProjectMoveIntent(
                organizationLogin: snapshot.organization.login,
                projectID: snapshot.project.id,
                itemID: item.id,
                fieldID: field.id,
                destinationOptionID: destinationOptionID
            ),
            principalID: snapshot.principalID,
            sourceOptionID: sourceOptionID,
            itemUpdatedAt: item.updatedAt,
            itemEvidenceDigest: item.evidenceDigest,
            fieldUpdatedAt: field.updatedAt,
            fieldDefinitionDigest: field.definitionDigest,
            policyDigest: policy.digest,
            risk: risk,
            capturedAt: snapshot.capturedAt
        )
        guard await preflightLedger.issue(nonce) else {
            throw GitHubProjectsError.invalidMutation
        }
        return (snapshot, preflight)
    }

    /// Revokes a preflight declined by the user.
    func discard(preflight: GitHubProjectMovePreflight) async {
        await preflightLedger.discard(preflight.nonce)
    }

    /// Applies one field move, never retries ambiguity, and verifies the exact resulting value.
    func applyMove(
        credential: GitHubCredential,
        preflight: GitHubProjectMovePreflight,
        policy: GitHubProjectDriftPolicy
    ) async throws -> (snapshot: GitHubProjectSnapshot, receipt: GitHubProjectMutationReceipt) {
        guard policy.digest == preflight.policyDigest else {
            throw GitHubProjectsError.driftDetected
        }
        let token = try requireWriteCredential(credential)
        guard await preflightLedger.consume(preflight.nonce) else {
            throw GitHubProjectsError.invalidMutation
        }
        let fresh = try await fetchSnapshot(
            organizationLogin: preflight.intent.organizationLogin,
            projectID: preflight.intent.projectID,
            token: token
        )
        guard fresh.coverage.isComplete,
              fresh.project.viewerCanUpdate,
              fresh.principalID == preflight.principalID,
              let item = fresh.items.first(where: { $0.id == preflight.intent.itemID }),
              let field = fresh.fields.first(where: { $0.id == preflight.intent.fieldID }),
              !item.isArchived,
              item.updatedAt == preflight.itemUpdatedAt,
              item.evidenceDigest == preflight.itemEvidenceDigest,
              field.updatedAt == preflight.fieldUpdatedAt,
              field.definitionDigest == preflight.fieldDefinitionDigest,
              item.singleSelectValue(fieldID: field.id)?.optionID == preflight.sourceOptionID else {
            throw GitHubProjectsError.driftDetected
        }
        if let destinationOptionID = preflight.intent.destinationOptionID,
           !field.options.contains(where: { $0.id == destinationOptionID }) {
            throw GitHubProjectsError.driftDetected
        }

        let clientMutationID = makeMutationID()
        guard !clientMutationID.isEmpty else { throw GitHubProjectsError.invalidMutation }
        let mutationItemID: String
        if let destinationOptionID = preflight.intent.destinationOptionID {
            let payload: UpdateFieldData = try await mutation(
                query: Self.updateFieldMutation,
                variables: UpdateFieldVariables(input: UpdateFieldInput(
                    projectID: preflight.intent.projectID,
                    itemID: preflight.intent.itemID,
                    fieldID: preflight.intent.fieldID,
                    value: UpdateFieldValue(singleSelectOptionID: destinationOptionID),
                    clientMutationID: clientMutationID
                )),
                token: token
            )
            guard let result = payload.updateProjectV2ItemFieldValue,
                  result.clientMutationID == clientMutationID,
                  result.projectV2Item.id == preflight.intent.itemID else {
                throw GitHubProjectsError.ambiguousWrite
            }
            mutationItemID = result.projectV2Item.id
        } else {
            let payload: ClearFieldData = try await mutation(
                query: Self.clearFieldMutation,
                variables: ClearFieldVariables(input: ClearFieldInput(
                    projectID: preflight.intent.projectID,
                    itemID: preflight.intent.itemID,
                    fieldID: preflight.intent.fieldID,
                    clientMutationID: clientMutationID
                )),
                token: token
            )
            guard let result = payload.clearProjectV2ItemFieldValue,
                  result.clientMutationID == clientMutationID,
                  result.projectV2Item.id == preflight.intent.itemID else {
                throw GitHubProjectsError.ambiguousWrite
            }
            mutationItemID = result.projectV2Item.id
        }

        let verified: GitHubProjectSnapshot
        do {
            verified = try await fetchSnapshot(
                organizationLogin: preflight.intent.organizationLogin,
                projectID: preflight.intent.projectID,
                token: token
            )
        } catch {
            throw GitHubProjectsError.ambiguousWrite
        }
        guard verified.coverage.isComplete,
              verified.fields.contains(where: { $0.id == preflight.intent.fieldID }),
              let verifiedItem = verified.items.first(where: { $0.id == mutationItemID }),
              verifiedItem.fieldValuesComplete,
              verifiedItem.singleSelectValue(fieldID: preflight.intent.fieldID)?.optionID
                == preflight.intent.destinationOptionID else {
            throw GitHubProjectsError.ambiguousWrite
        }
        return (
            verified,
            GitHubProjectMutationReceipt(
                itemID: mutationItemID,
                clientMutationID: clientMutationID,
                verifiedOptionID: preflight.intent.destinationOptionID
            )
        )
    }

    /// Loads immutable Project identity used at both ends of a snapshot read.
    private func fetchBase(projectID: String, token: String) async throws -> GitHubProjectBase {
        let data: BaseData = try await query(
            query: Self.baseQuery,
            variables: NodeVariables(id: projectID),
            token: token,
            estimatedNodes: 1
        )
        guard let node = data.node,
              node.id == projectID,
              !data.viewer.id.isEmpty else {
            throw GitHubProjectsError.projectUnavailable
        }
        return try node.base(principalID: data.viewer.id)
    }

    /// Loads every field page while retaining only board-capable single-select fields.
    private func fetchFields(
        projectID: String,
        token: String
    ) async throws -> (fields: [GitHubProjectSingleSelectField], isComplete: Bool) {
        var after: String?
        var tracker = GitHubProjectPageTracker(pageLimit: pageLimit)
        var fields: [GitHubProjectSingleSelectField] = []
        var isComplete = true
        repeat {
            let data: FieldsData = try await query(
                query: Self.fieldsQuery,
                variables: NodePageVariables(id: projectID, first: pageSize, after: after),
                token: token,
                estimatedNodes: pageSize
            )
            guard let node = data.node, node.id == projectID else {
                throw GitHubProjectsError.projectUnavailable
            }
            let mapped = try node.fields.nodes.compactMap { try $0.singleSelectField }
            fields.append(contentsOf: mapped)
            switch try tracker.consume(
                nodeIDs: mapped.map(\.id),
                rawNodeCount: node.fields.nodes.count,
                totalCount: node.fields.totalCount,
                pageInfo: node.fields.pageInfo
            ) {
            case .next(let cursor): after = cursor
            case .done: after = nil
            case .truncated:
                isComplete = false
                after = nil
            }
        } while after != nil
        return (fields, isComplete)
    }

    /// Loads every workflow page as bounded automation evidence.
    private func fetchWorkflows(
        projectID: String,
        token: String
    ) async throws -> (workflows: [GitHubProjectWorkflow], isComplete: Bool) {
        var after: String?
        var tracker = GitHubProjectPageTracker(pageLimit: pageLimit)
        var workflows: [GitHubProjectWorkflow] = []
        var isComplete = true
        repeat {
            let data: WorkflowsData = try await query(
                query: Self.workflowsQuery,
                variables: NodePageVariables(id: projectID, first: pageSize, after: after),
                token: token,
                estimatedNodes: pageSize
            )
            guard let node = data.node, node.id == projectID else {
                throw GitHubProjectsError.projectUnavailable
            }
            let mapped = node.workflows.nodes.map(\.workflow)
            workflows.append(contentsOf: mapped)
            switch try tracker.consume(
                nodeIDs: mapped.map(\.id),
                rawNodeCount: node.workflows.nodes.count,
                totalCount: node.workflows.totalCount,
                pageInfo: node.workflows.pageInfo
            ) {
            case .next(let cursor): after = cursor
            case .done: after = nil
            case .truncated:
                isComplete = false
                after = nil
            }
        } while after != nil
        return (workflows, isComplete)
    }

    /// Loads every item page with bounded nested relationships and field values.
    private func fetchItems(
        projectID: String,
        token: String
    ) async throws -> (items: [GitHubProjectItem], isComplete: Bool) {
        var after: String?
        var tracker = GitHubProjectPageTracker(pageLimit: pageLimit)
        var items: [GitHubProjectItem] = []
        var contentIDs = Set<String>()
        var isComplete = true
        let boundedNestedConnectionsPerItem = 3 // Field values, subissues, and linked content.
        repeat {
            let data: ItemsData = try await query(
                query: Self.itemsQuery,
                variables: ItemPageVariables(
                    id: projectID,
                    first: pageSize,
                    after: after,
                    nestedFirst: nestedPageSize
                ),
                token: token,
                estimatedNodes: pageSize * (1 + (nestedPageSize * boundedNestedConnectionsPerItem))
            )
            guard let node = data.node, node.id == projectID else {
                throw GitHubProjectsError.projectUnavailable
            }
            let mapped = try node.items.nodes.map { try $0.item }
            for item in mapped {
                if let contentID = item.content.id,
                   !contentIDs.insert(contentID).inserted {
                    throw GitHubProjectsError.duplicateIdentifier(contentID)
                }
            }
            items.append(contentsOf: mapped)
            switch try tracker.consume(
                nodeIDs: mapped.map(\.id),
                rawNodeCount: node.items.nodes.count,
                totalCount: node.items.totalCount,
                pageInfo: node.items.pageInfo
            ) {
            case .next(let cursor): after = cursor
            case .done: after = nil
            case .truncated:
                isComplete = false
                after = nil
            }
        } while after != nil
        return (items, isComplete)
    }

    /// Performs a typed GraphQL read and rejects every partial error payload.
    private func query<Variables: Encodable & Sendable, ResponseData: Decodable>(
        query: String,
        variables: Variables,
        token: String,
        estimatedNodes: Int,
        usesSnapshotBudget: Bool = true
    ) async throws -> ResponseData {
        if usesSnapshotBudget {
            try await Self.activeSnapshotBudget?.reserveRequest(estimatedNodes: estimatedNodes)
        }
        let request = try makeRequest(query: query, variables: variables, token: token)
        let (data, response) = try await performRead(request)
        if usesSnapshotBudget {
            try await Self.activeSnapshotBudget?.consume(bytes: data.count)
        }
        try validateHTTP(response: response)
        return try decodeGraphQL(data: data)
    }

    /// Performs one non-retried GraphQL write and treats uncertain outcomes as ambiguous.
    private func mutation<Variables: Encodable & Sendable, ResponseData: Decodable>(
        query: String,
        variables: Variables,
        token: String
    ) async throws -> ResponseData {
        let request = try makeRequest(query: query, variables: variables, token: validatedToken(token))
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw GitHubProjectsError.ambiguousWrite
        }
        guard data.count <= maximumResponseBytes else { throw GitHubProjectsError.ambiguousWrite }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw GitHubProjectsError.authenticationFailed
        case 403: throw GitHubProjectsError.missingPermission
        case 429: throw GitHubProjectsError.rateLimited
        case 500...599: throw GitHubProjectsError.ambiguousWrite
        default: throw GitHubProjectsError.mutationRejected
        }
        do {
            return try decodeGraphQL(data: data)
        } catch {
            throw GitHubProjectsError.ambiguousWrite
        }
    }

    /// Creates one authenticated JSON GraphQL request.
    private func makeRequest<Variables: Encodable>(
        query: String,
        variables: Variables,
        token: String
    ) throws -> URLRequest {
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodingBuddy", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            GitHubProjectsGraphQLRequest(query: query, variables: variables)
        )
        return request
    }

    /// Performs one bounded read request with conservative network classification.
    private func performRead(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await transport.data(for: request)
            guard data.count <= maximumResponseBytes else {
                throw GitHubProjectsError.invalidResponse
            }
            return (data, response)
        } catch {
            try rethrowCancellation(error)
            if let error = error as? GitHubProjectsError { throw error }
            throw GitHubProjectsError.networkUnavailable
        }
    }

    /// Preserves explicit and URLSession cancellation, including stale transport failures from a cancelled task.
    private func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Derives a bounded pessimistic node budget covering every configured snapshot page.
    private static func defaultSnapshotNodeBudget(
        pageLimit: Int,
        pageSize: Int,
        nestedPageSize: Int
    ) -> Int {
        let nestedConnectionsPerItem = 3
        let itemNodesPerPage = saturatingProduct(
            pageSize,
            1 + saturatingProduct(nestedPageSize, nestedConnectionsPerItem)
        )
        let nodesPerPageSet = saturatingSum(
            itemNodesPerPage,
            saturatingProduct(pageSize, 2)
        )
        return saturatingSum(2, saturatingProduct(pageLimit, nodesPerPageSet))
    }

    /// Adds non-negative bounds without allowing integer overflow to weaken the ceiling.
    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    /// Multiplies non-negative bounds without allowing integer overflow to weaken the ceiling.
    private static func saturatingProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : result
    }

    /// Maps HTTP status without exposing provider response bodies.
    private func validateHTTP(response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw GitHubProjectsError.authenticationFailed
        case 403: throw GitHubProjectsError.missingPermission
        case 404: throw GitHubProjectsError.projectUnavailable
        case 429: throw GitHubProjectsError.rateLimited
        default: throw GitHubProjectsError.server(statusCode: response.statusCode)
        }
    }

    /// Decodes one GraphQL envelope and rejects any error-bearing partial data.
    private func decodeGraphQL<ResponseData: Decodable>(data: Data) throws -> ResponseData {
        let envelope: GitHubProjectsGraphQLEnvelope<ResponseData>
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(GitHubProjectsGraphQLEnvelope<ResponseData>.self, from: data)
        } catch {
            throw GitHubProjectsError.invalidResponse
        }
        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "FORBIDDEN" || $0.type == "INSUFFICIENT_SCOPES" }) {
                throw GitHubProjectsError.missingPermission
            }
            throw GitHubProjectsError.invalidResponse
        }
        guard let data = envelope.data else { throw GitHubProjectsError.invalidResponse }
        return data
    }

    /// Requires an installed GitHub App credential for Project writes.
    private func requireWriteCredential(_ credential: GitHubCredential) throws -> String {
        guard credential.source == .githubAppDeviceFlow else {
            throw GitHubProjectsError.writesNotAllowed
        }
        return try validatedToken(credential.accessToken)
    }

    /// Validates a token without retaining or surfacing it in errors.
    private func validatedToken(_ token: String) throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 4_096 else {
            throw GitHubProjectsError.noToken
        }
        return token
    }

    /// Validates an organization login before it enters a provider query.
    private func validatedOrganizationLogin(_ login: String) throws -> String {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(login.utf8.count),
              login.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            throw GitHubProjectsError.invalidOrganization
        }
        return login
    }

    /// Validates an opaque GraphQL node ID before sending it to GitHub.
    private func validatedNodeID(_ id: String) throws -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...512).contains(id.utf8.count),
              !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw GitHubProjectsError.invalidProject
        }
        return id
    }
}

/// Typed failures produced by ProjectV2 reads and writes.
nonisolated enum GitHubProjectsError: LocalizedError, Equatable, Sendable {
    /// Credential value is empty or structurally invalid.
    case noToken
    /// Organization input is invalid.
    case invalidOrganization
    /// Project node ID is invalid.
    case invalidProject
    /// GitHub rejected the credential.
    case authenticationFailed
    /// Credential lacks required Projects permission.
    case missingPermission
    /// Organization is unavailable to the credential.
    case organizationUnavailable
    /// Project is unavailable to the credential.
    case projectUnavailable
    /// GitHub rate-limited the request.
    case rateLimited
    /// Provider returned an unexpected HTTP status.
    case server(statusCode: Int)
    /// Network failed during a read.
    case networkUnavailable
    /// Provider response was malformed or partial.
    case invalidResponse
    /// Cursor, total count, or configured paging bound prevented a complete read.
    case incompletePagination
    /// A stable provider ID appeared more than once.
    case duplicateIdentifier(String)
    /// Aggregate snapshot budget was exceeded.
    case snapshotBudgetExceeded
    /// Project evidence changed while a snapshot or preflight was evaluated.
    case driftDetected
    /// Fine-grained personal access tokens cannot authorize writes.
    case writesNotAllowed
    /// Mutation target or transition is invalid.
    case invalidMutation
    /// Snapshot or lifecycle mapping cannot support a safe write.
    case incompleteSnapshot
    /// Write may have reached GitHub and must not be retried automatically.
    case ambiguousWrite
    /// GitHub definitively rejected the mutation.
    case mutationRejected

    /// Localized, credential-safe explanation.
    var errorDescription: String? {
        switch self {
        case .noToken: String(localized: "Sign in to GitHub to load Projects.")
        case .invalidOrganization: String(localized: "Enter a valid GitHub organization login.")
        case .invalidProject: String(localized: "The selected GitHub Project is invalid.")
        case .authenticationFailed: String(localized: "GitHub rejected the saved authorization.")
        case .missingPermission: String(localized: "The GitHub authorization cannot access organization Projects.")
        case .organizationUnavailable: String(localized: "The GitHub organization is unavailable to this authorization.")
        case .projectUnavailable: String(localized: "The selected GitHub Project is unavailable.")
        case .rateLimited: String(localized: "GitHub rate limit reached. Try again later.")
        case .server(let code): String(format: String(localized: "GitHub returned HTTP %lld."), Int64(code))
        case .networkUnavailable: String(localized: "GitHub is unreachable. Check the network and try again.")
        case .invalidResponse: String(localized: "GitHub returned incomplete Project data.")
        case .incompletePagination: String(localized: "GitHub Project pagination changed before the read completed.")
        case .duplicateIdentifier: String(localized: "GitHub returned duplicate Project identities.")
        case .snapshotBudgetExceeded: String(localized: "The GitHub Project exceeds the safe snapshot limit.")
        case .driftDetected: String(localized: "The GitHub Project changed. Refresh before trying again.")
        case .writesNotAllowed: String(localized: "Sign in with the CodingBuddy GitHub App before changing Projects.")
        case .invalidMutation: String(localized: "The requested Project change is no longer valid.")
        case .incompleteSnapshot: String(localized: "Complete Project evidence and lifecycle roles are required before changing an item.")
        case .ambiguousWrite: String(localized: "GitHub may have applied the change. Verify the item before trying again.")
        case .mutationRejected: String(localized: "GitHub rejected the Project change.")
        }
    }
}

/// One-use nonce ledger shared by all copies of a client value.
private actor GitHubProjectPreflightLedger {
    /// Issued, not-yet-consumed nonces.
    private var nonces = Set<String>()

    /// Registers a unique nonce.
    func issue(_ nonce: String) -> Bool { nonces.insert(nonce).inserted }

    /// Atomically consumes a nonce once.
    func consume(_ nonce: String) -> Bool { nonces.remove(nonce) != nil }

    /// Revokes a nonce after user cancellation.
    func discard(_ nonce: String) { nonces.remove(nonce) }
}

/// Aggregate request, node, and byte budget for one snapshot.
private actor GitHubProjectSnapshotBudget {
    /// Request ceiling.
    let maximumRequests: Int
    /// Node ceiling.
    let maximumNodes: Int
    /// Byte ceiling.
    let maximumBytes: Int
    /// Reserved requests.
    private var requests = 0
    /// Pessimistically reserved nodes.
    private var nodes = 0
    /// Consumed response bytes.
    private var bytes = 0

    /// Creates a fixed aggregate budget.
    init(maximumRequests: Int, maximumNodes: Int, maximumBytes: Int) {
        self.maximumRequests = maximumRequests
        self.maximumNodes = maximumNodes
        self.maximumBytes = maximumBytes
    }

    /// Reserves one read and its maximum expected nodes.
    func reserveRequest(estimatedNodes: Int) throws {
        requests += 1
        nodes += max(0, estimatedNodes)
        guard requests <= maximumRequests, nodes <= maximumNodes else {
            throw GitHubProjectsError.snapshotBudgetExceeded
        }
    }

    /// Accounts for provider response bytes.
    func consume(bytes additionalBytes: Int) throws {
        bytes += max(0, additionalBytes)
        guard bytes <= maximumBytes else { throw GitHubProjectsError.snapshotBudgetExceeded }
    }
}

/// Result of consuming one provider connection page.
private nonisolated enum GitHubProjectPageStep: Equatable {
    /// Continue with the exact next cursor.
    case next(String)
    /// Provider connection is complete.
    case done
    /// Configured page cap stopped a structurally valid connection.
    case truncated
}

/// Cursor, count, duplicate, and page-cap validator for one connection.
private nonisolated struct GitHubProjectPageTracker {
    /// Maximum accepted pages.
    let pageLimit: Int
    /// Seen stable node IDs.
    private var nodeIDs = Set<String>()
    /// Seen outgoing cursors.
    private var cursors = Set<String>()
    /// Stable total count from the first page.
    private var expectedTotalCount: Int?
    /// Raw provider nodes consumed, including irrelevant union members.
    private var consumedNodeCount = 0
    /// Pages consumed.
    private var pageCount = 0

    /// Creates an empty validator with one fixed page bound.
    init(pageLimit: Int) {
        self.pageLimit = pageLimit
    }

    /// Validates one page and returns the bounded continuation step.
    mutating func consume(
        nodeIDs newNodeIDs: [String],
        rawNodeCount: Int,
        totalCount: Int,
        pageInfo: GitHubProjectPageInfo
    ) throws -> GitHubProjectPageStep {
        guard totalCount >= 0, rawNodeCount >= 0 else { throw GitHubProjectsError.invalidResponse }
        if let expectedTotalCount, expectedTotalCount != totalCount {
            throw GitHubProjectsError.driftDetected
        }
        expectedTotalCount = expectedTotalCount ?? totalCount
        for id in newNodeIDs {
            guard !id.isEmpty else { throw GitHubProjectsError.invalidResponse }
            guard nodeIDs.insert(id).inserted else {
                throw GitHubProjectsError.duplicateIdentifier(id)
            }
        }
        consumedNodeCount += rawNodeCount
        pageCount += 1
        guard pageInfo.hasNextPage else {
            guard consumedNodeCount == totalCount else {
                throw GitHubProjectsError.incompletePagination
            }
            return .done
        }
        guard let cursor = pageInfo.endCursor, !cursor.isEmpty,
              cursors.insert(cursor).inserted else {
            throw GitHubProjectsError.incompletePagination
        }
        guard pageCount < pageLimit else { return .truncated }
        return .next(cursor)
    }
}

private extension GitHubProjectsClient {
    /// Organization-scoped Project discovery query.
    static let discoveryQuery = """
    query CodingBuddyProjects($login: String!, $first: Int!, $after: String) {
      viewer { id }
      organization(login: $login) {
        id login
        projectsV2(
          first: $first
          after: $after
          orderBy: { field: UPDATED_AT, direction: DESC }
        ) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id number title url closed updatedAt viewerCanUpdate }
        }
      }
    }
    """

    /// Immutable Project identity queried before and after a snapshot read.
    static let baseQuery = """
    query CodingBuddyProjectBase($id: ID!) {
      viewer { id }
      node(id: $id) { ... on ProjectV2 {
        id number title url closed updatedAt viewerCanUpdate
        owner { ... on Organization { id login } }
      } }
    }
    """

    /// One page of Project fields, retaining full data for single-select fields.
    static let fieldsQuery = """
    query CodingBuddyProjectFields($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on ProjectV2 {
        id
        fields(
          first: $first
          after: $after
          orderBy: { field: POSITION, direction: ASC }
        ) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on ProjectV2SingleSelectField {
              id name updatedAt
              options { id name description color }
            }
          }
        }
      } }
    }
    """

    /// One page of Project workflow metadata.
    static let workflowsQuery = """
    query CodingBuddyProjectWorkflows($id: ID!, $first: Int!, $after: String) {
      node(id: $id) { ... on ProjectV2 {
        id
        workflows(
          first: $first
          after: $after
          orderBy: { field: NUMBER, direction: ASC }
        ) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes { id name enabled updatedAt }
        }
      } }
    }
    """

    /// One page of Project items plus bounded relationship and field-value evidence.
    static let itemsQuery = """
    query CodingBuddyProjectItems(
      $id: ID!
      $first: Int!
      $after: String
      $nestedFirst: Int!
    ) {
      node(id: $id) { ... on ProjectV2 {
        id
        items(first: $first, after: $after) {
          totalCount pageInfo { hasNextPage endCursor }
          nodes {
            id updatedAt isArchived
            fieldValues(first: $nestedFirst) {
              totalCount pageInfo { hasNextPage endCursor }
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  optionId name updatedAt
                  field { ... on ProjectV2SingleSelectField { id } }
                }
              }
            }
            content {
              __typename
              ... on DraftIssue { id title updatedAt }
              ... on Issue {
                id number title url state stateReason updatedAt closedAt
                repository { nameWithOwner }
                parent {
                  id number state repository { nameWithOwner }
                }
                subIssues(first: $nestedFirst) {
                  totalCount pageInfo { hasNextPage endCursor }
                  nodes { id number state repository { nameWithOwner } }
                }
                closedByPullRequestsReferences(first: $nestedFirst, includeClosedPrs: true) {
                  totalCount pageInfo { hasNextPage endCursor }
                  nodes { id number state repository { nameWithOwner } }
                }
              }
              ... on PullRequest {
                id number title url state isDraft updatedAt closedAt mergedAt
                repository { nameWithOwner }
                closingIssuesReferences(first: $nestedFirst) {
                  totalCount pageInfo { hasNextPage endCursor }
                  nodes { id number state repository { nameWithOwner } }
                }
              }
            }
          }
        }
      } }
    }
    """

    /// Mutation setting one single-select option.
    static let updateFieldMutation = """
    mutation CodingBuddyUpdateProjectField($input: UpdateProjectV2ItemFieldValueInput!) {
      updateProjectV2ItemFieldValue(input: $input) {
        clientMutationId projectV2Item { id }
      }
    }
    """

    /// Mutation clearing one single-select value.
    static let clearFieldMutation = """
    mutation CodingBuddyClearProjectField($input: ClearProjectV2ItemFieldValueInput!) {
      clearProjectV2ItemFieldValue(input: $input) {
        clientMutationId projectV2Item { id }
      }
    }
    """
}

/// Immutable Project identity used to detect concurrent changes.
private nonisolated struct GitHubProjectBase: Equatable {
    /// Resolved organization owner.
    let organization: GitHubProjectOrganization
    /// Project descriptor.
    let project: GitHubProjectSummary
    /// Authenticated viewer identity.
    let principalID: String
}

/// Generic encodable GraphQL request envelope.
private nonisolated struct GitHubProjectsGraphQLRequest<Variables: Encodable>: Encodable {
    /// GraphQL operation text.
    let query: String
    /// Typed variables.
    let variables: Variables
}

/// Generic decodable GraphQL response envelope.
private nonisolated struct GitHubProjectsGraphQLEnvelope<Payload: Decodable>: Decodable {
    /// Successful data when no errors occurred.
    let data: Payload?
    /// Provider errors; any entry invalidates partial data.
    let errors: [GitHubProjectsGraphQLError]?
}

/// Minimal provider error classification without exposing message bodies.
private nonisolated struct GitHubProjectsGraphQLError: Decodable {
    /// Stable provider error type.
    let type: String?
}

/// Standard cursor metadata used by all queried connections.
private nonisolated struct GitHubProjectPageInfo: Decodable {
    /// Whether another page exists.
    let hasNextPage: Bool
    /// Cursor for the next page.
    let endCursor: String?
}

/// Authenticated viewer identity.
private nonisolated struct GitHubProjectsViewerNode: Decodable {
    /// Viewer GraphQL node ID.
    let id: String
}

/// Variables for organization Project discovery.
private nonisolated struct PageVariables: Encodable, Sendable {
    /// Organization login.
    let login: String
    /// Page size.
    let first: Int
    /// Previous cursor.
    let after: String?
}

/// Variables for a single node read.
private nonisolated struct NodeVariables: Encodable, Sendable {
    /// GraphQL node ID.
    let id: String
}

/// Variables for a paged connection under one node.
private nonisolated struct NodePageVariables: Encodable, Sendable {
    /// Parent node ID.
    let id: String
    /// Page size.
    let first: Int
    /// Previous cursor.
    let after: String?
}

/// Variables for Project item pages with one nested connection bound.
private nonisolated struct ItemPageVariables: Encodable, Sendable {
    /// Project node ID.
    let id: String
    /// Item page size.
    let first: Int
    /// Previous item cursor.
    let after: String?
    /// Nested field and relationship cap.
    let nestedFirst: Int
}

/// Top-level organization discovery payload.
private nonisolated struct DiscoveryData: Decodable {
    /// Current viewer, retained to require authenticated responses.
    let viewer: GitHubProjectsViewerNode
    /// Requested organization.
    let organization: DiscoveryOrganizationNode?
}

/// Organization and its Project connection.
private nonisolated struct DiscoveryOrganizationNode: Decodable {
    /// Organization node ID.
    let id: String
    /// Canonical organization login.
    let login: String
    /// Project page.
    let projects: DiscoveryProjectConnection

    /// Coding key mapping GitHub's ProjectV2 field name.
    private enum CodingKeys: String, CodingKey {
        /// Organization node identifier.
        case id, login
        /// ProjectV2 connection exposed under GitHub's provider field name.
        case projects = "projectsV2"
    }
}

/// One Project discovery page.
private nonisolated struct DiscoveryProjectConnection: Decodable {
    /// Stable total count.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Project nodes.
    let nodes: [DiscoveryProjectNode]
}

/// Project descriptor returned during discovery.
private nonisolated struct DiscoveryProjectNode: Decodable {
    /// Project node ID.
    let id: String
    /// Owner-scoped number.
    let number: Int
    /// Project title.
    let title: String
    /// Browser URL.
    let url: URL
    /// Closed state.
    let closed: Bool
    /// Last update.
    let updatedAt: Date
    /// Viewer write capability.
    let viewerCanUpdate: Bool

    /// Validated public model.
    var summary: GitHubProjectSummary {
        get throws {
            guard !id.isEmpty, number > 0, !title.isEmpty else {
                throw GitHubProjectsError.invalidResponse
            }
            return GitHubProjectSummary(
                id: id,
                number: number,
                title: title,
                url: url,
                isClosed: closed,
                viewerCanUpdate: viewerCanUpdate,
                updatedAt: updatedAt
            )
        }
    }
}

/// Base-query payload.
private nonisolated struct BaseData: Decodable {
    /// Authenticated viewer.
    let viewer: GitHubProjectsViewerNode
    /// Requested Project node.
    let node: BaseProjectNode?
}

/// Organization owner fragment on a Project.
private nonisolated struct BaseOwnerNode: Decodable {
    /// Organization node ID.
    let id: String
    /// Canonical login.
    let login: String
}

/// Project base fragment.
private nonisolated struct BaseProjectNode: Decodable {
    /// Project node ID.
    let id: String
    /// Owner-scoped project number.
    let number: Int
    /// Project title.
    let title: String
    /// Browser URL.
    let url: URL
    /// Closed state.
    let closed: Bool
    /// Last project update.
    let updatedAt: Date
    /// Current viewer write capability.
    let viewerCanUpdate: Bool
    /// Organization owner fragment.
    let owner: BaseOwnerNode?

    /// Validates a Project base response.
    func base(principalID: String) throws -> GitHubProjectBase {
        guard !id.isEmpty, number > 0, !title.isEmpty,
              let owner, !owner.id.isEmpty, !owner.login.isEmpty,
              !principalID.isEmpty else {
            throw GitHubProjectsError.invalidResponse
        }
        return GitHubProjectBase(
            organization: GitHubProjectOrganization(id: owner.id, login: owner.login),
            project: GitHubProjectSummary(
                id: id,
                number: number,
                title: title,
                url: url,
                isClosed: closed,
                viewerCanUpdate: viewerCanUpdate,
                updatedAt: updatedAt
            ),
            principalID: principalID
        )
    }
}

/// Fields-query payload.
private nonisolated struct FieldsData: Decodable {
    /// Requested Project node.
    let node: FieldsProjectNode?
}

/// Project field page owner.
private nonisolated struct FieldsProjectNode: Decodable {
    /// Project node ID.
    let id: String
    /// Field page.
    let fields: FieldConnection
}

/// One Project field page.
private nonisolated struct FieldConnection: Decodable {
    /// Stable total count across every field type.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Union nodes.
    let nodes: [FieldNode]
}

/// Union field node retaining single-select fragments.
private nonisolated struct FieldNode: Decodable {
    /// GraphQL typename.
    let typename: String
    /// Single-select field ID.
    let id: String?
    /// Single-select field name.
    let name: String?
    /// Single-select definition update time.
    let updatedAt: Date?
    /// Single-select options.
    let options: [FieldOptionNode]?

    /// Coding key for GraphQL typename.
    private enum CodingKeys: String, CodingKey {
        /// Provider union discriminator.
        case typename = "__typename"
        /// Supported field payload properties.
        case id, name, updatedAt, options
    }

    /// Maps supported single-select fields and ignores all other field types.
    var singleSelectField: GitHubProjectSingleSelectField? {
        get throws {
            guard typename == "ProjectV2SingleSelectField" else { return nil }
            guard let id, !id.isEmpty,
                  let name, !name.isEmpty,
                  let updatedAt,
                  let options else {
                throw GitHubProjectsError.invalidResponse
            }
            let mapped = try options.map { try $0.option }
            guard Set(mapped.map(\.id)).count == mapped.count else {
                throw GitHubProjectsError.duplicateIdentifier(id)
            }
            return GitHubProjectSingleSelectField(
                id: id,
                name: name,
                updatedAt: updatedAt,
                options: mapped
            )
        }
    }
}

/// Provider single-select option.
private nonisolated struct FieldOptionNode: Decodable {
    /// Stable option ID.
    let id: String
    /// Option name.
    let name: String
    /// Optional description.
    let description: String?
    /// Raw GitHub color token.
    let color: String

    /// Validated public option.
    var option: GitHubProjectSingleSelectOption {
        get throws {
            guard !id.isEmpty, !name.isEmpty,
                  let color = GitHubProjectOptionColor(rawValue: color) else {
                throw GitHubProjectsError.invalidResponse
            }
            return GitHubProjectSingleSelectOption(
                id: id,
                name: name,
                description: description,
                color: color
            )
        }
    }
}

/// Workflows-query payload.
private nonisolated struct WorkflowsData: Decodable {
    /// Requested Project node.
    let node: WorkflowsProjectNode?
}

/// Project workflow page owner.
private nonisolated struct WorkflowsProjectNode: Decodable {
    /// Project node ID.
    let id: String
    /// Workflow page.
    let workflows: WorkflowConnection
}

/// One Project workflow page.
private nonisolated struct WorkflowConnection: Decodable {
    /// Stable total count.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Workflow nodes.
    let nodes: [WorkflowNode]
}

/// Provider workflow node.
private nonisolated struct WorkflowNode: Decodable {
    /// Workflow ID.
    let id: String
    /// Workflow name.
    let name: String
    /// Enabled state.
    let enabled: Bool
    /// Last update.
    let updatedAt: Date

    /// Public workflow value.
    var workflow: GitHubProjectWorkflow {
        GitHubProjectWorkflow(id: id, name: name, isEnabled: enabled, updatedAt: updatedAt)
    }
}

/// Items-query payload.
private nonisolated struct ItemsData: Decodable {
    /// Requested Project node.
    let node: ItemsProjectNode?
}

/// Project item page owner.
private nonisolated struct ItemsProjectNode: Decodable {
    /// Project node ID.
    let id: String
    /// Item page.
    let items: ItemConnection
}

/// One Project item page.
private nonisolated struct ItemConnection: Decodable {
    /// Stable total count.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Project item nodes.
    let nodes: [ItemNode]
}

/// Provider Project item node.
private nonisolated struct ItemNode: Decodable {
    /// Project item node ID.
    let id: String
    /// Item update timestamp.
    let updatedAt: Date
    /// Archived state.
    let isArchived: Bool
    /// Bounded field-value connection.
    let fieldValues: ItemFieldValueConnection
    /// Attached union content.
    let content: ItemContentNode?

    /// Validated public item.
    var item: GitHubProjectItem {
        get throws {
            guard !id.isEmpty else { throw GitHubProjectsError.invalidResponse }
            let selectedValues = fieldValues.nodes.compactMap(\.singleSelectValue)
            let fieldIDs = selectedValues.map(\.fieldID)
            let duplicateValue = Set(fieldIDs).count != fieldIDs.count
            let incompleteSingleSelectValue = fieldValues.nodes.contains(where: \.hasIncompleteSingleSelectValue)
            let fieldValuesComplete = !fieldValues.pageInfo.hasNextPage
                && fieldValues.nodes.count == fieldValues.totalCount
                && !duplicateValue
                && !incompleteSingleSelectValue
            let mappedContent = try content?.content ?? GitHubProjectItemContent(
                id: nil,
                kind: .redacted,
                title: "",
                number: nil,
                url: nil,
                repository: nil,
                state: .unknown,
                issueStateReason: nil,
                isDraftPullRequest: false,
                updatedAt: nil,
                terminalAt: nil,
                parent: nil,
                subIssues: [],
                linkedContent: [],
                relationCoverage: GitHubProjectRelationCoverage(
                    subIssuesComplete: false,
                    linkedContentComplete: false
                )
            )
            return GitHubProjectItem(
                id: id,
                updatedAt: updatedAt,
                isArchived: isArchived,
                content: mappedContent,
                singleSelectValues: selectedValues,
                fieldValuesComplete: fieldValuesComplete
            )
        }
    }
}

/// Bounded Project item field-value connection.
private nonisolated struct ItemFieldValueConnection: Decodable {
    /// Total field values for the item.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Union field-value nodes.
    let nodes: [ItemFieldValueNode]
}

/// Union item field value retaining single-select fragments.
private nonisolated struct ItemFieldValueNode: Decodable {
    /// GraphQL typename.
    let typename: String
    /// Selected option ID.
    let optionID: String?
    /// Selected option name.
    let name: String?
    /// Value update timestamp.
    let updatedAt: Date?
    /// Field identity fragment.
    let field: ItemFieldIdentityNode?

    /// Coding keys for provider naming.
    private enum CodingKeys: String, CodingKey {
        /// Provider union discriminator.
        case typename = "__typename"
        /// Provider option identifier spelling.
        case optionID = "optionId"
        /// Supported value payload properties.
        case name, updatedAt, field
    }

    /// Maps supported values and ignores all other field-value union members.
    var singleSelectValue: GitHubProjectSingleSelectValue? {
        guard typename == "ProjectV2ItemFieldSingleSelectValue",
              let optionID, !optionID.isEmpty,
              let name, !name.isEmpty,
              let updatedAt,
              let field, !field.id.isEmpty else { return nil }
        return GitHubProjectSingleSelectValue(
            fieldID: field.id,
            optionID: optionID,
            name: name,
            updatedAt: updatedAt
        )
    }

    /// Whether a supported value node lacks nullable provider evidence required for an exact value.
    var hasIncompleteSingleSelectValue: Bool {
        guard typename == "ProjectV2ItemFieldSingleSelectValue" else { return false }
        return optionID?.isEmpty != false
            || name?.isEmpty != false
            || updatedAt == nil
            || field?.id.isEmpty != false
    }
}

/// Field identity nested in a field value.
private nonisolated struct ItemFieldIdentityNode: Decodable {
    /// Field GraphQL node ID.
    let id: String
}

/// Content union attached to a Project item.
private nonisolated struct ItemContentNode: Decodable {
    /// GraphQL typename.
    let typename: String
    /// Content node ID.
    let id: String?
    /// Repository issue or pull-request number.
    let number: Int?
    /// User-visible title.
    let title: String?
    /// Browser URL.
    let url: URL?
    /// Raw issue or pull-request state.
    let state: String?
    /// Raw issue-only closure reason.
    let stateReason: String?
    /// Pull request draft state.
    let isDraft: Bool?
    /// Last content update.
    let updatedAt: Date?
    /// Issue or pull-request close time.
    let closedAt: Date?
    /// Pull-request merge time.
    let mergedAt: Date?
    /// Repository identity fragment.
    let repository: RepositoryNameNode?
    /// Parent issue.
    let parent: RelationshipNode?
    /// Child issue connection.
    let subIssues: RelationshipConnection?
    /// Issue-closing pull requests.
    let closedByPullRequestsReferences: RelationshipConnection?
    /// Pull-request closing issues.
    let closingIssuesReferences: RelationshipConnection?

    /// Coding key for GraphQL typename.
    private enum CodingKeys: String, CodingKey {
        /// Provider union discriminator.
        case typename = "__typename"
        /// Shared issue and pull-request properties.
        case id, number, title, url, state, stateReason, isDraft, updatedAt, closedAt, mergedAt
        /// Repository and relationship properties.
        case repository, parent, subIssues, closedByPullRequestsReferences, closingIssuesReferences
    }

    /// Validated public content model.
    var content: GitHubProjectItemContent {
        get throws {
            switch typename {
            case "DraftIssue":
                guard let id, !id.isEmpty, let title, let updatedAt else {
                    throw GitHubProjectsError.invalidResponse
                }
                return GitHubProjectItemContent(
                    id: id,
                    kind: .draftIssue,
                    title: title,
                    number: nil,
                    url: nil,
                    repository: nil,
                    state: .draft,
                    issueStateReason: nil,
                    isDraftPullRequest: false,
                    updatedAt: updatedAt,
                    terminalAt: nil,
                    parent: nil,
                    subIssues: [],
                    linkedContent: [],
                    relationCoverage: .notApplicable
                )
            case "Issue":
                return try repositoryContent(kind: .issue)
            case "PullRequest":
                return try repositoryContent(kind: .pullRequest)
            default:
                return GitHubProjectItemContent(
                    id: id,
                    kind: .redacted,
                    title: title ?? "",
                    number: number,
                    url: url,
                    repository: repository?.repository,
                    state: .unknown,
                    issueStateReason: nil,
                    isDraftPullRequest: false,
                    updatedAt: updatedAt,
                    terminalAt: nil,
                    parent: nil,
                    subIssues: [],
                    linkedContent: [],
                    relationCoverage: GitHubProjectRelationCoverage(
                        subIssuesComplete: false,
                        linkedContentComplete: false
                    )
                )
            }
        }
    }

    /// Maps issue or pull-request content and its bounded relationships.
    private func repositoryContent(kind: GitHubProjectContentKind) throws -> GitHubProjectItemContent {
        guard let id, !id.isEmpty,
              let number, number > 0,
              let title,
              let url,
              let rawState = state,
              let updatedAt,
              let repository = repository?.repository else {
            throw GitHubProjectsError.invalidResponse
        }
        let state = try Self.contentState(rawState, kind: kind)
        let parent = try parent?.reference(kind: .issue)
        let subIssueResult = kind == .issue
            ? try subIssues?.references(kind: .issue)
                ?? (references: [], complete: false)
            : (references: [], complete: true)
        let linkedConnection = kind == .issue
            ? closedByPullRequestsReferences
            : closingIssuesReferences
        let linkedKind: GitHubProjectContentKind = kind == .issue ? .pullRequest : .issue
        let linkedResult = try linkedConnection?.references(kind: linkedKind)
            ?? (references: [], complete: false)
        return GitHubProjectItemContent(
            id: id,
            kind: kind,
            title: title,
            number: number,
            url: url,
            repository: repository,
            state: state,
            issueStateReason: try issueStateReason(kind: kind, state: state),
            isDraftPullRequest: kind == .pullRequest && (isDraft ?? false),
            updatedAt: updatedAt,
            terminalAt: state == .merged ? mergedAt : closedAt,
            parent: parent,
            subIssues: subIssueResult.references,
            linkedContent: linkedResult.references,
            relationCoverage: GitHubProjectRelationCoverage(
                subIssuesComplete: subIssueResult.complete,
                linkedContentComplete: linkedResult.complete
            )
        )
    }

    /// Validates GitHub's issue-only closure reason without inferring missing evidence.
    private func issueStateReason(
        kind: GitHubProjectContentKind,
        state: GitHubProjectContentState
    ) throws -> GitHubProjectIssueStateReason? {
        guard kind == .issue else { return nil }
        if state == .open {
            guard stateReason == nil || stateReason == GitHubProjectIssueStateReason.reopened.rawValue else {
                throw GitHubProjectsError.invalidResponse
            }
            return stateReason.flatMap(GitHubProjectIssueStateReason.init(rawValue:))
        }
        guard let stateReason else { return nil }
        guard let reason = GitHubProjectIssueStateReason(rawValue: stateReason),
              reason != .reopened else {
            throw GitHubProjectsError.invalidResponse
        }
        return reason
    }

    /// Normalizes content state and rejects future provider values.
    private static func contentState(
        _ rawValue: String,
        kind: GitHubProjectContentKind
    ) throws -> GitHubProjectContentState {
        switch rawValue {
        case "OPEN": return .open
        case "CLOSED": return .closed
        case "MERGED" where kind == .pullRequest: return .merged
        default: throw GitHubProjectsError.invalidResponse
        }
    }
}

/// Repository `owner/name` fragment.
private nonisolated struct RepositoryNameNode: Decodable {
    /// Provider name with owner.
    let nameWithOwner: String

    /// Parsed repository identity.
    var repository: GitHubRepositoryRef? { GitHubRepositoryRef(displayName: nameWithOwner) }
}

/// Parent, child, issue, or pull-request relationship node.
private nonisolated struct RelationshipNode: Decodable {
    /// Content node ID.
    let id: String
    /// Repository issue or pull-request number.
    let number: Int
    /// Raw state.
    let state: String
    /// Repository identity.
    let repository: RepositoryNameNode

    /// Validated public relationship reference.
    func reference(kind: GitHubProjectContentKind) throws -> GitHubProjectContentReference {
        guard !id.isEmpty, number > 0, let repository = repository.repository else {
            throw GitHubProjectsError.invalidResponse
        }
        let state: GitHubProjectContentState
        switch self.state {
        case "OPEN": state = .open
        case "CLOSED": state = .closed
        case "MERGED" where kind == .pullRequest: state = .merged
        default: throw GitHubProjectsError.invalidResponse
        }
        return GitHubProjectContentReference(
            id: id,
            repository: repository,
            number: number,
            state: state
        )
    }
}

/// Bounded relationship connection nested under one content node.
private nonisolated struct RelationshipConnection: Decodable {
    /// Stable total count.
    let totalCount: Int
    /// Cursor metadata.
    let pageInfo: GitHubProjectPageInfo
    /// Relationship nodes.
    let nodes: [RelationshipNode]

    /// Maps relationships and proves whether the nested connection is complete.
    func references(
        kind: GitHubProjectContentKind
    ) throws -> (references: [GitHubProjectContentReference], complete: Bool) {
        let mapped = try nodes.map { try $0.reference(kind: kind) }
        let ids = mapped.map(\.id)
        guard Set(ids).count == ids.count else {
            throw GitHubProjectsError.duplicateIdentifier(ids.first ?? "relationship")
        }
        return (
            mapped,
            !pageInfo.hasNextPage && nodes.count == totalCount
        )
    }
}

/// Variables for setting a single-select value.
private nonisolated struct UpdateFieldVariables: Encodable, Sendable {
    /// Mutation input.
    let input: UpdateFieldInput
}

/// GraphQL update input.
private nonisolated struct UpdateFieldInput: Encodable, Sendable {
    /// Project node ID.
    let projectID: String
    /// Project item node ID.
    let itemID: String
    /// Field node ID.
    let fieldID: String
    /// New field value.
    let value: UpdateFieldValue
    /// Correlation ID.
    let clientMutationID: String

    /// Coding keys matching GitHub's input schema.
    private enum CodingKeys: String, CodingKey {
        /// Project node identifier.
        case projectID = "projectId"
        /// Project item node identifier.
        case itemID = "itemId"
        /// Project field node identifier.
        case fieldID = "fieldId"
        /// Destination field value.
        case value
        /// Mutation correlation identifier.
        case clientMutationID = "clientMutationId"
    }
}

/// GraphQL Project field value input.
private nonisolated struct UpdateFieldValue: Encodable, Sendable {
    /// Destination single-select option ID.
    let singleSelectOptionID: String

    /// Coding key matching GitHub's input schema.
    private enum CodingKeys: String, CodingKey {
        /// Destination single-select option identifier.
        case singleSelectOptionID = "singleSelectOptionId"
    }
}

/// Variables for clearing a field value.
private nonisolated struct ClearFieldVariables: Encodable, Sendable {
    /// Mutation input.
    let input: ClearFieldInput
}

/// GraphQL clear input.
private nonisolated struct ClearFieldInput: Encodable, Sendable {
    /// Project node ID.
    let projectID: String
    /// Project item node ID.
    let itemID: String
    /// Field node ID.
    let fieldID: String
    /// Correlation ID.
    let clientMutationID: String

    /// Coding keys matching GitHub's input schema.
    private enum CodingKeys: String, CodingKey {
        /// Project node identifier.
        case projectID = "projectId"
        /// Project item node identifier.
        case itemID = "itemId"
        /// Project field node identifier.
        case fieldID = "fieldId"
        /// Mutation correlation identifier.
        case clientMutationID = "clientMutationId"
    }
}

/// Update mutation payload.
private nonisolated struct UpdateFieldData: Decodable {
    /// Mutation result.
    let updateProjectV2ItemFieldValue: ProjectItemMutationPayload?
}

/// Clear mutation payload.
private nonisolated struct ClearFieldData: Decodable {
    /// Mutation result.
    let clearProjectV2ItemFieldValue: ProjectItemMutationPayload?
}

/// Shared Project item mutation result.
private nonisolated struct ProjectItemMutationPayload: Decodable {
    /// Echoed correlation ID.
    let clientMutationID: String?
    /// Updated Project item identity.
    let projectV2Item: MutationItemNode

    /// Coding keys matching GitHub response names.
    private enum CodingKeys: String, CodingKey {
        /// Echoed mutation correlation identifier.
        case clientMutationID = "clientMutationId"
        /// Updated Project item payload.
        case projectV2Item
    }
}

/// Minimal mutation item identity.
private nonisolated struct MutationItemNode: Decodable {
    /// Project item node ID.
    let id: String
}
