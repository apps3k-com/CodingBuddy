//
//  PackageMaintenanceGuidance.swift
//  CodingBuddy
//

import Foundation

/// Release-note state used by guidance without carrying note content or destinations.
nonisolated enum PackageGuidanceReleaseNotesState: String, Equatable, Sendable {
    /// Release notes have not been requested.
    case idle
    /// Release-note lookup is in progress.
    case loading
    /// Release-note lookup produced a usable result.
    case loaded
    /// No release notes or fallback source could be resolved.
    case unavailable
}

/// Existing Package Maintenance routes that guidance is allowed to request.
nonisolated enum PackageMaintenanceGuidanceRoute: Equatable, Sendable {
    /// Opens the reviewable update-plan flow.
    case prepareUpdatePlan
    /// Opens release notes for the selected target version.
    case openReleaseNotes
    /// Opens package-manager executable settings.
    case openSettings
    /// Repeats the package inventory scan.
    case reload
}

/// Availability of the existing package-maintenance routes when guidance is built.
nonisolated struct PackageMaintenanceGuidanceActionAvailability: Equatable, Sendable {
    /// Whether an update plan can currently be prepared.
    let canPrepareUpdatePlan: Bool
    /// Whether resolved release notes can currently be opened.
    let canOpenReleaseNotes: Bool
    /// Whether package-maintenance settings can currently be opened.
    let canOpenSettings: Bool
    /// Whether the package inventory can currently be reloaded.
    let canReload: Bool

    /// Common test and production state when no package operation blocks a route.
    static let allAvailable = PackageMaintenanceGuidanceActionAvailability(
        canPrepareUpdatePlan: true,
        canOpenReleaseNotes: true,
        canOpenSettings: true,
        canReload: true
    )
}

/// Inspector inputs resolved at the feature boundary so executable tests can cover legacy and guided behavior.
nonisolated struct PackageMaintenanceInspectorPresentation: Equatable, Sendable {
    /// Status shown by the inspector after applying the selected update mode.
    let displayedStatus: PackageStatus
    /// Explainable recommendation shown when guidance is enabled.
    let guidance: Guidance?
}

/// Testable feature-gate seam used by the package maintenance inspector.
nonisolated enum PackageMaintenanceGuidanceViewPolicy {
    /// Resolves the legacy or target-aware status according to the guidance feature flag.
    static func displayedStatus(
        isGuidanceEnabled: Bool,
        package: InstalledPackage,
        mode: PackageUpdateMode
    ) -> PackageStatus {
        guard isGuidanceEnabled else { return package.status }
        return PackageMaintenanceGuidance.selectedStatus(for: package, mode: mode)
    }

    /// Builds the inspector status and optional guidance at the feature-gate boundary.
    static func inspectorPresentation(
        isGuidanceEnabled: Bool,
        package: InstalledPackage,
        mode: PackageUpdateMode,
        releaseNotes: PackageGuidanceReleaseNotesState,
        actionAvailability: PackageMaintenanceGuidanceActionAvailability
    ) -> PackageMaintenanceInspectorPresentation {
        guard isGuidanceEnabled else {
            return PackageMaintenanceInspectorPresentation(
                displayedStatus: package.status,
                guidance: nil
            )
        }
        return PackageMaintenanceInspectorPresentation(
            displayedStatus: displayedStatus(
                isGuidanceEnabled: isGuidanceEnabled,
                package: package,
                mode: mode
            ),
            guidance: PackageMaintenanceGuidance.guidance(
                for: package,
                mode: mode,
                releaseNotes: releaseNotes,
                actionAvailability: actionAvailability
            )
        )
    }
}

