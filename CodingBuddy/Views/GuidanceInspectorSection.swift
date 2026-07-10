//
//  GuidanceInspectorSection.swift
//  CodingBuddy
//

import SwiftUI

/// Reusable explanation and action hierarchy for a single guidance item.
struct GuidanceInspectorSection: View {
    /// Guidance presented by the inspector.
    let guidance: Guidance
    /// Executes an action identified by its stable model identifier.
    let onPerformAction: (String) -> Void

    /// Expansion state is local because technical context is supplemental.
    @State private var isShowingTechnicalDetails = false

    /// Plain, composable content intended for placement in an existing inspector.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanationSection
            relevanceSection
            actionSection
            if hasTechnicalDetails {
                technicalDetailsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: guidance.id) {
            isShowingTechnicalDetails = false
        }
    }

    /// Plain-language explanation without imposing a surrounding container.
    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this means")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            multilineText(guidance.explanation)
        }
    }

    /// Relevance and consequence remain together so the impact reads in context.
    private var relevanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why it matters")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            multilineText(guidance.relevance)
            labeledText(label: "What could happen", value: guidance.consequence)
        }
    }

    /// One primary recommendation followed by ordered secondary alternatives.
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended next step")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            actionContent(guidance.recommendedAction, isRecommended: true)

            if !guidance.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Alternatives")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(guidance.alternatives, id: \.id) { action in
                        actionContent(action, isRecommended: false)
                    }
                }
            }
        }
    }

    /// Collapsed technical context containing only sanitized model data.
    private var technicalDetailsSection: some View {
        DisclosureGroup(isExpanded: $isShowingTechnicalDetails) {
            VStack(alignment: .leading, spacing: 14) {
                if !guidance.technicalEvidence.isEmpty {
                    evidenceSection
                }
                if !guidance.glossaryTerms.isEmpty {
                    glossarySection
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Technical details")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityHint(Text("Show or hide technical evidence and glossary definitions."))
    }

    /// Sanitized evidence remains readable at narrow inspector widths.
    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(guidance.technicalEvidence) { evidence in
                VStack(alignment: .leading, spacing: 2) {
                    Text(evidence.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(evidence.sanitizedValue)
                        .monospaced()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Curated glossary definitions clarify only the terms attached to this guidance.
    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glossary")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(uniqueGlossaryTerms, id: \.self) { term in
                let entry = DeveloperGlossary.entry(for: term)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.definition)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Presents the promised result and action classifications before its control.
    @ViewBuilder
    private func actionContent(_ action: RecommendedAction, isRecommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            labeledText(label: "Expected result", value: action.expectedResult)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    actionMetadata(for: action)
                }
                VStack(alignment: .leading, spacing: 6) {
                    actionMetadata(for: action)
                }
            }

            switch action.availability {
            case .available:
                if isRecommended {
                    primaryButton(for: action)
                } else {
                    secondaryButton(for: action)
                }
            case .notNeeded(let reason):
                multilineText(action.title)
                    .fontWeight(.semibold)
                multilineText(reason)
                    .foregroundStyle(.secondary)
            case .unavailable(let reason):
                multilineText(action.title)
                    .fontWeight(.semibold)
                Text("Unavailable: \(reason)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The sole visually prominent action in the component.
    private func primaryButton(for action: RecommendedAction) -> some View {
        Button {
            onPerformAction(action.id)
        } label: {
            multilineButtonLabel(action.title)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint(Text("Recommended. Expected result: \(action.expectedResult)"))
    }

    /// Alternative actions preserve source ordering and native keyboard behavior.
    private func secondaryButton(for action: RecommendedAction) -> some View {
        Button {
            onPerformAction(action.id)
        } label: {
            multilineButtonLabel(action.title)
        }
        .buttonStyle(.bordered)
        .accessibilityHint(Text("Alternative. Expected result: \(action.expectedResult)"))
    }

    /// Vertically arranged labels avoid truncating prose in narrow inspectors.
    private func labeledText(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            multilineText(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Compact metadata pair used for short action classifications.
    private func compactMetadata(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Metadata fields used in both horizontal and narrow-width layouts.
    @ViewBuilder
    private func actionMetadata(for action: RecommendedAction) -> some View {
        compactMetadata(label: "Effort", value: effortText(for: action.effort))
        compactMetadata(label: "Safety", value: safetyText(for: action.safetyClass))
    }

    /// Shared multiline styling for model-provided prose.
    private func multilineText(_ value: String) -> some View {
        Text(value)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Button text wraps without imposing a full-width control.
    private func multilineButtonLabel(_ title: String) -> some View {
        Text(title)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Localized display value for relative action effort.
    private func effortText(for effort: GuidanceEffort) -> String {
        switch effort {
        case .low:
            String(localized: "Guidance effort low", defaultValue: "Low")
        case .medium:
            String(localized: "Guidance effort medium", defaultValue: "Medium")
        case .high:
            String(localized: "Guidance effort high", defaultValue: "High")
        }
    }

    /// Localized display value for action safety classification.
    private func safetyText(for safetyClass: GuidanceSafetyClass) -> String {
        switch safetyClass {
        case .readOnly:
            String(localized: "Guidance safety read only", defaultValue: "Read-only")
        case .reversible:
            String(localized: "Guidance safety reversible", defaultValue: "Reversible")
        case .requiresConfirmation:
            String(localized: "Guidance safety requires confirmation", defaultValue: "Requires confirmation")
        }
    }

    /// Removes duplicate glossary references while preserving source order.
    private var uniqueGlossaryTerms: [DeveloperTerm] {
        var seen = Set<DeveloperTerm>()
        return guidance.glossaryTerms.filter { seen.insert($0).inserted }
    }

    /// Empty technical disclosures create a false affordance and stay hidden.
    private var hasTechnicalDetails: Bool {
        !guidance.technicalEvidence.isEmpty || !guidance.glossaryTerms.isEmpty
    }
}
