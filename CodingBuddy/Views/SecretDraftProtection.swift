//
//  SecretDraftProtection.swift
//  CodingBuddy
//

import Accessibility
import SwiftUI

/// Pure timing policy for pre-expiry warnings in protected variable editors.
nonisolated enum SecretDraftRelockTiming {
    /// Lead time offered to save, reauthenticate, or discard a dirty secret draft.
    static let warningLeadTime: TimeInterval = 30

    /// Delay until a finite reveal window enters the warning interval.
    static func warningDelay(until deadline: Date?, now: Date) -> TimeInterval? {
        guard let deadline, deadline != .distantFuture else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(0, remaining - warningLeadTime)
    }
}

/// Outcome applied when the shared secret session expires around an editor draft.
nonisolated enum SecretDraftAutomaticRelockDecision: Equatable {
    /// The editor does not own revealed store cleartext and remains untouched.
    case preserveDraft
    /// Revealed cleartext must be removed; dirty drafts additionally surface a notice.
    case clearAndDismiss(reportDiscard: Bool)
}

/// Outcome applied when the focused editor receives the app-wide manual lock command.
nonisolated enum SecretDraftManualLockDecision: Equatable {
    /// Lock shared secrets while preserving a non-sensitive editor draft.
    case lockWithoutDismissal
    /// Remove a clean revealed-secret draft and lock immediately.
    case clearAndLock
    /// Ask whether to save or discard a dirty revealed-secret draft.
    case requestConfirmation
}

/// Presentation outcome after a secret authentication request completes.
nonisolated enum SecretAuthenticationPresentation: Equatable {
    /// Authentication succeeded and the caller may continue its protected action.
    case succeeded
    /// User, lifecycle, or task cancellation intentionally produces no app feedback.
    case silentFailure
    /// A sanitized recoverable failure must remain visible beside the protected action.
    case visibleFailure(String)

    /// Separates a genuine authentication failure from success and silent cancellation.
    static func resolve(didUnlock: Bool, errorMessage: String?) -> Self {
        if didUnlock { return .succeeded }
        guard let errorMessage, !errorMessage.isEmpty else { return .silentFailure }
        return .visibleFailure(errorMessage)
    }
}

/// Pure policy separating secret ownership from SwiftUI presentation behavior.
nonisolated enum SecretDraftProtectionPolicy {
    /// Determines whether the current draft owns cleartext that must be cleared on lock.
    static func protectsDraft(
        protectsRevealedSecret: Bool,
        currentName: String,
        protectionEnabled: Bool
    ) -> Bool {
        protectsRevealedSecret
            || (protectionEnabled && SecretDetector.isSensitive(name: currentName))
    }

    /// Decides how an editor responds to an automatic unlocked-to-locked transition.
    static func automaticRelock(
        protectsRevealedSecret: Bool,
        hasUnsavedChanges: Bool
    ) -> SecretDraftAutomaticRelockDecision {
        guard protectsRevealedSecret else { return .preserveDraft }
        return .clearAndDismiss(reportDiscard: hasUnsavedChanges)
    }

    /// Decides how an editor responds to the explicit app-wide lock command.
    static func manualLock(
        protectsRevealedSecret: Bool,
        hasUnsavedChanges: Bool
    ) -> SecretDraftManualLockDecision {
        guard protectsRevealedSecret else { return .lockWithoutDismissal }
        return hasUnsavedChanges ? .requestConfirmation : .clearAndLock
    }
}

/// Coordinates app-wide secret locking with a focused editor that temporarily
/// owns cleartext outside its backing store.
private struct SecretDraftProtectionModifier: ViewModifier {
    /// Shared authentication state whose expiry must clear this draft.
    let secrets: SecretsGuard
    /// Whether this editor received sensitive cleartext from a protected backing store.
    let protectsRevealedSecret: Bool
    /// Whether dismissing the draft would lose user changes.
    let hasUnsavedChanges: Bool
    /// Whether the current draft passes the editor's normal save validation.
    let canSave: Bool
    /// Persists the validated draft and dismisses its editor only on success.
    let saveAndDismiss: () -> Bool
    /// Clears sensitive state and dismisses the editor.
    let clearAndDismiss: () -> Void
    /// Surfaces an automatic-expiry discard after the sheet is gone.
    let reportAutomaticDiscard: () -> Void

