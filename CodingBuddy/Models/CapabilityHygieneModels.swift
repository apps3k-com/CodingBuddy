//
//  CapabilityHygieneModels.swift
//  CodingBuddy
//

import CryptoKit
import Foundation

/// Supported categories in the static local capability inventory.
nonisolated enum CapabilityKind: String, CaseIterable, Comparable, Sendable {
    /// A configured Model Context Protocol server.
    case mcpServer
    /// A standalone skill rooted in a supported skills directory.
    case skill
    /// A plugin named by an authoritative configuration or installation registry.
    case plugin

    /// Supplies locale-independent deterministic ordering.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Consumer whose runtime resolves a capability occurrence.
nonisolated enum CapabilityConsumer: String, CaseIterable, Comparable, Sendable {
    /// OpenAI Codex.
    case codex
    /// Anthropic Claude Code.
    case claudeCode
    /// Cursor.
    case cursor
    /// The shared `~/.agents` skills surface.
    case sharedAgents

    /// Supplies locale-independent deterministic ordering.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Authoritative relationship between an occurrence and its provider.
nonisolated enum CapabilityRegistrationState: String, CaseIterable, Sendable {
    /// The provider's active configuration names the capability.
    case configured
    /// The provider's installation registry or standalone skill root contains the capability.
    case installed
}

/// Why a source could not produce a complete, behavior-bearing inventory result.
nonisolated enum CapabilitySourceReason: String, CaseIterable, Sendable {
    /// The source bytes are not valid UTF-8 where text is required.
    case malformedUTF8
    /// JSON syntax or duplicate object keys made the source ambiguous.
    case malformedJSON
    /// TOML structure was ambiguous or duplicated.
    case malformedTOML
    /// A path component or leaf is a symbolic link.
    case symbolicLink
    /// A configured path escaped its provider-owned root.
    case pathEscape
    /// A filesystem entry is not a regular file or directory.
    case specialFile
    /// One file exceeded the configured byte limit.
    case fileByteLimit
    /// Aggregate bytes exceeded the configured scan budget.
    case aggregateByteLimit
    /// Entry enumeration exceeded the configured scan budget.
    case entryLimit
    /// Tree traversal exceeded the configured depth.
    case depthLimit
    /// Project or provider roots exceeded the configured scan budget.
    case rootLimit
    /// The static source omits behavior-bearing fields needed for exact matching.
    case behaviorDefinitionUnavailable
    /// The provider format or field is not supported by the v1 static scanner.
    case unsupportedFormat
    /// A descriptor-bound read failed or changed during inspection.
    case unavailable
}

/// Completeness of one source or occurrence, preserved instead of fabricating healthy data.
nonisolated enum CapabilitySourceStatus: Equatable, Hashable, Sendable {
    /// The expected provider source does not exist.
    case missing
    /// The complete supported source was read and understood.
    case complete
    /// Useful metadata was read, but exact behavior is incomplete.
    case partial(CapabilitySourceReason)
    /// Safety validation refused the source.
    case refused(CapabilitySourceReason)
    /// The source exists but v1 deliberately does not interpret it.
    case unsupported(CapabilitySourceReason)
}

/// Provider-reported activation evidence without turning absence into an enabled claim.
nonisolated enum CapabilityActivationState: String, Equatable, Hashable, Sendable {
    /// The inspected provider source explicitly makes the occurrence available in its scope.
    case enabled
    /// The inspected provider source explicitly disables the occurrence in its scope.
    case disabled
    /// The effective state depends on approval, policy, project context, or unsupported settings.
    case unknown
}

/// Internal equality token for complete canonical behavior; it has no printable representation.
nonisolated struct CapabilityFingerprint: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Digest bytes remain inaccessible to UI, persistence, logging, and export layers.
    private let digest: Data

    /// Creates an opaque SHA-256 equality token for complete, non-secret canonical bytes.
    static func publicContent(schemaVersion: String, data: Data) -> CapabilityFingerprint {
        CapabilityFingerprint(digest: Data(SHA256.hash(data: domainSeparated(schemaVersion, data: data))))
    }

    /// Creates a scan-local equality token for canonical bytes that may contain secrets.
    ///
    /// The caller owns a fresh random key for one scan and must discard it afterwards. This
    /// preserves equality inside that scan without creating a reusable hash oracle for secrets.
    static func secretBearingContent(
        schemaVersion: String,
        data: Data,
        key: SymmetricKey
    ) -> CapabilityFingerprint {
        let digest = HMAC<SHA256>.authenticationCode(
            for: domainSeparated(schemaVersion, data: data),
            using: key
        )
        return CapabilityFingerprint(digest: Data(digest))
    }

    /// Prevents equal bytes from colliding across canonical schema revisions.
    private static func domainSeparated(_ schemaVersion: String, data: Data) -> Data {
        var result = Data("codingbuddy-capability\u{0}\(schemaVersion)\u{0}".utf8)
        result.append(data)
        return result
    }

    /// Prevents reflection-based logging from revealing digest bytes or a reusable encoding.
    var description: String { "<opaque capability fingerprint>" }

    /// Prevents debug output from revealing digest bytes or a reusable encoding.
    var debugDescription: String { description }
}

/// One normalized, display-safe occurrence from a static authoritative source.
nonisolated struct CapabilityInventoryItem: Identifiable, Equatable, Hashable, Sendable {
    /// Capability category.
    let kind: CapabilityKind
    /// Provider runtime that consumes this occurrence.
    let consumer: CapabilityConsumer
    /// Runtime identity normalized only to Unicode NFC; case and punctuation remain exact.
    let runtimeIdentity: String
    /// Lossy identity used only for search and possible-overlap tokenization.
    let searchIdentity: String
    /// Authoritative source reference; JSON occurrences may include a value-free pointer suffix.
    let sourcePath: String
    /// Effective provider scope such as `user` or a repository path.
    let effectiveScope: String
    /// Explicit repository usage metadata from the provider, never inferred by executing tools.
    let repositoryUsage: [String]
    /// Safe provider version metadata when present.
    let version: String?
    /// Short redacted summary derived from non-secret metadata.
    let summary: String?
    /// Permission or tool names only.
    let permissionNames: [String]
    /// Secret-reference names only; values are never retained.
    let secretReferenceNames: [String]
    /// Static HTTP header names only; values are never retained.
    let headerNames: [String]
    /// Whether the authoritative provider configured or installed the occurrence.
    let registrationState: CapabilityRegistrationState
    /// Provider activation evidence; unknown state is never treated as enabled by analysis.
    let activationState: CapabilityActivationState
    /// Preserved completeness for this occurrence.
    let sourceStatus: CapabilitySourceStatus
    /// Opaque exact-match token, present only for complete behavior-bearing content.
    let canonicalFingerprint: CapabilityFingerprint?

    /// Stable occurrence identity that does not depend on the opaque fingerprint.
    var id: String {
        CapabilityStableID.encode(
            namespace: "inventory-item-v1",
            components: [kind.rawValue, consumer.rawValue, effectiveScope, sourcePath, runtimeIdentity]
        )
    }

    /// Whether exact-content analysis is supported for this occurrence.
    var supportsExactMatching: Bool {
        sourceStatus == .complete && canonicalFingerprint != nil
    }

    /// Bounded, control-free identity for compact UI surfaces only.
    var displayIdentity: String {
        let controlFree = runtimeIdentity.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? "�" : String($0) }
            .joined()
        guard controlFree.count > 160 else { return controlFree }
        return String(controlFree.prefix(159)) + "…"
    }

    /// Creates an item while preserving runtime identity and sorting safe list metadata.
    init(
        kind: CapabilityKind,
        consumer: CapabilityConsumer,
        runtimeIdentity: String,
        sourcePath: String,
        effectiveScope: String,
        repositoryUsage: [String] = [],
        version: String? = nil,
        summary: String? = nil,
        permissionNames: [String] = [],
        secretReferenceNames: [String] = [],
        headerNames: [String] = [],
        registrationState: CapabilityRegistrationState,
        activationState: CapabilityActivationState = .unknown,
        sourceStatus: CapabilitySourceStatus,
        canonicalFingerprint: CapabilityFingerprint? = nil
    ) {
        let nfcIdentity = runtimeIdentity.precomposedStringWithCanonicalMapping
        self.kind = kind
        self.consumer = consumer
        self.runtimeIdentity = nfcIdentity
        self.searchIdentity = Self.lossySearchIdentity(nfcIdentity)
        self.sourcePath = sourcePath
        self.effectiveScope = effectiveScope.precomposedStringWithCanonicalMapping
        self.repositoryUsage = Self.uniqueSorted(repositoryUsage)
        self.version = Self.nonempty(version)
        self.summary = Self.nonempty(summary)
        self.permissionNames = Self.uniqueSorted(permissionNames)
        self.secretReferenceNames = Self.uniqueSorted(secretReferenceNames)
        self.headerNames = Self.uniqueSorted(headerNames)
        self.registrationState = registrationState
        self.activationState = activationState
        self.sourceStatus = sourceStatus
        self.canonicalFingerprint = sourceStatus == .complete ? canonicalFingerprint : nil
    }

    /// Builds a deliberately lossy comparison identity without changing runtime identity.
    static func lossySearchIdentity(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Returns trimmed optional metadata only when content remains.
    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Removes duplicates from non-secret names and applies stable ordering.
    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.precomposedStringWithCanonicalMapping }.filter { !$0.isEmpty })).sorted()
    }
}

