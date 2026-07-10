//
//  DeveloperGlossary.swift
//  CodingBuddy
//

import Foundation

/// Curated developer terms that can be referenced from guidance.
nonisolated enum DeveloperTerm: String, CaseIterable, Hashable, Sendable {
    case ci
    case pr
    case mcp
    case oauth
    case scope
    case dirtyWorktree = "dirty-worktree"
    case aheadBehind = "ahead-behind"
    case packagePin = "package-pin"
    case directDependency = "direct-dependency"
}

/// Localized plain-language content for one developer term.
nonisolated struct DeveloperGlossaryEntry: Identifiable, Equatable, Sendable {
    /// Stable term identity; never derived from localized display text.
    var id: String { term.rawValue }
    let term: DeveloperTerm
    let title: String
    let definition: String
}

/// Curated localized definitions for developer terms used by guidance.
nonisolated enum DeveloperGlossary {
    /// Returns the localized entry for every supported developer term.
    static func entry(for term: DeveloperTerm) -> DeveloperGlossaryEntry {
        switch term {
        case .ci:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary CI title", defaultValue: "CI"),
                definition: String(
                    localized: "Developer glossary CI definition",
                    defaultValue: "Continuous integration (CI) automatically builds and tests code changes."
                )
            )
        case .pr:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary PR title", defaultValue: "PR"),
                definition: String(
                    localized: "Developer glossary PR definition",
                    defaultValue: "A pull request (PR) proposes code changes for review before they are merged."
                )
            )
        case .mcp:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary MCP title", defaultValue: "MCP"),
                definition: String(
                    localized: "Developer glossary MCP definition",
                    defaultValue: "The Model Context Protocol (MCP) lets AI tools connect to external tools and data sources."
                )
            )
        case .oauth:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary OAuth title", defaultValue: "OAuth"),
                definition: String(
                    localized: "Developer glossary OAuth definition",
                    defaultValue: "OAuth lets an app access another service with your approval without sharing your password."
                )
            )
        case .scope:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary scope title", defaultValue: "Scope"),
                definition: String(
                    localized: "Developer glossary scope definition",
                    defaultValue:
                        "Scope describes a boundary: which permissions a login receives or where a setting applies."
                )
            )
        case .dirtyWorktree:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary dirty worktree title", defaultValue: "Dirty worktree"),
                definition: String(
                    localized: "Developer glossary dirty worktree definition",
                    defaultValue: "A dirty worktree has local file changes that have not been committed."
                )
            )
        case .aheadBehind:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary ahead behind title", defaultValue: "Ahead/behind"),
                definition: String(
                    localized: "Developer glossary ahead behind definition",
                    defaultValue:
                        "Ahead counts local commits not on the remote branch; behind counts remote commits not in your local branch."
                )
            )
        case .packagePin:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary package pin title", defaultValue: "Package pin"),
                definition: String(
                    localized: "Developer glossary package pin definition",
                    defaultValue: "A package pin keeps a package at its current version until the pin is removed."
                )
            )
        case .directDependency:
            DeveloperGlossaryEntry(
                term: term,
                title: String(localized: "Developer glossary direct dependency title", defaultValue: "Direct dependency"),
                definition: String(
                    localized: "Developer glossary direct dependency definition",
                    defaultValue:
                        "A direct dependency is a package you explicitly installed or declared, rather than one required by another package."
                )
            )
        }
    }
}