    @State private var showsImmediateLockPrompt = false
    @State private var isRelockWarningVisible = false
    @State private var relockScheduleID = UUID()
    @State private var authenticationFailure: String?
    @FocusState private var reauthenticateFocused: Bool
    @AccessibilityFocusState private var reauthenticateAccessibilityFocused: Bool

    /// Adds focused-command handling, automatic expiry, and dirty-state choice.
    func body(content: Content) -> some View {
        content
            .focusedValue(\.secretLockCommandAction, requestImmediateLock)
            .onChange(of: secrets.isUnlocked) { wasUnlocked, isUnlocked in
                if isUnlocked {
                    isRelockWarningVisible = false
                    authenticationFailure = nil
                    relockScheduleID = UUID()
                }
                guard wasUnlocked, !isUnlocked else { return }
                switch SecretDraftProtectionPolicy.automaticRelock(
                    protectsRevealedSecret: protectsRevealedSecret,
                    hasUnsavedChanges: hasUnsavedChanges
                ) {
                case .preserveDraft:
                    break
                case .clearAndDismiss(let reportDiscard):
                    clearAndDismiss()
                    if reportDiscard { reportAutomaticDiscard() }
                }
            }
            .onChange(of: secrets.unlockedUntil) {
                isRelockWarningVisible = false
                relockScheduleID = UUID()
            }
            .onChange(of: hasUnsavedChanges) {
                relockScheduleID = UUID()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let warningDeadline {
                    relockWarning(deadline: warningDeadline)
                }
            }
            .task(id: relockScheduleID) {
                await scheduleRelockWarning()
            }
            .confirmationDialog(
                String(localized: "Lock All Revealed Secrets?"),
                isPresented: $showsImmediateLockPrompt,
                titleVisibility: .visible
            ) {
                if canSave {
                    Button(String(localized: "Save and Lock")) {
                        if saveAndDismiss() { secrets.lock() }
                    }
                }
                Button(String(localized: "Discard and Lock"), role: .destructive) {
                    clearAndDismiss()
                    secrets.lock()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(localized: "This editor contains unsaved cleartext. Save or discard it before locking all revealed secrets."))
            }
    }

    /// Locks immediately for a clean draft and asks before discarding a dirty one.
    private func requestImmediateLock() {
        switch SecretDraftProtectionPolicy.manualLock(
            protectsRevealedSecret: protectsRevealedSecret,
            hasUnsavedChanges: hasUnsavedChanges
        ) {
        case .lockWithoutDismissal:
            secrets.lock()
        case .clearAndLock:
            clearAndDismiss()
            secrets.lock()
        case .requestConfirmation:
            showsImmediateLockPrompt = true
        }
    }

    /// Finite unlock deadline shown only for a dirty revealed-secret draft.
    private var warningDeadline: Date? {
        guard isRelockWarningVisible,
              protectsRevealedSecret,
              hasUnsavedChanges,
              secrets.isUnlocked,
              let deadline = secrets.unlockedUntil,
              deadline != .distantFuture else { return nil }
        return deadline
    }

    /// Waits until the shared reveal window enters its final 30 seconds.
    private func scheduleRelockWarning() async {
        guard protectsRevealedSecret,
              hasUnsavedChanges,
              let deadline = secrets.unlockedUntil,
              let delay = SecretDraftRelockTiming.warningDelay(until: deadline, now: Date()) else { return }
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard !Task.isCancelled,
              secrets.isUnlocked,
              secrets.unlockedUntil == deadline,
              hasUnsavedChanges,
              deadline.timeIntervalSinceNow > 0 else { return }
        isRelockWarningVisible = true
        let remainingSeconds = Int64(max(1, ceil(deadline.timeIntervalSinceNow)))
        AccessibilityNotification.Announcement(
            String(
                format: String(localized: "CodingBuddy will lock all revealed secrets in %lld seconds."),
                locale: Locale.current,
                remainingSeconds
            )
        ).post()
    }

