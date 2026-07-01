//
//  SidebarSectionExpansionState.swift
//  CodingBuddy
//

import Foundation

/// Stable identifiers for collapsible top-level sidebar groups.
nonisolated enum SidebarSectionID: String, CaseIterable, Sendable {
    /// Managed zsh startup files.
    case files
    /// Supported AI coding tool configuration sections.
    case aiTools
    /// Credential cache management sections.
    case credentials
    /// Local setup health checks.
    case health
    /// Read-only inventory and monitor sections.
    case inventory
    /// Safety and recovery sections.
    case safety
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
        collapsedSections = Set(storageValue
            .split(separator: ",")
            .compactMap { SidebarSectionID(rawValue: String($0)) })
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
