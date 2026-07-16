//
//  SidebarSectionExpansionState.swift
//  CodingBuddy
//

import Foundation

/// Stable identifiers for collapsible top-level sidebar groups.
nonisolated enum SidebarSectionID: String, CaseIterable, Sendable {
    /// Environment variables and managed zsh startup files.
    case environment
    /// Supported AI coding tool configuration sections.
    case agentTools
    /// Local setup health, credentials, and security inventory.
    case healthSecurity
    /// Repository context, readiness, and pull request follow-up.
    case repositories
    /// Software maintenance, backup, and recovery sections.
    case maintenance
}

/// Encodes which sidebar groups the user collapsed.
nonisolated struct SidebarSectionExpansionState: Equatable, Sendable {
    /// Collapsed groups; missing groups are treated as expanded.
    private var collapsedSections: Set<SidebarSectionID>

    /// Creates an expansion state with every sidebar group expanded.
    init(collapsedSections: Set<SidebarSectionID> = []) {
        self.collapsedSections = collapsedSections
    }

    /// Restores expansion state from the compact `AppStorage` representation.
    init(storageValue: String) {
        collapsedSections = []
        for token in storageValue.split(separator: ",").map(String.init) {
            if let section = SidebarSectionID(rawValue: token) {
                collapsedSections.insert(section)
                continue
            }
            switch token {
            case "files":
                collapsedSections.insert(.environment)
            case "aiTools":
                collapsedSections.insert(.agentTools)
            case "credentials", "health":
                collapsedSections.insert(.healthSecurity)
            case "inventory":
                collapsedSections.formUnion([.healthSecurity, .repositories])
            case "safety":
                collapsedSections.insert(.maintenance)
            default:
                break
            }
        }
    }

    /// Compact representation suitable for `AppStorage`.
    var storageValue: String {
        collapsedSections
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    /// Returns whether the section should render expanded.
    func isExpanded(_ section: SidebarSectionID) -> Bool {
        !collapsedSections.contains(section)
    }

    /// Updates one section's expansion state.
    mutating func setExpanded(_ isExpanded: Bool, for section: SidebarSectionID) {
        if isExpanded {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
    }
}
