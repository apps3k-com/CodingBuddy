//
//  SecretsGuardTests.swift
//  CodingBuddyTests
//

import Foundation
import LocalAuthentication
import Testing
@testable import CodingBuddy

/// Deterministic authentication boundary that lets a test revoke access while
/// a simulated system prompt is still pending.
private actor ControlledAuthenticator {
    private var resultContinuation: CheckedContinuation<Bool, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var started = false

    /// Suspends until the test supplies the authentication result.
    func authenticate() async -> Bool {
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    /// Waits until ``authenticate()`` has entered its suspended state.
    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    /// Completes the simulated system prompt.
    func complete(with result: Bool) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

/// Deterministic failing boundary used to complete an authentication error after revocation.
private actor ControlledFailingAuthenticator {
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var started = false

    /// Suspends until the test releases the simulated system prompt, then fails.
    func authenticate() async throws -> Bool {
        started = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        await withCheckedContinuation { completionContinuation = $0 }
        throw AuthenticationFailure.failed
    }

    /// Waits until ``authenticate()`` has entered its suspended state.
    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    /// Releases the simulated prompt so it can publish its failure.
    func fail() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}

/// Pure synthetic failure distinct from a user or task cancellation.
nonisolated private enum AuthenticationFailure: Error {
    case failed
}

@MainActor
struct SecretsGuardTests {
    @Test func successfulAuthenticationUnlocksWithoutError() async {
        let guardStore = SecretsGuard { _ in true }

        #expect(await guardStore.requestUnlock())
        #expect(guardStore.isUnlocked)
        #expect(guardStore.lastError == nil)
    }

    @Test func userCancellationStaysSilent() async {
        let guardStore = SecretsGuard { _ in
            throw NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)
        }

        #expect(!(await guardStore.requestUnlock()))
        #expect(!guardStore.isUnlocked)
        #expect(guardStore.lastError == nil)
    }

    @Test func systemFailureProducesRecoverableMessage() async {
        let guardStore = SecretsGuard { _ in
            throw NSError(domain: LAError.errorDomain, code: LAError.Code.notInteractive.rawValue)
        }

        #expect(!(await guardStore.requestUnlock()))
        #expect(!guardStore.isUnlocked)
        #expect(guardStore.lastError != nil)

        guardStore.clearError()
        #expect(guardStore.lastError == nil)
    }

    /// Verifies views distinguish genuine failures from cancellation without exposing raw errors.
    @Test func authenticationPresentationSurfacesOnlySanitizedFailures() {
        let sanitizedMessage = String(
            localized: "Authentication could not be completed. Check your Mac authentication settings and try again."
        )

        #expect(
            SecretAuthenticationPresentation.resolve(
                didUnlock: true,
                errorMessage: sanitizedMessage
            ) == .succeeded
        )
        #expect(
            SecretAuthenticationPresentation.resolve(
                didUnlock: false,
                errorMessage: nil
            ) == .silentFailure
        )
        #expect(
            SecretAuthenticationPresentation.resolve(
                didUnlock: false,
                errorMessage: sanitizedMessage
            ) == .visibleFailure(sanitizedMessage)
        )
    }

    @Test func lateAuthenticationCannotReopenAfterLock() async {
        let authenticator = ControlledAuthenticator()
        let guardStore = SecretsGuard { _ in await authenticator.authenticate() }
        let request = Task { await guardStore.requestUnlock() }

        await authenticator.waitUntilStarted()
        guardStore.lock()
        await authenticator.complete(with: true)

        #expect(!(await request.value))
        #expect(!guardStore.isUnlocked)
    }

    /// Verifies cancelling only the requesting task cannot globally unlock the shared guard.
    @Test func cancelledRequestCannotUnlockAfterAuthenticationCompletes() async {
        let authenticator = ControlledAuthenticator()
        let guardStore = SecretsGuard { _ in await authenticator.authenticate() }
        let request = Task { await guardStore.requestUnlock() }

        await authenticator.waitUntilStarted()
        request.cancel()
        await authenticator.complete(with: true)

        #expect(!(await request.value))
        #expect(!guardStore.isUnlocked)
    }

    /// Verifies a failure completed after an explicit lock cannot publish a stale alert.
    @Test func lateAuthenticationFailureAfterLockStaysSilent() async {
        let authenticator = ControlledFailingAuthenticator()
        let guardStore = SecretsGuard { _ in try await authenticator.authenticate() }
        let request = Task { await guardStore.requestUnlock() }

        await authenticator.waitUntilStarted()
        guardStore.lock()
        await authenticator.fail()

        #expect(!(await request.value))
        #expect(guardStore.lastError == nil)
    }

    /// Verifies task cancellation suppresses both CancellationError and later unrelated failures.
    @Test func taskCancelledAuthenticationFailuresStaySilent() async {
        let directCancellation = SecretsGuard { _ in throw CancellationError() }
        #expect(!(await directCancellation.requestUnlock()))
        #expect(directCancellation.lastError == nil)

        let authenticator = ControlledFailingAuthenticator()
        let delayedFailure = SecretsGuard { _ in try await authenticator.authenticate() }
        let request = Task { await delayedFailure.requestUnlock() }
        await authenticator.waitUntilStarted()
        request.cancel()
        await authenticator.fail()

        #expect(!(await request.value))
        #expect(delayedFailure.lastError == nil)
    }

    @Test func relockWarningTimingIsDeterministic() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(MCPAuthRelockTiming.warningDelay(until: nil, now: now) == nil)
        #expect(MCPAuthRelockTiming.warningDelay(until: .distantFuture, now: now) == nil)
        #expect(
            MCPAuthRelockTiming.warningDelay(
                until: now.addingTimeInterval(90),
                now: now
            ) == 60
        )
        #expect(
            MCPAuthRelockTiming.warningDelay(
                until: now.addingTimeInterval(30),
                now: now
            ) == 0
        )
        #expect(
            MCPAuthRelockTiming.shouldWarn(
                until: now.addingTimeInterval(10),
                now: now
            )
        )
        #expect(!MCPAuthRelockTiming.shouldWarn(until: now, now: now))
        #expect(SecretDraftRelockTiming.warningDelay(until: nil, now: now) == nil)
        #expect(SecretDraftRelockTiming.warningDelay(until: .distantFuture, now: now) == nil)
        #expect(
            SecretDraftRelockTiming.warningDelay(
                until: now.addingTimeInterval(75),
                now: now
            ) == 45
        )
        #expect(
            SecretDraftRelockTiming.warningDelay(
                until: now.addingTimeInterval(15),
                now: now
            ) == 0
        )
    }

    /// Verifies expiry never discards ordinary PATH or non-sensitive variable drafts.
    @Test func automaticRelockPreservesDraftWithoutRevealedStoreSecret() {
        #expect(
            SecretDraftProtectionPolicy.automaticRelock(
                protectsRevealedSecret: false,
                hasUnsavedChanges: true
            ) == .preserveDraft
        )
    }

    /// Verifies a sensitive name entered after sheet creation activates draft protection.
    @Test func liveSensitiveNameProtectsNewDraftWhenFeatureIsEnabled() {
        #expect(SecretDraftProtectionPolicy.protectsDraft(
            protectsRevealedSecret: false,
            currentName: "GITHUB_TOKEN",
            protectionEnabled: true
        ))
        #expect(!SecretDraftProtectionPolicy.protectsDraft(
            protectsRevealedSecret: false,
            currentName: "PATH",
            protectionEnabled: true
        ))
        #expect(!SecretDraftProtectionPolicy.protectsDraft(
            protectsRevealedSecret: false,
            currentName: "GITHUB_TOKEN",
            protectionEnabled: false
        ))
        #expect(SecretDraftProtectionPolicy.protectsDraft(
            protectsRevealedSecret: true,
            currentName: "PATH",
            protectionEnabled: false
        ))
    }

    /// Verifies renaming a draft cannot remove protection after sensitive cleartext was owned.
    @Test func sensitiveDraftProtectionRemainsLatchedAfterRename() {
        let protected = SecretDraftProtectionPolicy.latchedProtection(
            wasProtected: false,
            protectsRevealedSecret: false,
            currentName: "GITHUB_TOKEN",
            protectionEnabled: true
        )

        #expect(protected)
        #expect(SecretDraftProtectionPolicy.latchedProtection(
            wasProtected: protected,
            protectsRevealedSecret: false,
            currentName: "PATH",
            protectionEnabled: true
        ))
        #expect(SecretDraftProtectionPolicy.protectionBecameActive(
            wasProtected: false,
            isProtected: protected
        ))
        #expect(!SecretDraftProtectionPolicy.protectionBecameActive(
            wasProtected: protected,
            isProtected: true
        ))
    }

    /// Verifies a same-update sensitive rename cannot race ahead of the sticky state callback.
    @Test func sensitiveRenameUsesCurrentEvidenceDuringAutomaticRelock() {
        let effectiveProtection = SecretDraftProtectionPolicy.latchedProtection(
            wasProtected: false,
            protectsRevealedSecret: false,
            currentName: "GITHUB_TOKEN",
            protectionEnabled: true
        )

        #expect(SecretDraftProtectionPolicy.automaticRelock(
            protectsRevealedSecret: effectiveProtection,
            hasUnsavedChanges: true
        ) == .clearAndDismiss(reportDiscard: true))
    }

    /// Verifies expiry clears a revealed secret and reports only meaningful lost edits.
    @Test func automaticRelockClearsRevealedSecretAndTracksDirtyState() {
        #expect(
            SecretDraftProtectionPolicy.automaticRelock(
                protectsRevealedSecret: true,
                hasUnsavedChanges: false
            ) == .clearAndDismiss(reportDiscard: false)
        )
        #expect(
            SecretDraftProtectionPolicy.automaticRelock(
                protectsRevealedSecret: true,
                hasUnsavedChanges: true
            ) == .clearAndDismiss(reportDiscard: true)
        )
    }

    /// Verifies manual lock preserves ordinary drafts but confirms dirty revealed secrets.
    @Test func manualLockPolicyDistinguishesOrdinaryAndRevealedDrafts() {
        #expect(
            SecretDraftProtectionPolicy.manualLock(
                protectsRevealedSecret: false,
                hasUnsavedChanges: true
            ) == .lockWithoutDismissal
        )
        #expect(
            SecretDraftProtectionPolicy.manualLock(
                protectsRevealedSecret: true,
                hasUnsavedChanges: false
            ) == .clearAndLock
        )
        #expect(
            SecretDraftProtectionPolicy.manualLock(
                protectsRevealedSecret: true,
                hasUnsavedChanges: true
            ) == .requestConfirmation
        )
    }
}
