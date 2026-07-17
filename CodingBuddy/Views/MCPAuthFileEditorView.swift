//
//  MCPAuthFileEditorView.swift
//  CodingBuddy
//

import Accessibility
import AppKit
import SwiftUI

/// Pure timing policy for the editor's pre-lock warning.
nonisolated enum MCPAuthRelockTiming {
    /// Lead time offered to resolve edits before cleartext is removed.
    static let warningLeadTime: TimeInterval = 30

    /// Delay from `now` until the warning should be presented.
    static func warningDelay(until deadline: Date?, now: Date) -> TimeInterval? {
        guard let deadline, deadline != .distantFuture else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(0, remaining - warningLeadTime)
    }

    /// Whether a still-valid deadline is currently inside the warning window.
    static func shouldWarn(until deadline: Date?, now: Date) -> Bool {
        guard let deadline, deadline != .distantFuture else { return false }
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0 && remaining <= warningLeadTime
    }
}

/// Generation token that prevents a completed authentication request from
/// mutating editor state after its presentation has ended or restarted.
nonisolated struct MCPAuthEditorLifecycle {
    /// Monotonic presentation generation used by in-flight requests.
    private(set) var generation = 0
    /// Whether the credential sheet currently owns visible editor state.
    private(set) var isPresented = false

    /// Starts a new presentation and returns the generation requests must retain.
    @discardableResult
    mutating func appear() -> Int {
        generation &+= 1
        isPresented = true
        return generation
    }

    /// Invalidates every request issued by the current presentation.
    mutating func disappear() {
        generation &+= 1
        isPresented = false
    }

    /// Returns whether an asynchronous result still belongs to the visible sheet.
    func accepts(_ requestGeneration: Int) -> Bool {
        isPresented && requestGeneration == generation
    }
}

/// Safety state that prevents reset-only credential artifacts from being reset blindly.
nonisolated enum MCPAuthResetSafetyBlocker: Equatable {
    /// A retained transaction must be recovered before another reset can begin.
    case recoveryRequired(URL)
    /// CodingBuddy could not enumerate the recovery area within its safety bounds.
    case recoveryDiscoveryUnavailable(URL)
    /// The current credential scan cannot prove that the reset inventory is complete.
    case incompleteInventory(URL)

    /// Resolves the most specific recovery state and its actionable filesystem location.
    static func resolve(
        recoveryDirectory: URL?,
        recoveryDiscoveryRefusedAt: URL?,
        hasIncompleteInventory: Bool,
        rootDirectory: URL
    ) -> Self? {
        if let recoveryDirectory { return .recoveryRequired(recoveryDirectory) }
        if let recoveryDiscoveryRefusedAt {
            return .recoveryDiscoveryUnavailable(recoveryDiscoveryRefusedAt)
        }
        if hasIncompleteInventory { return .incompleteInventory(rootDirectory) }
        return nil
    }
}

/// Shows the credential files of one MCP server. Token values are masked;
/// after Touch ID / password authentication the raw content becomes editable
/// (JSON files are validated before saving).
struct MCPAuthFileEditorView: View {
    /// Navigation that waits for the user to resolve unsaved edits.
    private enum PendingNavigation: Equatable {
        /// Switch to another credential artifact after resolving edits.
        case selectFile(MCPAuthFile.ID)
        /// Dismiss the credential editor after resolving edits.
        case close
    }

    /// Actionable editor failure shown inside the credential sheet.
    private struct EditorFailure {
        /// Localized alert heading.
        let title: String
        /// Localized explanation and recovery guidance.
        let message: String
        /// Whether reloading the current disk snapshot is a safe recovery.
        let canReload: Bool
        /// Retained artifact that can be revealed or copied for manual recovery.
        var recoveryArtifact: URL?
        /// Credential path that can be revealed to diagnose a load refusal.
        var affectedArtifact: URL?
    }