/// Pure deterministic guidance for one package and its selected update target.
nonisolated enum PackageMaintenanceGuidance {
    private static let maximumEvidenceLength = 160

    /// Builds one package-specific guidance item from normalized inventory metadata.
    static func guidance(
        for package: InstalledPackage,
        mode: PackageUpdateMode,
        releaseNotes: PackageGuidanceReleaseNotesState,
        actionAvailability: PackageMaintenanceGuidanceActionAvailability = .allAvailable
    ) -> Guidance {
        let state = guidanceState(for: package, mode: mode)

        return switch state {
        case .current:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance current explanation",
                    defaultValue: "The package provider reports this package as current."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance current relevance",
                        defaultValue: "No package update needs review for the selected target."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance current consequence",
                    defaultValue: "Leaving it unchanged keeps the installed version in place."
                ),
                recommendedAction: noUpdateAction(for: package),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .routineUpdate:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance routine update explanation",
                    defaultValue: "The selected target is a newer version that CodingBuddy can prepare for review."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance routine update relevance",
                        defaultValue:
                            "Reviewing the plan shows the exact version change before CodingBuddy runs an update."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance routine update consequence",
                    defaultValue: "Until it is updated, fixes and improvements in the selected version remain unavailable."
                ),
                recommendedAction: reviewUpdateAction(
                    for: package,
                    isMajorTransition: false,
                    targetIsAvailable: true,
                    routeIsAvailable: actionAvailability.canPrepareUpdatePlan
                ),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .majorUpdate:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance major update explanation",
                    defaultValue:
                        "The selected target crosses into a different major version, which may include breaking changes."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance major update relevance",
                        defaultValue:
                            "Compatibility can change across major versions, so review the target and release notes before confirming the update."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance major update consequence",
                    defaultValue:
                        "Updating without checking compatibility could disrupt tools or projects that depend on the current major version."
                ),
                recommendedAction: reviewUpdateAction(
                    for: package,
                    isMajorTransition: true,
                    targetIsAvailable: true,
                    routeIsAvailable: actionAvailability.canPrepareUpdatePlan
                ),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .unavailableUpdate:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance unavailable update explanation",
                    defaultValue:
                        "The provider reports an update, but the selected policy does not provide a different target version."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance unavailable update relevance",
                        defaultValue: "CodingBuddy needs a distinct target version before it can prepare an update plan."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance unavailable update consequence",
                    defaultValue: "No update can be reviewed until a provider reports a usable target version."
                ),
                recommendedAction: reviewUpdateAction(
                    for: package,
                    isMajorTransition: false,
                    targetIsAvailable: false,
                    routeIsAvailable: actionAvailability.canPrepareUpdatePlan
                ),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .pinned:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance pinned explanation",
                    defaultValue: "A Homebrew pin is keeping this package at its installed version."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance pinned relevance",
                        defaultValue: "CodingBuddy respects package pins and will not remove one or update through it."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance pinned consequence",
                    defaultValue: "The package remains on this version until its pin is removed outside CodingBuddy."
                ),
                recommendedAction: unpinAction(for: package),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .selfUpdating:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance self updating explanation",
                    defaultValue: "This cask manages its own application updates."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance self updating relevance",
                        defaultValue: "CodingBuddy does not run a separate package-manager update for self-updating casks."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance self updating consequence",
                    defaultValue: "The application remains responsible for checking and applying its own updates."
                ),
                recommendedAction: selfUpdatingAction(for: package),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .notWritable:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance not writable explanation",
                    defaultValue: "CodingBuddy cannot write to the selected package-manager installation."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance not writable relevance",
                        defaultValue: "An update cannot be prepared safely while that installation is not writable."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance not writable consequence",
                    defaultValue: "Package updates through CodingBuddy remain unavailable for this installation."
                ),
                recommendedAction: openSettingsAction(
                    for: package,
                    isAvailable: actionAvailability.canOpenSettings
                ),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )

        case .unknown:
            Guidance(
                id: guidanceID(for: package, state: state, mode: mode, releaseNotes: releaseNotes),
                explanation: String(
                    localized: "Package guidance unknown explanation",
                    defaultValue: "The last scan could not determine whether this package can be updated."
                ),
                relevance: relevance(
                    String(
                        localized: "Package guidance unknown relevance",
                        defaultValue: "A fresh provider scan may replace the unknown state with current update information."
                    ),
                    package: package,
                    releaseNotes: releaseNotes
                ),
                consequence: String(
                    localized: "Package guidance unknown consequence",
                    defaultValue: "CodingBuddy cannot offer an update while the package state is unknown."
                ),
                recommendedAction: refreshAction(
                    for: package,
                    isAvailable: actionAvailability.canReload
                ),
                alternatives: releaseNotesAlternatives(
                    for: package,
                    state: releaseNotes,
                    isAvailable: actionAvailability.canOpenReleaseNotes
                ),
                technicalEvidence: evidence(for: package, mode: mode),
                glossaryTerms: glossaryTerms(for: package)
            )
        }
    }

    /// Resolves only an available action currently offered by this guidance item.
    static func route(
        for actionID: String,
        in guidance: Guidance,
        package: InstalledPackage
    ) -> PackageMaintenanceGuidanceRoute? {
        let actions = [guidance.recommendedAction] + guidance.alternatives
        guard let action = actions.first(where: { $0.id == actionID }), action.availability == .available else {
            return nil
        }

        return switch actionID {
        case routeActionID(.reviewUpdate, for: package): .prepareUpdatePlan
        case routeActionID(.openReleaseNotes, for: package): .openReleaseNotes
        case routeActionID(.openSettings, for: package): .openSettings
        case routeActionID(.refresh, for: package): .reload
        default: nil
        }
    }

    /// Returns true only when both versions expose different semantic major components.
    static func crossesMajorVersion(from installedVersion: String, to targetVersion: String) -> Bool {
        guard let installedMajor = semanticMajor(in: installedVersion),
              let targetMajor = semanticMajor(in: targetVersion) else {
            return false
        }
        return installedMajor != targetMajor
    }

    /// Explains whether provider errors coexist with retained successful results.
    static func providerIssueSummary(hasSuccessfulResults: Bool) -> String {
        if hasSuccessfulResults {
            String(
                localized: "Package guidance partial provider failure summary",
                defaultValue:
                    "Some package managers could not be scanned. Results from successful providers remain visible."
            )
        } else {
            String(
                localized: "Package guidance provider failure summary",
                defaultValue: "Some package managers could not be scanned."
            )
        }
    }

    /// Status shown for the selected target policy rather than the provider's latest-version summary.
    static func selectedStatus(
        for package: InstalledPackage,
        mode: PackageUpdateMode
    ) -> PackageStatus {
        guard package.status.isUpdateAvailable else { return package.status }
        guard let target = package.targetVersion(for: mode) else { return .unknown }
        guard target != package.installedVersion else { return .current }
        return crossesMajorVersion(from: package.installedVersion, to: target)
            ? .majorUpdateAvailable
            : .updateAvailable
    }

    /// Resolves one guidance state from provider status and the selected target policy.
    private static func guidanceState(
        for package: InstalledPackage,
        mode: PackageUpdateMode
    ) -> PackageGuidanceState {
        switch package.status {
        case .current:
            return .current
        case .updateAvailable, .majorUpdateAvailable:
            guard let target = package.targetVersion(for: mode) else {
                return .unavailableUpdate
            }
            guard target != package.installedVersion else { return .current }
            return crossesMajorVersion(from: package.installedVersion, to: target)
                ? .majorUpdate
                : .routineUpdate
        case .pinned:
            return .pinned
        case .selfUpdating:
            return .selfUpdating
        case .notWritable:
            return .notWritable
        case .unknown:
            return .unknown
        }
    }

    /// Adds dependency and release-note context to the state-specific relevance copy.
    private static func relevance(
        _ base: String,
        package: InstalledPackage,
        releaseNotes: PackageGuidanceReleaseNotesState
    ) -> String {
        [base, dependencyContext(for: package), releaseNotesContext(for: releaseNotes)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Explains whether the selected package was installed directly or transitively.
    private static func dependencyContext(for package: InstalledPackage) -> String {
        if package.isDirect {
            String(
                localized: "Package guidance direct dependency context",
                defaultValue: "This is a direct package that you installed or declared explicitly."
            )
        } else {
            String(
                localized: "Package guidance transitive dependency context",
                defaultValue: "This is a transitive dependency installed because another package needs it."
            )
        }
    }

    /// Explains non-blocking release-note loading and unavailable states.
    private static func releaseNotesContext(for state: PackageGuidanceReleaseNotesState) -> String {
        switch state {
        case .idle, .loaded:
            ""
        case .loading:
            String(
                localized: "Package guidance release notes loading context",
                defaultValue: "Release notes are still being checked and do not block the package guidance."
            )
        case .unavailable:
            String(
                localized: "Package guidance release notes unavailable context",
                defaultValue:
                    "No release notes were found for the selected target; this is normal for some packages and does not change the package status."
            )
        }
    }

    /// Builds the honest no-action state for a current selected target.
    private static func noUpdateAction(for package: InstalledPackage) -> RecommendedAction {
        RecommendedAction(
            id: nonRouteActionID(.noUpdateNeeded, for: package),
            title: String(
                localized: "Package guidance no update action title",
                defaultValue: "No update needed"
            ),
            expectedResult: String(
                localized: "Package guidance no update action result",
                defaultValue: "The package stays at its current installed version."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: .notNeeded(reason: String(
                localized: "Package guidance no update action reason",
                defaultValue: "The provider reports no available update for the selected target."
            ))
        )
    }

    /// Builds the confirmation-gated route to the existing update-plan preview.
    private static func reviewUpdateAction(
        for package: InstalledPackage,
        isMajorTransition: Bool,
        targetIsAvailable: Bool,
        routeIsAvailable: Bool
    ) -> RecommendedAction {
        RecommendedAction(
            id: routeActionID(.reviewUpdate, for: package),
            title: isMajorTransition
                ? String(
                    localized: "Package guidance review major update action title",
                    defaultValue: "Review major update"
                )
                : String(
                    localized: "Package guidance review update action title",
                    defaultValue: "Review update"
                ),
            expectedResult: String(
                localized: "Package guidance review update action result",
                defaultValue:
                    "CodingBuddy prepares the existing update plan and asks for confirmation before running it."
            ),
            effort: isMajorTransition ? .medium : .low,
            safetyClass: .requiresConfirmation,
            availability: !targetIsAvailable
                ? .unavailable(reason: String(
                    localized: "Package guidance review update unavailable reason",
                    defaultValue: "The selected policy does not provide a different target version."
                ))
                : routeIsAvailable
                    ? .available
                    : .unavailable(reason: String(
                        localized: "Package guidance operation busy unavailable reason",
                        defaultValue: "Wait for the current package operation to finish."
                    ))
        )
    }

    /// Describes the external Homebrew unpin step without offering unsupported mutation.
    private static func unpinAction(for package: InstalledPackage) -> RecommendedAction {
        RecommendedAction(
            id: nonRouteActionID(.unpin, for: package),
            title: String(
                localized: "Package guidance unpin action title",
                defaultValue: "Unpin in Homebrew"
            ),
            expectedResult: String(
                localized: "Package guidance unpin action result",
                defaultValue:
                    "After the pin is removed outside CodingBuddy, a refresh can detect whether an update is available."
            ),
            effort: .medium,
            safetyClass: .reversible,
            availability: .unavailable(reason: String(
                localized: "Package guidance unpin unavailable reason",
                defaultValue: "CodingBuddy does not remove Homebrew package pins."
            ))
        )
    }

    /// Builds a no-action state for applications that own their update process.
    private static func selfUpdatingAction(for package: InstalledPackage) -> RecommendedAction {
        RecommendedAction(
            id: nonRouteActionID(.selfUpdate, for: package),
            title: String(
                localized: "Package guidance self updating action title",
                defaultValue: "No CodingBuddy update needed"
            ),
            expectedResult: String(
                localized: "Package guidance self updating action result",
                defaultValue: "The application keeps using its own update mechanism."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: .notNeeded(reason: String(
                localized: "Package guidance self updating action reason",
                defaultValue: "CodingBuddy does not directly update self-updating casks."
            ))
        )
    }

    /// Builds the existing read-only route to package-manager settings.
    private static func openSettingsAction(
        for package: InstalledPackage,
        isAvailable: Bool
    ) -> RecommendedAction {
        RecommendedAction(
            id: routeActionID(.openSettings, for: package),
            title: String(localized: "Open Settings", defaultValue: "Open Settings"),
            expectedResult: String(
                localized: "Package guidance open settings action result",
                defaultValue: "Package manager settings open so you can review the selected executable."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable
                ? .available
                : .unavailable(reason: String(
                    localized: "Package guidance open settings unavailable reason",
                    defaultValue: "Settings cannot be opened from this view."
                ))
        )
    }

    /// Builds the existing read-only provider rescan route.
    private static func refreshAction(
        for package: InstalledPackage,
        isAvailable: Bool
    ) -> RecommendedAction {
        RecommendedAction(
            id: routeActionID(.refresh, for: package),
            title: String(localized: "Refresh", defaultValue: "Refresh"),
            expectedResult: String(
                localized: "Package guidance refresh action result",
                defaultValue: "CodingBuddy scans the package managers again and refreshes their reported states."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable
                ? .available
                : .unavailable(reason: String(
                    localized: "Package guidance refresh unavailable reason",
                    defaultValue: "Refresh is unavailable while a package operation is running."
                ))
        )
    }

    /// Adds a read-only release-note alternative only after notes have loaded.
    private static func releaseNotesAlternatives(
        for package: InstalledPackage,
        state: PackageGuidanceReleaseNotesState,
        isAvailable: Bool
    ) -> [RecommendedAction] {
        guard state == .loaded else { return [] }
        return [RecommendedAction(
            id: routeActionID(.openReleaseNotes, for: package),
            title: String(localized: "Open Release Notes", defaultValue: "Open Release Notes"),
            expectedResult: String(
                localized: "Package guidance open release notes action result",
                defaultValue: "The available release notes open in your default browser."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: isAvailable
                ? .available
                : .unavailable(reason: String(
                    localized: "Package guidance release notes unavailable reason",
                    defaultValue: "Release notes cannot be opened from this view."
                ))
        )]
    }

    /// Evidence is allowlisted and ordered; installation and release-note fields are intentionally absent.
    private static func evidence(
        for package: InstalledPackage,
        mode: PackageUpdateMode
    ) -> [TechnicalEvidence] {
        let instance = instanceID(for: package)
        let missing = String(
            localized: "Package guidance evidence not reported",
            defaultValue: "Not reported"
        )

        return [
            TechnicalEvidence(
                id: evidenceID("manager", instance: instance),
                label: String(localized: "Package guidance evidence manager", defaultValue: "Manager"),
                sanitizedValue: sanitized(package.manager.displayName, fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("package-name", instance: instance),
                label: String(localized: "Package guidance evidence package name", defaultValue: "Package"),
                sanitizedValue: sanitized(package.name, fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("package-kind", instance: instance),
                label: String(localized: "Package guidance evidence package kind", defaultValue: "Package kind"),
                sanitizedValue: sanitized(packageKindName(package.kind), fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("installed-version", instance: instance),
                label: String(
                    localized: "Package guidance evidence installed version",
                    defaultValue: "Installed version"
                ),
                sanitizedValue: sanitized(package.installedVersion, fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("wanted-version", instance: instance),
                label: String(
                    localized: "Package guidance evidence wanted version",
                    defaultValue: "Compatible version"
                ),
                sanitizedValue: sanitized(package.wantedVersion, fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("latest-version", instance: instance),
                label: String(
                    localized: "Package guidance evidence latest version",
                    defaultValue: "Latest version"
                ),
                sanitizedValue: sanitized(package.latestVersion, fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("selected-target-version", instance: instance),
                label: String(
                    localized: "Package guidance evidence selected target version",
                    defaultValue: "Selected target"
                ),
                sanitizedValue: sanitized(package.targetVersion(for: mode), fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("dependency-classification", instance: instance),
                label: String(
                    localized: "Package guidance evidence dependency classification",
                    defaultValue: "Dependency classification"
                ),
                sanitizedValue: sanitized(dependencyClassification(package), fallback: missing)
            ),
            TechnicalEvidence(
                id: evidenceID("status", instance: instance),
                label: String(
                    localized: "Package guidance evidence status",
                    defaultValue: "Provider status"
                ),
                sanitizedValue: sanitized(package.status.displayName, fallback: missing)
            ),
        ]
    }

    /// Localizes the normalized package kind for technical evidence.
    private static func packageKindName(_ kind: PackageKind) -> String {
        switch kind {
        case .formula:
            String(localized: "Package guidance kind formula", defaultValue: "Formula")
        case .cask:
            String(localized: "Package guidance kind cask", defaultValue: "Cask")
        case .nodePackage:
            String(localized: "Package guidance kind node package", defaultValue: "Node package")
        }
    }

    /// Localizes the direct-versus-transitive evidence value.
    private static func dependencyClassification(_ package: InstalledPackage) -> String {
        package.isDirect
            ? String(localized: "Package guidance dependency direct", defaultValue: "Direct")
            : String(localized: "Package guidance dependency transitive", defaultValue: "Transitive")
    }

    /// Attaches only glossary entries used by the package explanation.
    private static func glossaryTerms(for package: InstalledPackage) -> [DeveloperTerm] {
        package.status == .pinned
            ? [.packagePin, .directDependency]
            : [.directDependency]
    }

    /// Combines package identity and every copy-shaping state into a stable guidance ID.
    private static func guidanceID(
        for package: InstalledPackage,
        state: PackageGuidanceState,
        mode: PackageUpdateMode,
        releaseNotes: PackageGuidanceReleaseNotesState
    ) -> String {
        "package-maintenance.guidance.\(instanceID(for: package)).\(state.rawValue).\(mode.rawValue).\(releaseNotes.rawValue)"
    }

    /// Creates an instance-specific identifier for an executable route.
    private static func routeActionID(_ action: RouteAction, for package: InstalledPackage) -> String {
        "package-maintenance.route.\(instanceID(for: package)).\(action.rawValue)"
    }

    /// Creates an instance-specific identifier for informational actions.
    private static func nonRouteActionID(_ action: NonRouteAction, for package: InstalledPackage) -> String {
        "package-maintenance.action.\(instanceID(for: package)).\(action.rawValue)"
    }

    /// Creates a unique evidence identity for one package field.
    private static func evidenceID(_ field: String, instance: String) -> String {
        "package-maintenance.evidence.\(instance).\(field)"
    }

    /// A stable hash keeps identifiers bounded without exposing configuration-derived names.
    private static func instanceID(for package: InstalledPackage) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in package.id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(package.manager.rawValue).\(package.kind.rawValue).\(String(hash, radix: 16))"
    }

    /// Removes controls and directional formatting, collapses whitespace, and bounds evidence.
    private static func sanitized(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        var result = ""
        var previousWasSeparator = false

        for scalar in value.unicodeScalars {
            let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || isDirectionalFormattingScalar(scalar.value)
            if isSeparator {
                if !result.isEmpty, !previousWasSeparator {
                    result.append(" ")
                }
                previousWasSeparator = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            }
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return fallback }
        guard result.count > maximumEvidenceLength else { return result }
        return String(result.prefix(maximumEvidenceLength - 3)) + "..."
    }

    /// Rejects invisible Unicode formatting that could misrepresent evidence order.
    private static func isDirectionalFormattingScalar(_ value: UInt32) -> Bool {
        (0x200B...0x200F).contains(value)
            || (0x202A...0x202E).contains(value)
            || (0x2060...0x2069).contains(value)
    }

    /// Parses a bounded leading semantic major component with an optional v prefix.
    private static func semanticMajor(in version: String) -> UInt64? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        var iterator = trimmed.utf8.makeIterator()
        var byte = iterator.next()
        if byte == 118 || byte == 86 {
            byte = iterator.next()
        }

        var digits: [UInt8] = []
        while let current = byte, (48...57).contains(current) {
            guard digits.count < 20 else { return nil }
            digits.append(current)
            byte = iterator.next()
        }

        guard !digits.isEmpty, byte == nil || byte == 46 else { return nil }
        return UInt64(String(decoding: digits, as: UTF8.self))
    }
}

private nonisolated enum PackageGuidanceState: String, Sendable {
    /// The installed package already matches the selected target.
    case current
    /// A non-major update is available.
    case routineUpdate = "routine-update"
    /// The selected target crosses a major-version boundary.
    case majorUpdate = "major-update"
    /// Inventory reports an update but no exact target can be selected.
    case unavailableUpdate = "unavailable-update"
    /// Package-manager policy prevents updating a pinned package.
    case pinned
    /// The package delegates updates to its own updater.
    case selfUpdating = "self-updating"
    /// The discovered package-manager installation is not writable.
    case notWritable = "not-writable"
    /// Available metadata cannot support a stronger package-state claim.
    case unknown
}

private nonisolated enum RouteAction: String, Sendable {
    /// Requests review of a generated update plan.
    case reviewUpdate = "review-update"
    /// Requests navigation to resolved release notes.
    case openReleaseNotes = "open-release-notes"
    /// Requests navigation to package-manager settings.
    case openSettings = "open-settings"
    /// Requests a fresh package scan.
    case refresh
}

private nonisolated enum NonRouteAction: String, Sendable {
    /// Indicates that the selected target requires no package change.
    case noUpdateNeeded = "no-update-needed"
    /// Recommends removing an external package-manager pin.
    case unpin
    /// Recommends using the package's own update mechanism.
    case selfUpdate = "self-update"
}
