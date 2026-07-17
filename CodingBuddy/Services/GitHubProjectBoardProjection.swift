//
//  GitHubProjectBoardProjection.swift
//  CodingBuddy
//

import Foundation

/// Repository-filter result that preserves redacted provider evidence.
nonisolated enum GitHubProjectScopeMembership: String, Codable, Sendable {
    /// The item conclusively matches the selected repository scope.
    case included
    /// GitHub redaction prevents a conclusive repository comparison.
    case unknown
}

/// Local display filters applied to one immutable Project snapshot.
nonisolated struct GitHubProjectBoardFilter: Codable, Equatable, Sendable {
    /// Case-insensitive title, reference, or repository query.
    var searchText = ""
    /// Canonical `owner/repository` identities; empty means every repository.
    var repositoryIDs: Set<String> = []
    /// Drift categories that must occur on an item; empty means every category.
    var driftCategories: Set<GitHubProjectDriftCategory> = []
    /// Whether archived GitHub Project items remain visible.
    var includesArchived = false
}

/// One option-backed board column, including explicit unavailable and unassigned lanes.
nonisolated struct GitHubProjectBoardColumn: Identifiable, Equatable, Sendable {
    /// Stable local identity; provider option ID or the reserved unassigned key.
    let id: String
    /// Provider option represented by the column, or `nil` for unassigned items.
    let option: GitHubProjectSingleSelectOption?
    /// Removed provider value represented by this column, if it is no longer selectable.
    let unavailableValue: GitHubProjectSingleSelectValue?
    /// Whether inconsistent provider evidence prevents selecting one exact value.
    let representsAmbiguousValue: Bool

    /// Reserved identity that cannot collide with GitHub GraphQL node IDs.
    static let noValueID = "codingbuddy:no-value"
    /// Prefix for removed provider values that remain assigned to Project items.
    static let unavailableValueIDPrefix = "codingbuddy:unavailable-value:"
    /// Reserved lane for a single-select field that unexpectedly returned multiple values.
    static let ambiguousValueID = "codingbuddy:ambiguous-value"

    /// Stable local lane identity for one removed provider option.
    static func unavailableValueID(optionID: String) -> String {
        unavailableValueIDPrefix + optionID
    }

    /// Localized column label.
    var displayName: String {
        if let option { return option.name }
        if let unavailableValue {
            return String(
                format: String(localized: "Unavailable value: %@"),
                locale: .current,
                unavailableValue.name
            )
        }
        if representsAmbiguousValue { return String(localized: "Unavailable value") }
        return String(localized: "No value")
    }
}

/// One filtered item shared by Table and Board rendering.
nonisolated struct GitHubProjectBoardRow: Identifiable, Equatable, Sendable {
    /// Exact authoritative Project item.
    let item: GitHubProjectItem
    /// Exact value returned by GitHub, even when its option was removed from the field definition.
    let selectedValue: GitHubProjectSingleSelectValue?
    /// Selected board option, or `nil` when absent or ambiguous.
    let selectedOption: GitHubProjectSingleSelectOption?
    /// Whether GitHub unexpectedly returned multiple values for the selected single-select field.
    let hasAmbiguousValue: Bool
    /// Findings tied to this exact item.
    let findings: [GitHubProjectDriftFinding]
    /// Whether repository filtering conclusively included the item.
    let scopeMembership: GitHubProjectScopeMembership

    /// Project item identity.
    var id: String { item.id }

    /// Column identity used by Board rendering.
    var columnID: String {
        if let selectedOption { return selectedOption.id }
        if let selectedValue {
            return GitHubProjectBoardColumn.unavailableValueID(optionID: selectedValue.optionID)
        }
        if hasAmbiguousValue { return GitHubProjectBoardColumn.ambiguousValueID }
        return GitHubProjectBoardColumn.noValueID
    }

    /// Whether GitHub still reports a value whose option is absent from the current field definition.
    var hasUnavailableValue: Bool { selectedValue != nil && selectedOption == nil }

    /// Whether any provider value evidence exists, including an inconsistent multi-value response.
    var hasAnyValue: Bool { selectedValue != nil || hasAmbiguousValue }
}