    /// Credential store that performs guarded file reads and writes.
    let store: MCPAuthStore
    /// Authentication gate required before unredacted content is loaded.
    var secrets: SecretsGuard
    /// Credential group whose files are available in this editor.
    let entry: MCPAuthEntry

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFileID: MCPAuthFile.ID?
    @State private var text = ""
    /// Exact descriptor-bound content required by the store on save.
    @State private var loadedContents: MCPAuthStore.LoadedContents?
    /// Whether the current authentication window permits unmasked editing.
    @State private var isEditing = false
    @State private var pendingNavigation: PendingNavigation?
    @State private var showsUnsavedConfirmation = false
    @State private var editorFailure: EditorFailure?
    @State private var showsImmediateLockPrompt = false
    @State private var isRelockWarningVisible = false
    @State private var relockScheduleID = UUID()
    @State private var lifecycle = MCPAuthEditorLifecycle()
    @State private var authenticationTask: Task<Void, Never>?
    @State private var showsResetConfirmation = false
    @State private var authenticationFailure: String?
    @FocusState private var unlockButtonFocused: Bool
    @AccessibilityFocusState private var unlockAccessibilityFocused: Bool
    @FocusState private var editorFocused: Bool
    @AccessibilityFocusState private var editorAccessibilityFocused: Bool
    @FocusState private var reauthenticateButtonFocused: Bool
    @AccessibilityFocusState private var reauthenticateAccessibilityFocused: Bool
    @FocusState private var showInFinderButtonFocused: Bool
    @AccessibilityFocusState private var showInFinderAccessibilityFocused: Bool

    /// File represented by the current picker selection.
    private var selectedFile: MCPAuthFile? {
        entry.files.first { $0.id == selectedFileID } ?? entry.files.first
    }