/// One static provider source and the completeness achieved during this scan.
nonisolated struct CapabilitySourceRecord: Identifiable, Equatable, Hashable, Sendable {
    /// Value-free source path.
    let sourcePath: String
    /// Capability category when the source is category-specific.
    let kind: CapabilityKind?
    /// Preserved source completeness.
    let status: CapabilitySourceStatus

    /// Stable source identity.
    var id: String {
        CapabilityStableID.encode(
            namespace: "source-record-v1",
            components: [kind?.rawValue ?? "", sourcePath]
        )
    }
}

/// Value-free scanner notice for safety refusals and bounded-resource decisions.
nonisolated struct CapabilityScanNotice: Identifiable, Equatable, Hashable, Sendable {
    /// Stable safety or completeness reason.
    let reason: CapabilitySourceReason
    /// Source path without source bytes or secret values.
    let sourcePath: String

    /// Stable notice identity.
    var id: String {
        CapabilityStableID.encode(
            namespace: "scan-notice-v1",
            components: [reason.rawValue, sourcePath]
        )
    }
}

/// Complete result of one static, bounded capability scan.
nonisolated struct CapabilityScanResult: Equatable, Sendable {
    /// Inventory occurrences in deterministic order.
    let items: [CapabilityInventoryItem]
    /// Source completeness records in deterministic order.
    let sources: [CapabilitySourceRecord]
    /// Value-free safety notices in deterministic order.
    let notices: [CapabilityScanNotice]
    /// Proven provider precedence emitted by static adapters; empty when no rule is established.
    let precedenceEvidence: [CapabilityPrecedenceEvidence]
}

