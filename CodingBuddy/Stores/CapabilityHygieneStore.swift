import Foundation
import Observation

/// Stable presentation phases for the local capability scan.
nonisolated enum CapabilityHygienePhase: Equatable, Sendable {
    /// No scan has started and no prior snapshot exists.
    case idle
    /// A scan is active; an older trustworthy snapshot may remain visible.
    case scanning
    /// The latest requested scan completed and published one atomic snapshot.
    case loaded
}

/// Root-owned state for the read-only Capability Hygiene inventory.
@Observable
final class CapabilityHygieneStore {
    /// Latest atomically published scanner result.
    private(set) var snapshot: CapabilityScanResult?
    /// Bounded analyzer output derived atomically from the same snapshot.
    private(set) var analysis = CapabilityAnalysisResult.empty
    /// Current loading phase independent of whether a stale snapshot remains visible.
    private(set) var phase = CapabilityHygienePhase.idle
    /// User-entered query applied to findings and inventory rows.
    var searchText = ""

    /// Injectable asynchronous scan boundary used by deterministic state tests.
    @ObservationIgnored private let scan: @Sendable () async -> CapabilityScanResult
    /// Current background reload, cancelled when a newer reload starts.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// Identity of the only reload still permitted to publish a result.
    @ObservationIgnored private var reloadRequestID: UUID?

    /// Creates a store for a real or temporary home directory.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scan: (@Sendable () async -> CapabilityScanResult)? = nil
    ) {
        if let scan {
            self.scan = scan
        } else {
            self.scan = {
                await Task.detached(priority: .userInitiated) {
                    CapabilityHygieneScanner(homeDirectory: homeDirectory).scan()
                }.value
            }
        }
    }

    /// Cancels pending work when the store leaves the view hierarchy.
    deinit {
        reloadTask?.cancel()
    }

    /// Complete inventory from the latest published snapshot.
    var items: [CapabilityInventoryItem] { snapshot?.items ?? [] }

    /// Deterministic findings derived only from the latest snapshot's evidence.
    var findings: [CapabilityHygieneFinding] {
        analysis.findings
    }

    /// Source records whose safety or format state prevents complete coverage.
    var incompleteSources: [CapabilitySourceRecord] {
        (snapshot?.sources ?? []).filter { source in
            switch source.status {
            case .missing, .complete:
                false
            case .partial, .refused, .unsupported:
                true
            }
        }
    }

    /// Number used by the sidebar after a snapshot has loaded.
    var findingCount: Int {
        findings.lazy.filter { $0.kind == .exactDuplicate || $0.kind == .shadowing }.count
    }

    /// Whether advisory analysis stopped at its explicit comparison or output budget.
    var isAnalysisTruncated: Bool { analysis.isTruncated }

    /// True while a first or background refresh is active.
    var isScanning: Bool { phase == .scanning }

    /// Inventory rows matching identity, kind, consumer, scope, source, and safe metadata.
    var filteredItems: [CapabilityInventoryItem] {
        let query = normalizedQuery
        guard !query.isEmpty else { return items }
        return items.filter { item in
            ([
                item.runtimeIdentity,
                item.kind.rawValue,
                item.consumer.rawValue,
                item.effectiveScope,
                item.sourcePath,
                item.version ?? "",
                item.summary ?? "",
            ] + item.repositoryUsage + item.permissionNames + item.secretReferenceNames + item.headerNames)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    /// Findings matching their localized-independent evidence and involved capabilities.
    var filteredFindings: [CapabilityHygieneFinding] {
        let query = normalizedQuery
        guard !query.isEmpty else { return findings }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return findings.filter { finding in
            let itemText = finding.itemIDs.compactMap { itemsByID[$0] }.flatMap { item in
                [item.runtimeIdentity, item.consumer.rawValue, item.effectiveScope, item.sourcePath]
            }
            return ([finding.kind.rawValue, finding.explanation] + itemText)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    /// Returns one occurrence by stable ID from the latest snapshot.
    func item(withID id: CapabilityInventoryItem.ID) -> CapabilityInventoryItem? {
        items.first { $0.id == id }
    }

    /// Starts a new scan while retaining the prior trustworthy snapshot on screen.
    func reload() {
        reloadTask?.cancel()
        let requestID = UUID()
        reloadRequestID = requestID
        phase = .scanning
        let scan = scan

        reloadTask = Task { [weak self, scan] in
            let result = await scan()
            guard let self,
                  !Task.isCancelled,
                  reloadRequestID == requestID
            else { return }
            snapshot = result
            analysis = CapabilityHygieneAnalyzer.analyze(
                in: result.items,
                precedenceEvidence: result.precedenceEvidence
            )
            phase = .loaded
        }
    }

    /// Trimmed query used consistently across both workspace modes.
    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