    /// Whether the in-memory cleartext differs from the last disk snapshot.
    private var hasUnsavedChanges: Bool {
        guard isEditing, let loadedContents else { return false }
        return text != loadedContents.text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("File", selection: selectedFileBinding) {
                    ForEach(entry.files) { file in
                        Text(verbatim: file.fileName).tag(Optional(file.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)

            Divider()

            Group {
                if isEditing {
                    TextEditor(text: $text)
                        .monospaced()
                        .focused($editorFocused)
                        .accessibilityFocused($editorAccessibilityFocused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .accessibilityLabel(
                            Text(
                                String(
                                    format: String(localized: "Unmasked credential contents for “%@”"),
                                    selectedFile?.fileName ?? ""
                                )
                            )
                        )
                        .accessibilityHint("The credential content is visible and editable until CodingBuddy locks it again.")
                } else {
                    ScrollView {
                        Text(verbatim: maskedPreview)
                            .monospaced()
                            .textSelection(.disabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let warningDeadline {
                Divider()
                relockWarning(deadline: warningDeadline)
            }

            if let authenticationFailure {
                Divider()
                authenticationFailureView(authenticationFailure)
            }

            if !isEditing,
               selectedFile?.isSafelyReadable != true,
               let resetSafetyBlocker {
                Divider()
                resetSafetyBlockerView(resetSafetyBlocker)
            }

            Divider()

            HStack {
                if !isEditing {
                    if selectedFile?.isSafelyReadable == true {
                        Button("Unlock to view and edit", systemImage: "lock") { unlock() }
                            .focused($unlockButtonFocused)
                            .accessibilityFocused($unlockAccessibilityFocused)
                            .keyboardShortcut(.defaultAction)
                        Text("Token values are masked until you authenticate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Reset only", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("This artifact is reset-only because CodingBuddy cannot read it safely.")
                        Button("Show in Finder", systemImage: "folder") {
                            showSelectedFileInFinder()
                        }
                        .focused($showInFinderButtonFocused)
                        .accessibilityFocused($showInFinderAccessibilityFocused)
                        if resetSafetyBlocker == nil {
                            Button("Reset Entry…", systemImage: "trash", role: .destructive) {
                                showsResetConfirmation = true
                            }
                        }
                    }
                }
                Spacer()
                Button("Close", role: .cancel) { requestClose() }
                    .keyboardShortcut(.cancelAction)
                if isEditing {
                    Button(String(localized: "Lock All Revealed Secrets"), systemImage: "lock.fill") {
                        requestImmediateLock()
                    }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFile == nil || loadedContents == nil)
                }
            }
            .padding(12)
        }
        .frame(width: 600, height: 460)
        .onAppear {
            lifecycle.appear()
            selectedFileID = entry.files.first?.id
            focusLockedStateControl()
        }
        .onChange(of: secrets.isUnlocked) {
            if !secrets.isUnlocked { handleRelock() }
        }
        .onChange(of: secrets.unlockedUntil) {
            isRelockWarningVisible = false
            relockScheduleID = UUID()
        }
        .onDisappear {
            invalidatePresentation()
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .presentationPreventsAppTermination(hasUnsavedChanges)
        .focusedValue(\.mcpAuthCommandActions, editorCommandActions)
        .focusedValue(\.secretLockCommandAction, requestImmediateLock)
        .task(id: relockScheduleID) {
            await scheduleRelockWarning()
        }
        .confirmationDialog(
            "Save changes before continuing?",
            isPresented: $showsUnsavedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save and Continue") {
                if save() { performPendingNavigation() }
            }
            Button("Discard Changes", role: .destructive) {
                performPendingNavigation()
            }
            Button("Cancel", role: .cancel) {
                pendingNavigation = nil
            }
        } message: {
            Text("This credential file contains unsaved changes.")
        }
        .confirmationDialog(
            String(localized: "Lock All Revealed Secrets?"),
            isPresented: $showsImmediateLockPrompt,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Save and Lock")) { saveAndLock() }
            Button(String(localized: "Discard and Lock"), role: .destructive) {
                discardAndLock()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "This credential file contains unsaved changes. Save or discard them before locking all revealed secrets."))
        }
        .confirmationDialog(
            "Move credentials for “\(entry.displayName)” to the Trash?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move Server Credentials to Trash", role: .destructive) {
                resetEntry()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will trigger a fresh OAuth login.")
        }
        .alert(
            editorFailure?.title ?? "",
            isPresented: Binding(
                get: { editorFailure != nil },
                set: { if !$0 { editorFailure = nil } }
            )
        ) {
            if editorFailure?.canReload == true {
                Button("Reload from Disk") {
                    editorFailure = nil
                    loadSelectedFile()
                }
            }
            if let recoveryArtifact = editorFailure?.recoveryArtifact {
                Button("Show Recovery Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recoveryArtifact])
                    editorFailure = nil
                }
                Button("Copy Recovery Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryArtifact.path, forType: .string)
                    editorFailure = nil
                }
            }
            if let affectedArtifact = editorFailure?.affectedArtifact {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([affectedArtifact])
                    editorFailure = nil
                }
            }
            Button("OK", role: .cancel) {
                editorFailure = nil
            }
        } message: {
            Text(editorFailure?.message ?? "")
        }
    }

    /// Picker binding that defers navigation until dirty edits are resolved.
    private var selectedFileBinding: Binding<MCPAuthFile.ID?> {
        Binding(
            get: { selectedFileID },
            set: { requestedID in
                guard requestedID != selectedFileID else { return }
                guard let requestedID else { return }
                if hasUnsavedChanges {
                    pendingNavigation = .selectFile(requestedID)
                    showsUnsavedConfirmation = true
                } else {
                    selectFile(requestedID)
                }
            }
        )
    }

    /// Overrides scene-level credential commands while this modal editor owns focus.
    /// Manual locking must pass through the editor's dirty-state confirmation;
    /// automatic expiry still revokes the shared reveal window immediately.
    private var editorCommandActions: MCPAuthCommandActions {
        MCPAuthCommandActions(
            viewSelectedFiles: nil,
            showRecoveryFiles: nil,
            resetAllCredentials: nil
        )
    }

    /// Redacted representation used before authentication and after relock.
    private var maskedPreview: String {
        guard let file = selectedFile else { return "" }
        return file.isSafelyReadable
            ? "••••••••"
            : String(localized: "This artifact is reset-only because CodingBuddy cannot read it safely.")
    }

    /// Authenticates, loads the selected file and enters cleartext editing.
    private func unlock() {
        guard selectedFile?.isSafelyReadable == true else { return }
        authenticationTask?.cancel()
        let requestGeneration = lifecycle.generation
        authenticationTask = Task { @MainActor in
            let didUnlock = await secrets.requestUnlock()
            guard !Task.isCancelled,
                  lifecycle.accepts(requestGeneration) else { return }
            let presentation = SecretAuthenticationPresentation.resolve(
                didUnlock: didUnlock,
                errorMessage: secrets.lastError
            )
            secrets.clearError()
            guard presentation == .succeeded else {
                authenticationTask = nil
                handleAuthenticationFailure(presentation, focus: .unlock)
                return
            }
            authenticationFailure = nil
            isRelockWarningVisible = false
            guard loadSelectedFile() else {
                authenticationTask = nil
                focusUnlockControl()
                return
            }
            isEditing = true
            unlockButtonFocused = false
            unlockAccessibilityFocused = false
            focusEditorControl()
            relockScheduleID = UUID()
            authenticationTask = nil
        }
    }

    /// Replaces the editor buffer with the selected file's current contents.
    @discardableResult
    private func loadSelectedFile() -> Bool {
        guard let file = selectedFile else { return false }
        do {
            let loaded = try store.loadContents(of: file)
            text = loaded.text
            loadedContents = loaded
            return true
        } catch {
            clearSensitiveBuffer()
            focusUnlockControl()
            editorFailure = EditorFailure(
                title: String(localized: "Credential File Could Not Be Loaded"),
                message: store.userFacingMessage(for: error),
                canReload: true,
                recoveryArtifact: nil,
                affectedArtifact: file.url
            )
            return false
        }
    }

    /// Saves against the loaded snapshot and keeps failures inside the sheet.
    @discardableResult
    private func save() -> Bool {
        guard let file = selectedFile, let loadedContents else { return false }
        if store.save(text, to: file, loaded: loadedContents) {
            return loadSelectedFile()
        }
        let isStale = store.lastFailureKind == .fileChangedExternally
        let recoveryArtifact: URL? = if case let .writeRecovery(url) = store.lastFailureKind {
            url
        } else {
            nil
        }
        editorFailure = EditorFailure(
            title: isStale
                ? String(localized: "Credential File Changed")
                : String(localized: "Credential File Could Not Be Saved"),
            message: store.lastError
                ?? String(localized: "CodingBuddy could not save this credential file. No changes were written."),
            canReload: isStale,
            recoveryArtifact: recoveryArtifact,
            affectedArtifact: nil
        )
        store.clearError()
        return false
    }

    /// Closes immediately or asks how to resolve dirty edits first.
    private func requestClose() {
        if hasUnsavedChanges {
            pendingNavigation = .close
            showsUnsavedConfirmation = true
        } else {
            invalidatePresentation()
            dismiss()
        }
    }

    /// Performs the deferred file switch or close after save/discard.
    private func performPendingNavigation() {
        let navigation = pendingNavigation
        pendingNavigation = nil
        showsUnsavedConfirmation = false
        switch navigation {
        case let .selectFile(fileID):
            selectFile(fileID)
        case .close:
            invalidatePresentation()
            dismiss()
        case nil:
            break
        }
    }

    /// Selects and, while unlocked, loads a credential file.
    private func selectFile(_ fileID: MCPAuthFile.ID) {
        selectedFileID = fileID
        if isEditing {
            loadSelectedFile()
        } else {
            focusLockedStateControl()
        }
    }

    /// Removes cleartext immediately when the shared authentication window ends.
    private func handleRelock() {
        guard isEditing else { return }
        let discardedChanges = hasUnsavedChanges
        showsImmediateLockPrompt = false
        isRelockWarningVisible = false
        authenticationFailure = nil
        clearSensitiveBuffer()
        focusUnlockControl()
        AccessibilityNotification.Announcement(
            String(localized: "Credential contents were locked and cleared.")
        ).post()
        if discardedChanges {
            editorFailure = EditorFailure(
                title: String(localized: "Credential Editor Locked"),
                message: String(localized: "The unlock period ended. CodingBuddy discarded the unsaved cleartext changes to protect your credentials."),
                canReload: false,
                recoveryArtifact: nil,
                affectedArtifact: nil
            )
        }
    }

    /// Clears all unmasked content retained by this view.
    private func clearSensitiveBuffer() {
        text = ""
        loadedContents = nil
        isEditing = false
        editorFocused = false
        editorAccessibilityFocused = false
    }

    /// Requests an immediate lock without silently discarding dirty content.
    private func requestImmediateLock() {
        if hasUnsavedChanges {
            showsImmediateLockPrompt = true
        } else {
            discardAndLock()
        }
    }

    /// Saves the current snapshot, then revokes authentication and cleartext.
    private func saveAndLock() {
        guard !hasUnsavedChanges || save() else { return }
        discardAndLock()
    }

    /// Clears cleartext first, then revokes the shared reveal window.
    private func discardAndLock() {
        showsImmediateLockPrompt = false
        isRelockWarningVisible = false
        clearSensitiveBuffer()
        secrets.lock()
        focusUnlockControl()
    }

    /// Extends the authentication window without replacing the editor buffer.
    private func reauthenticate() {
        authenticationTask?.cancel()
        let requestGeneration = lifecycle.generation
        authenticationTask = Task { @MainActor in
            let didUnlock = await secrets.requestUnlock()
            guard !Task.isCancelled,
                  lifecycle.accepts(requestGeneration) else { return }
            let presentation = SecretAuthenticationPresentation.resolve(
                didUnlock: didUnlock,
                errorMessage: secrets.lastError
            )
            secrets.clearError()
            guard presentation == .succeeded else {
                authenticationTask = nil
                handleAuthenticationFailure(presentation, focus: .reauthenticate)
                return
            }
            authenticationFailure = nil
            isRelockWarningVisible = false
            relockScheduleID = UUID()
            authenticationTask = nil
        }
    }

    /// Reveals the reset-only artifact without attempting to read its contents.
    private func showSelectedFileInFinder() {
        guard let file = selectedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Executes the already-confirmed reversible reset and keeps failures actionable.
    private func resetEntry() {
        showsResetConfirmation = false
        if store.reset(entry) {
            invalidatePresentation()
            dismiss()
            return
        }
        editorFailure = EditorFailure(
            title: store.lastRecoveryDirectory == nil
                ? String(localized: "Credential Operation Failed")
                : String(localized: "Credential Recovery Required"),
            message: store.lastError
                ?? String(localized: "CodingBuddy could not complete the credential operation. No unconfirmed changes were written."),
            canReload: false,
            recoveryArtifact: store.lastRecoveryDirectory,
            affectedArtifact: nil
        )
        store.clearError()
    }

    /// Most specific reason reset is blocked, including a safe recovery location.
    private var resetSafetyBlocker: MCPAuthResetSafetyBlocker? {
        MCPAuthResetSafetyBlocker.resolve(
            recoveryDirectory: store.lastRecoveryDirectory,
            recoveryDiscoveryRefusedAt: store.recoveryDiscoveryRefusedAt,
            hasIncompleteInventory: store.hasIncompleteCredentialInventory,
            rootDirectory: store.rootDirectory
        )
    }

    /// Invalidates asynchronous results before cleartext is removed or dismissal begins.
    private func invalidatePresentation() {
        authenticationTask?.cancel()
        authenticationTask = nil
        lifecycle.disappear()
        clearSensitiveBuffer()
    }

    /// Sleeps until the current finite reveal window reaches 30 seconds.
    private func scheduleRelockWarning() async {
        guard isEditing,
              let delay = MCPAuthRelockTiming.warningDelay(
                until: secrets.unlockedUntil,
                now: Date()
              ) else { return }
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard !Task.isCancelled,
              isEditing,
              secrets.isUnlocked,
              MCPAuthRelockTiming.shouldWarn(
                until: secrets.unlockedUntil,
                now: Date()
              ) else { return }
        isRelockWarningVisible = true
        let remainingSeconds = Int64(
            max(1, ceil((secrets.unlockedUntil ?? Date()).timeIntervalSinceNow))
        )
        AccessibilityNotification.Announcement(
            String(
                format: String(localized: "CodingBuddy will lock all revealed secrets in %lld seconds."),
                locale: Locale.current,
                remainingSeconds
            )
        ).post()
    }

    /// Finite deadline shown by the persistent pre-lock warning.
    private var warningDeadline: Date? {
        guard isRelockWarningVisible,
              isEditing,
              secrets.isUnlocked,
              let deadline = secrets.unlockedUntil,
              deadline != .distantFuture else { return nil }
        return deadline
    }

    /// Persistent countdown and resolution actions for the active reveal window.
    private func relockWarning(deadline: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(
                        String(localized: "CodingBuddy will lock all revealed secrets soon."),
                        systemImage: "clock.badge.exclamationmark"
                    )
                    Spacer()
                    Text(String(localized: "Automatic lock in"))
                        .foregroundStyle(.secondary)
                    if deadline > context.date {
                        Text(
                            timerInterval: context.date...deadline,
                            countsDown: true,
                            showsHours: false
                        )
                        .monospacedDigit()
                    } else {
                        Text("Locking…")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer()
                        relockActionButtons
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        relockActionButtons
                    }
                }
            }
            .padding(12)
            .background(.quaternary)
            .accessibilityElement(children: .contain)
        }
    }

    /// Actions shared by horizontal and compact vertical countdown layouts.
    @ViewBuilder
    private var relockActionButtons: some View {
        Button(String(localized: "Save and Lock")) { saveAndLock() }
        Button(String(localized: "Reauthenticate")) { reauthenticate() }
            .focused($reauthenticateButtonFocused)
            .accessibilityFocused($reauthenticateAccessibilityFocused)
        Button(String(localized: "Discard and Lock"), role: .destructive) {
            discardAndLock()
        }
    }

    /// Persistent sanitized authentication feedback with a single focusable recovery action.
    private func authenticationFailureView(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.red.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    /// Explains why reset is unavailable and exposes safe recovery actions.
    private func resetSafetyBlockerView(_ blocker: MCPAuthResetSafetyBlocker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(resetSafetyTitle(for: blocker), systemImage: "exclamationmark.shield.fill")
                .font(.headline)
            Text(resetSafetyMessage(for: blocker))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { resetSafetyActions(for: blocker) }
                VStack(alignment: .leading, spacing: 8) { resetSafetyActions(for: blocker) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    /// Localized heading for a blocked reset state.
    private func resetSafetyTitle(for blocker: MCPAuthResetSafetyBlocker) -> String {
        switch blocker {
        case .recoveryRequired:
            String(localized: "Credential Recovery Required")
        case .recoveryDiscoveryUnavailable, .incompleteInventory:
            String(localized: "Credential Scan Limited for Safety")
        }
    }

    /// Localized explanation for a blocked reset state.
    private func resetSafetyMessage(for blocker: MCPAuthResetSafetyBlocker) -> String {
        switch blocker {
        case .recoveryRequired:
            String(localized: "Resolve the retained recovery files before resetting more credentials")
        case .recoveryDiscoveryUnavailable, .incompleteInventory:
            String(localized: "CodingBuddy did not reset credentials because the cache or recovery area could not be enumerated safely. Review it in Finder and try again.")
        }
    }

    /// Retry plus the filesystem action relevant to the current blocker.
    @ViewBuilder
    private func resetSafetyActions(for blocker: MCPAuthResetSafetyBlocker) -> some View {
        Button(String(localized: "Retry"), systemImage: "arrow.clockwise") {
            store.reload()
        }
        switch blocker {
        case .recoveryRequired(let directory):
            Button(String(localized: "Show Recovery Files in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
            Button(String(localized: "Copy Recovery Path"), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory.path, forType: .string)
            }
        case .recoveryDiscoveryUnavailable(let directory), .incompleteInventory(let directory):
            Button(String(localized: "Show in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }
    }

    /// Focus target selected after a genuine authentication failure.
    private enum AuthenticationFailureFocus {
        /// Return focus to the initial secret-unlock action.
        case unlock
        /// Return focus to the pre-expiry reauthentication action.
        case reauthenticate
    }

    /// Keeps genuine failures visible and announces only the sanitized app message.
    private func handleAuthenticationFailure(
        _ presentation: SecretAuthenticationPresentation,
        focus: AuthenticationFailureFocus
    ) {
        guard case .visibleFailure(let message) = presentation else { return }
        authenticationFailure = message
        AccessibilityNotification.Announcement(message).post()
        switch focus {
        case .unlock:
            focusUnlockControl()
        case .reauthenticate:
            focusReauthenticateControl()
        }
    }

    /// Moves keyboard and VoiceOver focus to the safe locked-state action.
    private func focusUnlockControl() {
        Task { @MainActor in
            await Task.yield()
            guard !isEditing, selectedFile?.isSafelyReadable == true else { return }
            unlockButtonFocused = true
            unlockAccessibilityFocused = true
        }
    }

    /// Moves focus to the locked-state action that is actually rendered for the selected file.
    private func focusLockedStateControl() {
        Task { @MainActor in
            await Task.yield()
            guard !isEditing else { return }
            if selectedFile?.isSafelyReadable == true {
                unlockButtonFocused = true
                unlockAccessibilityFocused = true
            } else {
                showInFinderButtonFocused = true
                showInFinderAccessibilityFocused = true
            }
        }
    }

    /// Returns keyboard and VoiceOver focus to reauthentication after a failed attempt.
    private func focusReauthenticateControl() {
        Task { @MainActor in
            await Task.yield()
            guard isEditing, warningDeadline != nil, authenticationFailure != nil else { return }
            reauthenticateButtonFocused = true
            reauthenticateAccessibilityFocused = true
        }
    }

    /// Moves keyboard and VoiceOver focus to the editor after cleartext loaded successfully.
    private func focusEditorControl() {
        Task { @MainActor in
            await Task.yield()
            guard isEditing else { return }
            editorFocused = true
            editorAccessibilityFocused = true
        }
    }
}
