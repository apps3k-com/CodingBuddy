//
//  AgentDoctorStore.swift
//  CodingBuddy
//

import Foundation
import Observation

/// Root-owned state for the read-only Agent Doctor dashboard.
///
/// The store owns its scanner so views can observe a stable diagnostics
/// snapshot and request explicit refreshes without knowing filesystem paths.
@Observable
final class AgentDoctorStore {
    /// Home directory whose agent configuration is inspected.
    let homeDirectory: URL

    /// Latest Agent Doctor findings in scanner-defined display order.
    private(set) var diagnostics: [AgentDiagnostic] = []

    /// Read-only scanner that produces the current diagnostic snapshot.
    @ObservationIgnored private let scanner: AgentDoctorScanner

    /// Creates a store for one home directory without scanning it immediately.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.scanner = AgentDoctorScanner(homeDirectory: homeDirectory)
    }

    /// Number of actionable findings, excluding purely informational notices.
    var problemCount: Int {
        diagnostics.filter { $0.severity != .info }.count
    }

    /// Re-runs all Agent Doctor checks and replaces the diagnostics snapshot.
    func reload() {
        diagnostics = scanner.diagnostics()
    }
}
