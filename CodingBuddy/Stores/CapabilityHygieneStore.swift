import Foundation
import Observation

/// Atomic off-main output published by one capability reload generation.
private nonisolated struct CapabilityHygienePipelineResult: Sendable {
    /// Bounded filesystem evidence.
    let snapshot: CapabilityScanResult
    /// Bounded analysis derived from exactly that snapshot.
    let analysis: CapabilityAnalysisResult
}

/// Structured worker that keeps filesystem scanning and analysis off MainActor.
private nonisolated enum CapabilityHygienePipeline {
    /// Runs the production scanner and analyzer in one cancellation-linked worker.
    static func run(homeDirectory: URL) async -> CapabilityHygienePipelineResult? {
        await worker {
            let snapshot = CapabilityHygieneScanner(homeDirectory: homeDirectory).scan()
            guard !Task.isCancelled else { return nil }
            return result(for: snapshot)
        }
    }

    /// Analyzes an injected asynchronous snapshot off MainActor for deterministic tests.
    static func analyze(_ snapshot: CapabilityScanResult) async -> CapabilityHygienePipelineResult? {
        await worker { result(for: snapshot) }
    }

    /// Links parent cancellation to the detached CPU/filesystem worker.
    private static func worker(
        _ operation: @escaping @Sendable () -> CapabilityHygienePipelineResult?
    ) async -> CapabilityHygienePipelineResult? {
        let task = Task.detached(priority: .userInitiated) { () -> CapabilityHygienePipelineResult? in
            guard !Task.isCancelled else { return nil }
            let output = operation()
            guard !Task.isCancelled else { return nil }
            return output
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Produces analysis from the same immutable snapshot passed by the scanner.
    private static func result(for snapshot: CapabilityScanResult) -> CapabilityHygienePipelineResult {
        CapabilityHygienePipelineResult(
            snapshot: snapshot,
            analysis: CapabilityHygieneAnalyzer.analyze(
                in: snapshot.items,
                precedenceEvidence: snapshot.precedenceEvidence
            )
        )
    }
}

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

    /// Cancellation-linked scan-and-analysis boundary used by production and state tests.
    @ObservationIgnored private let load: @Sendable () async -> CapabilityHygienePipelineResult?
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
            self.load = {
                let snapshot = await scan()
                guard !Task.isCancelled else { return nil }
                return await CapabilityHygienePipeline.analyze(snapshot)
            }
        } else {
            self.load = { await CapabilityHygienePipeline.run(homeDirectory: homeDirectory) }
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
        let load = load

        reloadTask = Task { [weak self, load] in
            guard let output = await load(),
                  let self,
                  !Task.isCancelled,
                  reloadRequestID == requestID
            else { return }
            snapshot = output.snapshot
            analysis = output.analysis
            phase = .loaded
        }
    }

    /// Trimmed query used consistently across both workspace modes.
    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