/// Single filtered projection consumed by both Project display modes.
nonisolated struct GitHubProjectBoardProjection: Equatable, Sendable {
    /// Selected field that defines columns.
    let field: GitHubProjectSingleSelectField
    /// Provider columns followed by the explicit unassigned lane.
    let columns: [GitHubProjectBoardColumn]
    /// Rows in authoritative Project order after local filtering.
    let rows: [GitHubProjectBoardRow]

    /// IDs rendered by the Table representation.
    var tableItemIDs: [String] { rows.map(\.id) }

    /// IDs rendered by all Board columns, preserving the shared row order.
    var boardItemIDs: [String] {
        columns.flatMap { column in rows.filter { $0.columnID == column.id }.map(\.id) }
    }

    /// Rows belonging to one exact Board column.
    func rows(columnID: String) -> [GitHubProjectBoardRow] {
        rows.filter { $0.columnID == columnID }
    }

    /// Builds a fail-closed local projection without copying Project data into preferences.
    static func make(
        snapshot: GitHubProjectSnapshot,
        fieldID: String,
        assessment: GitHubProjectDriftAssessment,
        filter: GitHubProjectBoardFilter
    ) -> GitHubProjectBoardProjection? {
        guard let field = snapshot.fields.first(where: { $0.id == fieldID }) else { return nil }
        let optionsByID = Dictionary(uniqueKeysWithValues: field.options.map { ($0.id, $0) })
        let findingsByItem = Dictionary(grouping: assessment.findings, by: \.itemID)
        let query = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRepositoryIDs = Set(filter.repositoryIDs.map { $0.lowercased() })

        let rows = snapshot.items.compactMap { item -> GitHubProjectBoardRow? in
            guard filter.includesArchived || !item.isArchived else { return nil }
            let findings = findingsByItem[item.id] ?? []
            guard filter.driftCategories.isEmpty
                    || findings.contains(where: { filter.driftCategories.contains($0.category) }) else {
                return nil
            }
            guard query.isEmpty || matches(item: item, query: query) else { return nil }

            let membership: GitHubProjectScopeMembership
            if normalizedRepositoryIDs.isEmpty {
                membership = .included
            } else if let repository = item.content.repository {
                guard normalizedRepositoryIDs.contains(repository.canonicalID) else { return nil }
                membership = .included
            } else if item.content.kind == .redacted {
                membership = .unknown
            } else {
                return nil
            }

            let matchingValues = item.singleSelectValues.filter { $0.fieldID == fieldID }
            let selectedValue = matchingValues.count == 1 ? matchingValues[0] : nil
            return GitHubProjectBoardRow(
                item: item,
                selectedValue: selectedValue,
                selectedOption: selectedValue.flatMap { optionsByID[$0.optionID] },
                hasAmbiguousValue: matchingValues.count > 1,
                findings: findings,
                scopeMembership: membership
            )
        }
        let columns = field.options.map {
            GitHubProjectBoardColumn(
                id: $0.id,
                option: $0,
                unavailableValue: nil,
                representsAmbiguousValue: false
            )
        } + unavailableColumns(rows: rows) + ambiguousColumns(rows: rows) + [GitHubProjectBoardColumn(
            id: GitHubProjectBoardColumn.noValueID,
            option: nil,
            unavailableValue: nil,
            representsAmbiguousValue: false
        )]
        return GitHubProjectBoardProjection(field: field, columns: columns, rows: rows)
    }

    /// Builds one deterministic warning lane for every removed value still assigned to an item.
    private static func unavailableColumns(rows: [GitHubProjectBoardRow]) -> [GitHubProjectBoardColumn] {
        var seenOptionIDs: Set<String> = []
        return rows.compactMap { row in
            guard row.hasUnavailableValue,
                  let value = row.selectedValue,
                  seenOptionIDs.insert(value.optionID).inserted else { return nil }
            return GitHubProjectBoardColumn(
                id: GitHubProjectBoardColumn.unavailableValueID(optionID: value.optionID),
                option: nil,
                unavailableValue: value,
                representsAmbiguousValue: false
            )
        }
    }

    /// Adds one warning lane when malformed provider evidence contains multiple selected values.
    private static func ambiguousColumns(rows: [GitHubProjectBoardRow]) -> [GitHubProjectBoardColumn] {
        guard rows.contains(where: \.hasAmbiguousValue) else { return [] }
        return [GitHubProjectBoardColumn(
            id: GitHubProjectBoardColumn.ambiguousValueID,
            option: nil,
            unavailableValue: nil,
            representsAmbiguousValue: true
        )]
    }

    /// Applies the same query semantics to every Project content kind.
    private static func matches(item: GitHubProjectItem, query: String) -> Bool {
        item.content.title.localizedCaseInsensitiveContains(query)
            || item.content.referenceLabel.localizedCaseInsensitiveContains(query)
            || item.content.repository?.displayName.localizedCaseInsensitiveContains(query) == true
    }
}