/// Bounded analyzer output; truncation is explicit and never presented as complete coverage.
nonisolated struct CapabilityAnalysisResult: Equatable, Sendable {
    /// Findings retained in deterministic order.
    let findings: [CapabilityHygieneFinding]
    /// Whether a comparison or output budget stopped further advisory analysis.
    let isTruncated: Bool
    /// Number of possible-overlap candidate pairs actually examined.
    let examinedOverlapComparisons: Int

    /// Empty complete analysis used before a snapshot exists.
    static let empty = CapabilityAnalysisResult(
        findings: [],
        isTruncated: false,
        examinedOverlapComparisons: 0
    )
}

/// Supported relationship classifications.
nonisolated enum CapabilityHygieneFindingKind: String, CaseIterable, Comparable, Sendable {
    /// Same kind, exact runtime identity, and complete canonical behavior.
    case exactDuplicate
    /// An authoritative provider rule explicitly identifies a winner and loser.
    case shadowing
    /// Distinct runtime identities have conservatively similar search tokens.
    case possibleOverlap

    /// Supplies stable ordering.
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Explicit provider precedence supplied to the analyzer; scanners do not infer it.
nonisolated struct CapabilityPrecedenceEvidence: Equatable, Hashable, Sendable {
    /// Provider that defines the precedence rule.
    let provider: CapabilityConsumer
    /// Stable provider-owned rule identifier backed by caller fixtures or documentation.
    let ruleIdentifier: String
    /// Repository or working-directory context in which the provider evaluates both occurrences.
    let evaluationScope: String
    /// Occurrence selected by the provider rule.
    let winnerItemID: String
    /// Occurrence hidden by the provider rule.
    let loserItemID: String

    /// Creates provider evidence only for one explicit evaluation context.
    init(
        provider: CapabilityConsumer,
        ruleIdentifier: String,
        evaluationScope: String,
        winnerItemID: String,
        loserItemID: String
    ) {
        self.provider = provider
        self.ruleIdentifier = ruleIdentifier
        self.evaluationScope = evaluationScope.precomposedStringWithCanonicalMapping
        self.winnerItemID = winnerItemID
        self.loserItemID = loserItemID
    }
}

/// Typed winner/loser resolution attached only to proven shadowing findings.
nonisolated struct CapabilityShadowResolution: Equatable, Hashable, Sendable {
    /// Winning occurrence.
    let winnerItemID: String
    /// Shadowed occurrence.
    let loserItemID: String
    /// Provider rule that proves the result.
    let evidence: CapabilityPrecedenceEvidence
}

/// Explainable, read-only analyzer output with no automatic mutation action.
nonisolated struct CapabilityHygieneFinding: Identifiable, Equatable, Hashable, Sendable {
    /// Relationship classification.
    let kind: CapabilityHygieneFindingKind
    /// Stable involved occurrence IDs.
    let itemIDs: [String]
    /// Value-free technical explanation.
    let explanation: String
    /// Reversible manual recommendation; never an automatic delete or rewrite.
    let recommendation: String
    /// Similarity score for possible overlap only.
    let similarity: Double?
    /// Typed provider result for shadowing only.
    let shadowResolution: CapabilityShadowResolution?

    /// Stable finding identity.
    var id: String {
        CapabilityStableID.encode(
            namespace: "finding-v1",
            components: [kind.rawValue] + itemIDs.sorted()
        )
    }
}

/// Length-prefixed model identities remain unambiguous for arbitrary provider-controlled text.
private nonisolated enum CapabilityStableID {
    /// Encodes a typed identity without relying on a delimiter that may appear in a component.
    static func encode(namespace: String, components: [String]) -> String {
        ([namespace] + components)
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }
}
