//
//  PackageMaintenanceGuidanceTests.swift
//  CodingBuddyTests
//

import Foundation
import Testing
@testable import CodingBuddy

struct PackageMaintenanceGuidanceTests {
    @Test func everyPackageStatusHasAnHonestPrimaryAction() {
        let statuses: [PackageStatus] = [
            .current,
            .updateAvailable,
            .majorUpdateAvailable,
            .pinned,
            .selfUpdating,
            .notWritable,
            .unknown,
        ]

        for status in statuses {
            let package = makePackage(status: status)
            let guidance = makeGuidance(for: package)

            #expect(!guidance.explanation.isEmpty)
            #expect(!guidance.relevance.isEmpty)
            #expect(!guidance.consequence.isEmpty)

            switch status {
            case .current:
                expectNotNeeded(guidance.recommendedAction)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == nil)
            case .updateAvailable, .majorUpdateAvailable:
                #expect(guidance.recommendedAction.availability == .available)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == .prepareUpdatePlan)
            case .pinned:
                expectUnavailable(guidance.recommendedAction)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == nil)
                #expect(guidance.glossaryTerms.contains(.packagePin))
            case .selfUpdating:
                expectNotNeeded(guidance.recommendedAction)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == nil)
            case .notWritable:
                #expect(guidance.recommendedAction.availability == .available)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == .openSettings)
            case .unknown:
                #expect(guidance.recommendedAction.availability == .available)
                #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == .reload)
            }
        }
    }

    @Test func majorStatusDescribesTheSelectedCompatibleOrLatestTarget() throws {
        let package = makePackage(
            status: .majorUpdateAvailable,
            installedVersion: "5.4.0",
            wantedVersion: "5.5.2",
            latestVersion: "6.0.1"
        )

        let compatible = makeGuidance(for: package, mode: .compatible)
        let latest = makeGuidance(for: package, mode: .latest)

        #expect(!compatible.recommendedAction.title.isEmpty)
        #expect(!latest.recommendedAction.title.isEmpty)
        #expect(compatible.recommendedAction.title != latest.recommendedAction.title)
        #expect(compatible.explanation != latest.explanation)
        #expect(evidenceValue("selected-target-version", in: compatible) == "5.5.2")
        #expect(evidenceValue("selected-target-version", in: latest) == "6.0.1")
        #expect(compatible.id != latest.id)
        #expect(route(for: compatible.recommendedAction, guidance: compatible, package: package) == .prepareUpdatePlan)
        #expect(route(for: latest.recommendedAction, guidance: latest, package: package) == .prepareUpdatePlan)
        #expect(PackageMaintenanceGuidance.selectedStatus(for: package, mode: .compatible) == .updateAvailable)
        #expect(PackageMaintenanceGuidance.selectedStatus(for: package, mode: .latest) == .majorUpdateAvailable)
    }

    @Test func selectedTargetDeterminesMajorGuidanceEvenWhenProviderStatusIsRoutine() {
        let package = makePackage(
            status: .updateAvailable,
            installedVersion: "1.4.0",
            wantedVersion: "2.0.0",
            latestVersion: "2.0.0"
        )
        let guidance = makeGuidance(for: package)

        #expect(guidance.id.contains(".major-update."))
        #expect(guidance.recommendedAction.title.localizedCaseInsensitiveContains("major"))
        #expect(PackageMaintenanceGuidance.selectedStatus(for: package, mode: .compatible) == .majorUpdateAvailable)
    }

    @Test func selectedStatusReportsCurrentWhenCompatiblePolicyHasNoVersionChange() {
        let package = makePackage(
            status: .majorUpdateAvailable,
            installedVersion: "5.4.0",
            wantedVersion: "5.4.0",
            latestVersion: "6.0.0"
        )

        #expect(PackageMaintenanceGuidance.selectedStatus(for: package, mode: .compatible) == .current)
        #expect(PackageMaintenanceGuidance.selectedStatus(for: package, mode: .latest) == .majorUpdateAvailable)

        let compatible = makeGuidance(for: package, mode: .compatible)
        #expect(compatible.id.contains(".current."))
        expectNotNeeded(compatible.recommendedAction)
        #expect(route(for: compatible.recommendedAction, guidance: compatible, package: package) == nil)
    }

    @Test func semanticMajorComparisonIsSmallAndDeterministic() {
        #expect(!PackageMaintenanceGuidance.crossesMajorVersion(from: "5.4.0", to: "5.5.2"))
        #expect(PackageMaintenanceGuidance.crossesMajorVersion(from: "5.4.0", to: "6.0.0"))
        #expect(PackageMaintenanceGuidance.crossesMajorVersion(from: "v5.4.0", to: "V6.0.0-beta.1"))
        #expect(!PackageMaintenanceGuidance.crossesMajorVersion(from: "release-5", to: "release-6"))
        #expect(!PackageMaintenanceGuidance.crossesMajorVersion(from: "5.4.0", to: "5"))
    }

    @Test func unavailableSelectedTargetCannotReachTheUpdateRoute() {
        let missingTarget = makePackage(
            status: .updateAvailable,
            installedVersion: "1.0.0",
            wantedVersion: nil,
            latestVersion: nil
        )
        let guidance = makeGuidance(for: missingTarget)
        expectUnavailable(guidance.recommendedAction)
        #expect(route(for: guidance.recommendedAction, guidance: guidance, package: missingTarget) == nil)
    }

    @Test func missingOrLoadingReleaseNotesDoNotBlockUpdateGuidance() {
        let package = makePackage(status: .updateAvailable)

        for state in [PackageGuidanceReleaseNotesState.loading, .unavailable] {
            let guidance = makeGuidance(for: package, releaseNotes: state)
            #expect(guidance.recommendedAction.availability == .available)
            #expect(guidance.alternatives.isEmpty)
            #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == .prepareUpdatePlan)
        }

        let unavailable = makeGuidance(for: package, releaseNotes: .unavailable)
        #expect(unavailable.relevance.localizedCaseInsensitiveContains("normal"))
    }

    @Test func loadedReleaseNotesAddOnlyTheReadOnlyOpenAlternative() throws {
        let package = makePackage(status: .pinned)
        let guidance = makeGuidance(for: package, releaseNotes: .loaded)
        let alternative = try #require(guidance.alternatives.first)

        #expect(guidance.alternatives.count == 1)
        #expect(alternative.id.hasPrefix("package-maintenance.route."))
        #expect(alternative.id.hasSuffix(".open-release-notes"))
        #expect(alternative.safetyClass == .readOnly)
        #expect(route(for: alternative, guidance: guidance, package: package) == .openReleaseNotes)
        expectUnavailable(guidance.recommendedAction)
    }

    @Test func busyPackageOperationsDisableMutatingAndReloadRoutes() {
        let unavailable = PackageMaintenanceGuidanceActionAvailability(
            canPrepareUpdatePlan: false,
            canOpenReleaseNotes: true,
            canOpenSettings: true,
            canReload: false
        )
        let updatePackage = makePackage(status: .updateAvailable)
        let updateGuidance = PackageMaintenanceGuidance.guidance(
            for: updatePackage,
            mode: .compatible,
            releaseNotes: .unavailable,
            actionAvailability: unavailable
        )
        let unknownPackage = makePackage(status: .unknown)
        let unknownGuidance = PackageMaintenanceGuidance.guidance(
            for: unknownPackage,
            mode: .compatible,
            releaseNotes: .unavailable,
            actionAvailability: unavailable
        )

        expectUnavailable(updateGuidance.recommendedAction)
        expectUnavailable(unknownGuidance.recommendedAction)
        #expect(route(for: updateGuidance.recommendedAction, guidance: updateGuidance, package: updatePackage) == nil)
        #expect(route(for: unknownGuidance.recommendedAction, guidance: unknownGuidance, package: unknownPackage) == nil)
    }

    @Test func directAndTransitivePackagesExplainTheirClassification() {
        let direct = makeGuidance(for: makePackage(status: .current, isDirect: true))
        let transitive = makeGuidance(for: makePackage(status: .current, isDirect: false))

        let directClassification = evidenceValue("dependency-classification", in: direct)
        let transitiveClassification = evidenceValue("dependency-classification", in: transitive)
        #expect(directClassification?.isEmpty == false)
        #expect(transitiveClassification?.isEmpty == false)
        #expect(directClassification != transitiveClassification)
        #expect(direct.relevance != transitive.relevance)
        #expect(direct.glossaryTerms == [.directDependency])
        #expect(transitive.glossaryTerms == [.directDependency])
    }

    @Test func identityAndActionIDsAreDeterministicAndInstanceSpecific() {
        let firstPackage = makePackage(name: "first", status: .updateAvailable)
        let secondPackage = makePackage(name: "second", status: .updateAvailable)
        let first = makeGuidance(for: firstPackage, releaseNotes: .loaded)
        let repeated = makeGuidance(for: firstPackage, releaseNotes: .loaded)
        let second = makeGuidance(for: secondPackage, releaseNotes: .loaded)

        #expect(first == repeated)
        #expect(first.id.hasPrefix("package-maintenance.guidance."))
        #expect(first.id != second.id)
        #expect(first.recommendedAction.id != second.recommendedAction.id)
        #expect(first.recommendedAction.id.hasPrefix("package-maintenance.route."))
        #expect(first.recommendedAction.id.hasSuffix(".review-update"))
        #expect(first.alternatives.first?.id.hasSuffix(".open-release-notes") == true)
        #expect(Set(first.technicalEvidence.map(\.id)).count == first.technicalEvidence.count)
        #expect(first.technicalEvidence.allSatisfy { $0.id.hasPrefix("package-maintenance.evidence.") })
        #expect(first.technicalEvidence.map(\.id) != second.technicalEvidence.map(\.id))
    }

    @Test func evidenceIsOrderedBoundedSanitizedAndAllowlisted() {
        let longVersion = String(repeating: "9", count: 220)
        let package = InstalledPackage(
            manager: .npm,
            kind: .nodePackage,
            name: "  package\n\u{202E}name  ",
            installedVersion: "1.0\nSECRET_CONTROL",
            wantedVersion: longVersion,
            latestVersion: "2.0.0",
            isDirect: false,
            status: .updateAvailable,
            homepageURL: URL(string: "https://example.test/?token=URL_SECRET"),
            repositoryURL: URL(string: "https://user:password@example.test/URL_SECRET"),
            installationID: "/Users/private/INSTALLATION_SECRET"
        )
        let guidance = makeGuidance(for: package, releaseNotes: .loaded)
        let evidence = guidance.technicalEvidence
        let values = evidence.map(\.sanitizedValue)
        let rendered = allText(in: guidance)

        #expect(evidence.map { $0.id.split(separator: ".").last.map(String.init) } == [
            "manager",
            "package-name",
            "package-kind",
            "installed-version",
            "wanted-version",
            "latest-version",
            "selected-target-version",
            "dependency-classification",
            "status",
        ])
        #expect(values.allSatisfy { $0.count <= 160 })
        #expect(values.allSatisfy { !$0.contains("\n") && !$0.contains("\t") && !$0.contains("\u{202E}") })
        #expect(evidenceValue("package-name", in: guidance) == "package name")
        #expect(evidenceValue("wanted-version", in: guidance)?.hasSuffix("...") == true)
        #expect(!rendered.contains("INSTALLATION_SECRET"))
        #expect(!rendered.contains("URL_SECRET"))
        #expect(!rendered.contains("user:password"))
    }

    @Test func providerIssueSummaryPreservesSuccessfulResultContext() {
        let partial = PackageMaintenanceGuidance.providerIssueSummary(hasSuccessfulResults: true)
        let complete = PackageMaintenanceGuidance.providerIssueSummary(hasSuccessfulResults: false)

        #expect(!partial.isEmpty)
        #expect(!complete.isEmpty)
        #expect(partial != complete)
    }

    @Test func featureBoundaryPreservesLegacyPresentationAndEnablesGuidanceExplicitly() throws {
        let package = makePackage(
            status: .majorUpdateAvailable,
            installedVersion: "5.4.0",
            wantedVersion: "5.4.0",
            latestVersion: "6.0.0"
        )
        let legacy = PackageMaintenanceGuidanceViewPolicy.inspectorPresentation(
            isGuidanceEnabled: false,
            package: package,
            mode: .compatible,
            releaseNotes: .loaded,
            actionAvailability: .allAvailable
        )
        let guided = PackageMaintenanceGuidanceViewPolicy.inspectorPresentation(
            isGuidanceEnabled: true,
            package: package,
            mode: .compatible,
            releaseNotes: .loaded,
            actionAvailability: .allAvailable
        )

        #expect(legacy.displayedStatus == .majorUpdateAvailable)
        #expect(legacy.guidance == nil)
        #expect(guided.displayedStatus == .current)
        #expect(try #require(guided.guidance).id.contains(".current."))
    }

    @Test func updateGuidanceDeclaresTheExistingConfirmationBoundary() {
        let package = makePackage(status: .updateAvailable)
        let guidance = makeGuidance(for: package)

        #expect(guidance.recommendedAction.safetyClass == .requiresConfirmation)
        #expect(route(for: guidance.recommendedAction, guidance: guidance, package: package) == .prepareUpdatePlan)
    }

    private func makeGuidance(
        for package: InstalledPackage,
        mode: PackageUpdateMode = .compatible,
        releaseNotes: PackageGuidanceReleaseNotesState = .unavailable
    ) -> Guidance {
        PackageMaintenanceGuidance.guidance(for: package, mode: mode, releaseNotes: releaseNotes)
    }

    private func makePackage(
        name: String = "example-package",
        status: PackageStatus,
        installedVersion: String = "5.4.0",
        wantedVersion: String? = "5.5.2",
        latestVersion: String? = "6.0.1",
        isDirect: Bool = true
    ) -> InstalledPackage {
        InstalledPackage(
            manager: .npm,
            kind: .nodePackage,
            name: name,
            installedVersion: installedVersion,
            wantedVersion: wantedVersion,
            latestVersion: latestVersion,
            isDirect: isDirect,
            status: status,
            homepageURL: nil,
            repositoryURL: nil,
            installationID: "/usr/local/bin/npm"
        )
    }

    private func route(
        for action: RecommendedAction,
        guidance: Guidance,
        package: InstalledPackage
    ) -> PackageMaintenanceGuidanceRoute? {
        PackageMaintenanceGuidance.route(for: action.id, in: guidance, package: package)
    }

    private func evidenceValue(_ suffix: String, in guidance: Guidance) -> String? {
        guidance.technicalEvidence.first { $0.id.hasSuffix(".\(suffix)") }?.sanitizedValue
    }

    private func expectNotNeeded(_ action: RecommendedAction) {
        guard case let .notNeeded(reason) = action.availability else {
            Issue.record("Expected no action to be needed")
            return
        }
        #expect(!reason.isEmpty)
    }

    private func expectUnavailable(_ action: RecommendedAction) {
        guard case let .unavailable(reason) = action.availability else {
            Issue.record("Expected the action to be unavailable")
            return
        }
        #expect(!reason.isEmpty)
    }

    private func allText(in guidance: Guidance) -> String {
        let actions = [guidance.recommendedAction] + guidance.alternatives
        let actionText = actions.flatMap { action -> [String] in
            let availabilityReason = switch action.availability {
            case .available: ""
            case .notNeeded(let reason), .unavailable(let reason): reason
            }
            return [action.title, action.expectedResult, availabilityReason]
        }
        return ([guidance.explanation, guidance.relevance, guidance.consequence]
            + actionText
            + guidance.technicalEvidence.flatMap { [$0.label, $0.sanitizedValue] })
            .joined(separator: "\n")
    }
}