    /// Persistent pre-expiry actions that avoid silent draft loss.
    private func relockWarning(deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        relockWarningLabel(deadline: deadline, now: context.date)
                        Spacer()
                        relockWarningActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        relockWarningLabel(deadline: deadline, now: context.date)
                        relockWarningActions
                    }
                }
                if let authenticationFailure {
                    Label(authenticationFailure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.orange.opacity(0.10))
            .accessibilityElement(children: .contain)
        }
    }

    /// Countdown label shared by compact and wide warning layouts.
    private func relockWarningLabel(deadline: Date, now: Date) -> some View {
        HStack(spacing: 8) {
            Label(
                String(localized: "CodingBuddy will lock all revealed secrets soon."),
                systemImage: "clock.badge.exclamationmark"
            )
            if deadline > now {
                Text(timerInterval: now...deadline, countsDown: true, showsHours: false)
                    .monospacedDigit()
            }
        }
    }

    /// Save, reauthentication, and discard routes offered before expiry.
    @ViewBuilder
    private var relockWarningActions: some View {
        if canSave {
            Button(String(localized: "Save and Lock")) {
                if saveAndDismiss() { secrets.lock() }
            }
        }
        Button(String(localized: "Reauthenticate")) {
            requestReauthentication()
        }
        .focused($reauthenticateFocused)
        .accessibilityFocused($reauthenticateAccessibilityFocused)
        Button(String(localized: "Discard and Lock"), role: .destructive) {
            clearAndDismiss()
            secrets.lock()
        }
    }

    /// Reauthenticates without dismissing or replacing the editor's current draft.
    private func requestReauthentication() {
        Task { @MainActor in
            let didUnlock = await secrets.requestUnlock()
            let presentation = SecretAuthenticationPresentation.resolve(
                didUnlock: didUnlock,
                errorMessage: secrets.lastError
            )
            secrets.clearError()
            switch presentation {
            case .succeeded:
                authenticationFailure = nil
                isRelockWarningVisible = false
                relockScheduleID = UUID()
            case .silentFailure:
                break
            case .visibleFailure(let message):
                authenticationFailure = message
                AccessibilityNotification.Announcement(message).post()
                focusReauthenticateControl()
            }
        }
    }

    /// Returns keyboard and VoiceOver focus to the failed recovery action.
    private func focusReauthenticateControl() {
        Task { @MainActor in
            await Task.yield()
            guard warningDeadline != nil else { return }
            reauthenticateFocused = true
            reauthenticateAccessibilityFocused = true
        }
    }
}

extension View {
    /// Protects a cleartext draft from surviving manual or automatic relocking.
    func protectsSecretDraft(
        secrets: SecretsGuard,
        protectsRevealedSecret: Bool,
        currentName: String,
        hasUnsavedChanges: Bool,
        canSave: Bool,
        saveAndDismiss: @escaping () -> Bool,
        clearAndDismiss: @escaping () -> Void,
        reportAutomaticDiscard: @escaping () -> Void
    ) -> some View {
        modifier(
            SecretDraftProtectionModifier(
                secrets: secrets,
                protectsRevealedSecret: SecretDraftProtectionPolicy.protectsDraft(
                    protectsRevealedSecret: protectsRevealedSecret,
                    currentName: currentName,
                    protectionEnabled: FeatureFlag.secretsProtection.isEnabled
                ),
                hasUnsavedChanges: hasUnsavedChanges,
                canSave: canSave,
                saveAndDismiss: saveAndDismiss,
                clearAndDismiss: clearAndDismiss,
                reportAutomaticDiscard: reportAutomaticDiscard
            )
        )
    }
}
