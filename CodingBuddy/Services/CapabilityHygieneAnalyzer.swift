//
//  CapabilityHygieneAnalyzer.swift
//  CodingBuddy
//

import Foundation

/// Deterministic analyzer that never upgrades incomplete evidence into an exact claim.
nonisolated enum CapabilityHygieneAnalyzer {
    /// Explicit work budgets keep adversarial inventories from creating quadratic output.
    struct Limits: Equatable, Sendable {
        /// Maximum possible-overlap pairs examined in one analysis.
        let maximumOverlapComparisons: Int
        /// Maximum findings retained across every finding kind.
        let maximumFindings: Int

        /// Conservative production defaults for an interactive local utility.
        static let standard = Limits(maximumOverlapComparisons: 100_000, maximumFindings: 2_000)
    }

    /// Conservative Jaccard threshold for distinct runtime identities.
    static let possibleOverlapThreshold = 0.60

    /// Produces read-only findings from complete fingerprints and explicit precedence evidence.
    static func findings(
        in items: [CapabilityInventoryItem],
        precedenceEvidence: [CapabilityPrecedenceEvidence] = []
    ) -> [CapabilityHygieneFinding] {
        analyze(in: items, precedenceEvidence: precedenceEvidence).findings
    }

    /// Produces findings plus explicit coverage when advisory comparison limits are reached.
    static func analyze(
        in items: [CapabilityInventoryItem],
        precedenceEvidence: [CapabilityPrecedenceEvidence] = [],
        limits: Limits = .standard
    ) -> CapabilityAnalysisResult {
        let active = items.filter { $0.activationState == .enabled }
        let certain = exactDuplicates(in: active) + provenShadowing(in: active, evidence: precedenceEvidence)
        let remaining = max(0, limits.maximumFindings - certain.count)
        let overlap = possibleOverlaps(
            in: active,
            maximumComparisons: max(0, limits.maximumOverlapComparisons),
            maximumFindings: remaining
        )
        let combined = (certain + overlap.findings).sorted(by: findingOrder)
        let retained = Array(combined.prefix(max(0, limits.maximumFindings)))
        return CapabilityAnalysisResult(
            findings: retained,
            isTruncated: overlap.isTruncated || retained.count < combined.count || certain.count > limits.maximumFindings,
            examinedOverlapComparisons: overlap.comparisons
        )
    }

    /// Requires kind, exact NFC runtime identity, and the same non-nil complete fingerprint.
    private static func exactDuplicates(in items: [CapabilityInventoryItem]) -> [CapabilityHygieneFinding] {
        let eligible = items.filter(\.supportsExactMatching)
        var groups: [ExactKey: [CapabilityInventoryItem]] = [:]
        for item in eligible.sorted(by: itemOrder) {
            guard let fingerprint = item.canonicalFingerprint else { continue }
            groups[ExactKey(kind: item.kind, runtimeIdentity: item.runtimeIdentity, fingerprint: fingerprint), default: []]
                .append(item)
        }
        return groups.values.compactMap { group in
            guard group.count >= 2 else { return nil }
            return CapabilityHygieneFinding(
                kind: .exactDuplicate,
                itemIDs: group.map(\.id).sorted(),
                explanation: "The occurrences have the same kind, exact runtime identity, and complete canonical behavior.",
                recommendation: "Compare provider scopes manually before consolidating. CodingBuddy will not alter either source.",
                similarity: nil,
                shadowResolution: nil
            )
        }
    }

    /// Emits shadowing only when typed provider evidence proves a winner and loser.
    private static func provenShadowing(
        in items: [CapabilityInventoryItem],
        evidence: [CapabilityPrecedenceEvidence]
    ) -> [CapabilityHygieneFinding] {
        var byID: [String: CapabilityInventoryItem] = [:]
        for item in items where byID[item.id] == nil {
            byID[item.id] = item
        }
        return evidence.compactMap { evidence in
            guard evidence.winnerItemID != evidence.loserItemID,
                  let winner = byID[evidence.winnerItemID],
                  let loser = byID[evidence.loserItemID],
                  winner.consumer == evidence.provider,
                  loser.consumer == evidence.provider,
                  winner.kind == loser.kind,
                  winner.runtimeIdentity == loser.runtimeIdentity,
                  !evidence.ruleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !evidence.evaluationScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.applies(winner, to: evidence.evaluationScope),
                  Self.applies(loser, to: evidence.evaluationScope)
            else { return nil }
            let resolution = CapabilityShadowResolution(
                winnerItemID: winner.id,
                loserItemID: loser.id,
                evidence: evidence
            )
            return CapabilityHygieneFinding(
                kind: .shadowing,
                itemIDs: [winner.id, loser.id].sorted(),
                explanation: "Provider precedence rule \(evidence.ruleIdentifier) selects one occurrence over the other.",
                recommendation: "Review the typed winner and loser manually. CodingBuddy will not remove the shadowed source.",
                similarity: nil,
                shadowResolution: resolution
            )
        }
    }

    /// Compares lossy tokens only within one kind, consumer, and effective scope.
    private static func possibleOverlaps(
        in items: [CapabilityInventoryItem],
        maximumComparisons: Int,
        maximumFindings: Int
    ) -> OverlapResult {
        let groups = Dictionary(grouping: items) {
            "\($0.kind.rawValue)|\($0.consumer.rawValue)|\($0.effectiveScope)"
        }
        var result: [CapabilityHygieneFinding] = []
        var comparisons = 0
        var truncated = false
        for groupKey in groups.keys.sorted() {
            guard let group = groups[groupKey] else { continue }
            let sorted = group.sorted(by: itemOrder)
            guard sorted.count >= 2 else { continue }
            let tokenSets = sorted.map(tokens)
            var indexesByToken: [String: [Int]] = [:]
            for (index, tokenSet) in tokenSets.enumerated() {
                for token in tokenSet.sorted() { indexesByToken[token, default: []].append(index) }
            }
            var candidates: Set<IndexPair> = []
            var candidateAttempts = 0
            candidateLoop: for token in indexesByToken.keys.sorted() {
                guard let indexes = indexesByToken[token], indexes.count >= 2 else { continue }
                for leftOffset in 0..<(indexes.count - 1) {
                    for rightOffset in (leftOffset + 1)..<indexes.count {
                        if candidateAttempts >= maximumComparisons {
                            truncated = true
                            break candidateLoop
                        }
                        candidateAttempts += 1
                        candidates.insert(IndexPair(left: indexes[leftOffset], right: indexes[rightOffset]))
                    }
                }
            }
            for candidate in candidates.sorted() {
                if comparisons >= maximumComparisons || result.count >= maximumFindings {
                    truncated = true
                    break
                }
                comparisons += 1
                let left = sorted[candidate.left]
                let right = sorted[candidate.right]
                guard left.runtimeIdentity != right.runtimeIdentity else { continue }
                let shared = tokenSets[candidate.left].intersection(tokenSets[candidate.right])
                let union = tokenSets[candidate.left].union(tokenSets[candidate.right])
                guard shared.count >= 2, !union.isEmpty else { continue }
                let score = Double(shared.count) / Double(union.count)
                guard score >= possibleOverlapThreshold else { continue }
                result.append(CapabilityHygieneFinding(
                    kind: .possibleOverlap,
                    itemIDs: [left.id, right.id].sorted(),
                    explanation: "Distinct runtime identities share \(shared.count) lossy search tokens; overlap is possible, not proven.",
                    recommendation: "Compare documented responsibilities manually. CodingBuddy will not consolidate these occurrences.",
                    similarity: score,
                    shadowResolution: nil
                ))
            }
            if truncated { break }
        }
        return OverlapResult(findings: result, comparisons: comparisons, isTruncated: truncated)
    }

    /// Removes generic words from lossy identity tokens.
    private static func tokens(_ item: CapabilityInventoryItem) -> Set<String> {
        let stopWords: Set<String> = ["and", "for", "of", "plugin", "server", "skill", "the", "tool", "with"]
        let identity: String
        if item.kind == .plugin, let namespace = item.runtimeIdentity.firstIndex(of: "@") {
            identity = CapabilityInventoryItem.lossySearchIdentity(String(item.runtimeIdentity[..<namespace]))
        } else {
            identity = item.searchIdentity
        }
        return Set(identity.split(separator: "-").map(String.init).filter { $0.count >= 2 && !stopWords.contains($0) })
    }

    /// Proves both occurrences are applicable in the adapter-supplied evaluation scope.
    private static func applies(_ item: CapabilityInventoryItem, to evaluationScope: String) -> Bool {
        item.effectiveScope == "user"
            || item.effectiveScope == evaluationScope
            || item.repositoryUsage.contains(evaluationScope)
    }

    /// Supplies deterministic item order.
    private static func itemOrder(_ lhs: CapabilityInventoryItem, _ rhs: CapabilityInventoryItem) -> Bool {
        (lhs.kind, lhs.consumer, lhs.effectiveScope, lhs.runtimeIdentity, lhs.sourcePath, lhs.id)
            < (rhs.kind, rhs.consumer, rhs.effectiveScope, rhs.runtimeIdentity, rhs.sourcePath, rhs.id)
    }

    /// Supplies deterministic finding order.
    private static func findingOrder(_ lhs: CapabilityHygieneFinding, _ rhs: CapabilityHygieneFinding) -> Bool {
        (lhs.kind, lhs.itemIDs.joined(separator: "|"), lhs.id)
            < (rhs.kind, rhs.itemIDs.joined(separator: "|"), rhs.id)
    }
}

/// Hashable exact-group key avoids repeated linear scans through opaque fingerprints.
private nonisolated struct ExactKey: Hashable {
    let kind: CapabilityKind
    let runtimeIdentity: String
    let fingerprint: CapabilityFingerprint
}

/// Ordered candidate pair used by the bounded inverted-token index.
private nonisolated struct IndexPair: Hashable, Comparable {
    let left: Int
    let right: Int

    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.left, lhs.right) < (rhs.left, rhs.right) }
}

/// Internal advisory result carrying comparison-budget coverage.
private nonisolated struct OverlapResult {
    let findings: [CapabilityHygieneFinding]
    let comparisons: Int
    let isTruncated: Bool
}
