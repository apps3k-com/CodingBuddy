//
//  Guidance.swift
//  CodingBuddy
//

/// Deterministic guidance presented by an explainable feature surface.
nonisolated struct Guidance: Identifiable, Equatable, Sendable {
    /// Stable machine-readable identity that does not depend on localized copy.
    let id: String
    /// Localized plain-language explanation of the observed state.
    let explanation: String
    /// Localized explanation of why the observed state matters.
    let relevance: String
    /// Localized description of what can happen if the state is left unchanged.
    let consequence: String
    /// The single primary next step presented to the user.
    let recommendedAction: RecommendedAction
    /// Secondary actions in deterministic display order.
    let alternatives: [RecommendedAction]
    /// Sanitized technical details in deterministic display order.
    let technicalEvidence: [TechnicalEvidence]
    /// Glossary terms referenced by this guidance in deterministic display order.
    let glossaryTerms: [DeveloperTerm]
}

/// A deterministic action description. Feature surfaces retain execution ownership.
nonisolated struct RecommendedAction: Identifiable, Equatable, Sendable {
    /// Stable machine-readable identity that does not depend on localized copy.
    let id: String
    /// Localized action title.
    let title: String
    /// Localized description of the result the action should produce.
    let expectedResult: String
    /// Relative amount of user effort expected for the action.
    let effort: GuidanceEffort
    /// Safety characteristics that determine how the action should be presented.
    let safetyClass: GuidanceSafetyClass
    /// Whether the current feature surface can offer the action.
    let availability: ActionAvailability
}

/// Whether a recommended action can currently be performed.
nonisolated enum ActionAvailability: Equatable, Sendable {
    /// The owning feature can route and perform the action.
    case available
    /// The observed state is healthy or informational and needs no action.
    case notNeeded(reason: String)
    /// The action would be useful but cannot currently be performed.
    case unavailable(reason: String)
}

/// Relative effort required to complete a recommended action.
nonisolated enum GuidanceEffort: String, CaseIterable, Sendable {
    /// A small follow-up that should not require sustained focus.
    case low
    /// A bounded task that needs some context and attention.
    case medium
    /// A task that should be treated as focused work.
    case high
}

/// Safety classification for a recommended action.
nonisolated enum GuidanceSafetyClass: String, CaseIterable, Sendable {
    /// The action only inspects or opens existing information.
    case readOnly
    /// The action changes state through an existing recovery path.
    case reversible
    /// The action changes state only after an explicit confirmation.
    case requiresConfirmation
}

/// One display-safe technical fact supporting a guidance explanation.
nonisolated struct TechnicalEvidence: Identifiable, Equatable, Sendable {
    /// Stable machine-readable identity that does not depend on localized copy.
    let id: String
    /// Localized label describing the evidence.
    let label: String
    /// Sanitized technical value safe for display.
    let sanitizedValue: String
}
