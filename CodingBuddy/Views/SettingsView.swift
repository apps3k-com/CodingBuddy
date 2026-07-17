//
//  SettingsView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pane that Settings should show when first presented.
nonisolated enum SettingsInitialPane: Hashable {
    /// General app preferences.
    case general
    /// Security and authorization preferences.
    case security
    /// Package-manager executable selection.
    case maintenance
}

/// Presented as a sheet over the main window — window-modal on purpose, so
/// it neither spawns a second window nor leaves the app interactive behind it.
struct SettingsView: View {
    /// Settings sections exposed by the sheet's segmented control.
    private enum Pane: Hashable {
        /// General app behavior, language, appearance, and editor settings.
        case general
        /// Security-sensitive credentials and unlock timing settings.
        case security
        /// Package-manager command paths.
        case maintenance
    }

    /// Credential source requested after an explicit cross-source confirmation.
    private enum GitHubCredentialDestination {
        /// Rotating GitHub App user credential with Review Desk write capability.
        case githubApp
        /// User-managed fine-grained token restricted to read-only app behavior.
        case readOnlyToken
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(DefaultTextEditorPreference.bundleIdentifierKey) private var editorBundleIdentifier = ""
    @AppStorage(DefaultTextEditorPreference.applicationPathKey) private var editorApplicationPath = ""
    @AppStorage(DefaultTextEditorPreference.displayNameKey) private var editorDisplayName = ""
    @AppStorage(SecretsGuard.unlockDurationKey) private var unlockDuration = SecretsGuard.defaultUnlockDuration
    @AppStorage(PackageExecutablePreference.key(for: .homebrew)) private var homebrewExecutablePath = ""
    @AppStorage(PackageExecutablePreference.key(for: .npm)) private var npmExecutablePath = ""
    @AppStorage(PackageExecutablePreference.key(for: .pnpm)) private var pnpmExecutablePath = ""
    /// GitHub authorization state shared with Agent PR Monitor.
    var githubAuthorizationStore: GitHubAuthorizationStore
    /// Called after Settings saves or removes GitHub authorization.
    var onGitHubAuthorizationChange: (GitHubAuthorizationChange) -> Void
    /// Whether the GitHub token replacement sheet is visible.
    @State private var showsGitHubTokenSheet = false
    /// Whether GitHub App device-flow setup is visible.
    @State private var showsGitHubAppSignInSheet = false
    /// Whether the GitHub token removal confirmation is visible.
    @State private var showsRemoveGitHubTokenConfirmation = false
    /// Cross-source transition awaiting an explicit capability warning.
    @State private var pendingCredentialDestination: GitHubCredentialDestination?

    /// Creates the settings sheet with an optional initial pane.
    init(
        githubAuthorizationStore: GitHubAuthorizationStore = GitHubAuthorizationStore(),
        initialPane: SettingsInitialPane = .general,
        onGitHubAuthorizationChange: @escaping (GitHubAuthorizationChange) -> Void = { _ in }
    ) {
        self.githubAuthorizationStore = githubAuthorizationStore
        self.onGitHubAuthorizationChange = onGitHubAuthorizationChange
        switch initialPane {
        case .general: _pane = State(initialValue: .general)
        case .security: _pane = State(initialValue: .security)
        case .maintenance: _pane = State(initialValue: .maintenance)
        }
    }

    /// Segmented settings sheet content.
    var body: some View {
        // No TabView here: inside a sheet it draws its own bordered box,
        // which clashes with the grouped form and the sheet background.
        VStack(spacing: 0) {
            Picker(selection: $pane) {
                Text("General").tag(Pane.general)
                Text("Security").tag(Pane.security)
                if FeatureFlag.packageMaintenance.isEnabled {
                    Text("Maintenance").tag(Pane.maintenance)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)

            Group {
                switch pane {
                case .general: generalPane
                case .security: securityPane
                case .maintenance: maintenancePane
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 540, height: 460)
    }

    /// Explicit executable overrides for package managers that are not auto-detected.
    private var maintenancePane: some View {
        Form {
            Section {
                ForEach(PackageManagerKind.allCases, id: \.self) { manager in
                    PackageExecutableSettingsRow(
                        manager: manager,
                        path: packageExecutablePath(for: manager)
                    ) {
                        choosePackageExecutable(manager: manager, path: packageExecutablePath(for: manager))
                    }
                        .id(manager)
                }
            } header: {
                Text("Package manager executables")
            } footer: {
                Text("Leave a path empty to use automatic discovery. CodingBuddy never starts a login shell or requests administrator privileges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Binding for the explicit executable override of one manager.
    private func packageExecutablePath(for manager: PackageManagerKind) -> Binding<String> {
        switch manager {
        case .homebrew: $homebrewExecutablePath
        case .npm: $npmExecutablePath
        case .pnpm: $pnpmExecutablePath
        }
    }

    /// Selects one executable file without invoking or validating it in Settings.
    private func choosePackageExecutable(manager: PackageManagerKind, path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(
            format: String(localized: "Choose the %@ executable."),
            manager.displayName
        )
        panel.prompt = String(localized: "Choose Executable")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path.wrappedValue = url.path
    }

    /// Security-related settings, including GitHub authorization.
    private var securityPane: some View {
        Form {
            if FeatureFlag.agentPRMonitor.isEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        githubAuthorizationStatusLabel
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                githubAuthorizationButtons
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                githubAuthorizationButtons
                            }
                        }
                    }
                } header: {
                    Text("GitHub authorization")
                } footer: {
                    Text("GitHub App sign-in enables Review Desk actions. A fine-grained token remains available for read-only monitoring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Keep secrets revealed for", selection: $unlockDuration) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("Until CodingBuddy quits").tag(-1.0)
                }
            } footer: {
                Text("Values that look like secrets (TOKEN, KEY, PASSWORD, …) are masked until you authenticate with Touch ID or your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            githubAuthorizationStore.reload()
        }
        .sheet(isPresented: $showsGitHubTokenSheet) {
            GitHubTokenSettingsSheet(store: githubAuthorizationStore) {
                onGitHubAuthorizationChange(.saved)
            }
        }
        .sheet(isPresented: $showsGitHubAppSignInSheet) {
            GitHubAppSignInSheet(store: githubAuthorizationStore) {
                onGitHubAuthorizationChange(.saved)
            }
        }
        .confirmationDialog(removeCredentialTitle, isPresented: $showsRemoveGitHubTokenConfirmation) {
            Button(role: .destructive) {
                Task {
                    if await githubAuthorizationStore.deleteToken() {
                        onGitHubAuthorizationChange(.removed)
                    }
                }
            } label: {
                Text(verbatim: removeCredentialButtonTitle)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: removeCredentialMessage)
        }
        .confirmationDialog(
            credentialSwitchTitle,
            isPresented: Binding(
                get: { pendingCredentialDestination != nil },
                set: { if !$0 { pendingCredentialDestination = nil } }
            )
        ) {
            Button(credentialSwitchButtonTitle) { confirmCredentialSwitch() }
            Button("Cancel", role: .cancel) { pendingCredentialDestination = nil }
        } message: {
            Text(verbatim: credentialSwitchMessage)
        }
    }

    /// Authorization commands arranged by the parent layout without duplicating behavior.
    @ViewBuilder private var githubAuthorizationButtons: some View {
        Button(githubAppButtonTitle) {
            requestCredentialDestination(.githubApp)
        }
        .buttonStyle(.borderedProminent)
        Button(readOnlyTokenButtonTitle) {
            requestCredentialDestination(.readOnlyToken)
        }
        Button(removeCredentialCommandTitle, role: .destructive) {
            showsRemoveGitHubTokenConfirmation = true
        }
        .disabled(!githubAuthorizationStore.hasSavedToken)
    }

    /// Source-aware label for connecting, switching, or reconnecting the GitHub App.
    private var githubAppButtonTitle: String {
        switch githubAuthorizationStore.credentialSource {
        case .githubAppDeviceFlow: String(localized: "Reconnect GitHub App...")
        case .fineGrainedPersonalAccessToken: String(localized: "Switch to GitHub App...")
        case nil: String(localized: "Sign in with GitHub...")
        }
    }

    /// Source-aware label for adding, replacing, or switching to a read-only token.
    private var readOnlyTokenButtonTitle: String {
        switch githubAuthorizationStore.credentialSource {
        case .githubAppDeviceFlow: String(localized: "Switch to Read-only Token...")
        case .fineGrainedPersonalAccessToken: String(localized: "Replace Read-only Token...")
        case nil: String(localized: "Add Read-only Token...")
        }
    }

    /// Source-aware destructive command label.
    private var removeCredentialCommandTitle: String {
        githubAuthorizationStore.credentialSource == .githubAppDeviceFlow
            ? String(localized: "Disconnect GitHub App...")
            : String(localized: "Remove Token")
    }

    /// Opens a same-source flow immediately and confirms every capability-changing switch.
    private func requestCredentialDestination(_ destination: GitHubCredentialDestination) {
        let isCrossSource = switch (githubAuthorizationStore.credentialSource, destination) {
        case (.githubAppDeviceFlow?, .readOnlyToken),
             (.fineGrainedPersonalAccessToken?, .githubApp): true
        default: false
        }
        if isCrossSource {
            pendingCredentialDestination = destination
        } else {
            presentCredentialDestination(destination)
        }
    }

    /// Consumes the source-switch warning before opening the destination flow.
    private func confirmCredentialSwitch() {
        guard let destination = pendingCredentialDestination else { return }
        pendingCredentialDestination = nil
        presentCredentialDestination(destination)
    }

    /// Presents one credential flow without mutating Keychain until that flow succeeds.
    private func presentCredentialDestination(_ destination: GitHubCredentialDestination) {
        switch destination {
        case .githubApp:
            githubAuthorizationStore.clearSignInError()
            showsGitHubAppSignInSheet = true
        case .readOnlyToken:
            showsGitHubTokenSheet = true
        }
    }

    /// Capability-specific title for a cross-source credential replacement.
    private var credentialSwitchTitle: String {
        switch pendingCredentialDestination {
        case .githubApp: String(localized: "Switch to the GitHub App?")
        case .readOnlyToken: String(localized: "Switch to a read-only token?")
        case nil: ""
        }
    }

    /// Capability-specific confirmation command.
    private var credentialSwitchButtonTitle: String {
        switch pendingCredentialDestination {
        case .githubApp: String(localized: "Continue to GitHub Sign-in")
        case .readOnlyToken: String(localized: "Continue to Token Entry")
        case nil: ""
        }
    }

    /// Explains the exact capability change before replacing the current source.
    private var credentialSwitchMessage: String {
        switch pendingCredentialDestination {
        case .githubApp:
            String(localized: "A successful GitHub App sign-in replaces the read-only token and enables Review Desk write actions.")
        case .readOnlyToken:
            String(localized: "Saving a read-only token disconnects the GitHub App and disables Review Desk write actions.")
        case nil:
            ""
        }
    }

    /// Credential-specific confirmation title that does not mislabel a GitHub App connection.
    private var removeCredentialTitle: String {
        if githubAuthorizationStore.credentialSource == .githubAppDeviceFlow {
            String(localized: "Disconnect GitHub App?")
        } else {
            String(localized: "Remove GitHub token?")
        }
    }

    /// Credential-specific destructive button label.
    private var removeCredentialButtonTitle: String {
        if githubAuthorizationStore.credentialSource == .githubAppDeviceFlow {
            String(localized: "Disconnect")
        } else {
            String(localized: "Remove Token")
        }
    }

    /// Credential-specific impact description for the destructive confirmation.
    private var removeCredentialMessage: String {
        if githubAuthorizationStore.credentialSource == .githubAppDeviceFlow {
            String(localized: "This removes the GitHub App credential from Keychain. Review Desk actions and pull request monitoring will require another sign-in.")
        } else {
            String(localized: "This removes the read-only token from Keychain. Pull request monitoring will require another token or GitHub App sign-in.")
        }
    }

    /// Status label for the saved GitHub token without exposing its value.
    @ViewBuilder private var githubAuthorizationStatusLabel: some View {
        switch githubAuthorizationStore.state {
        case .authorized:
            Label {
                Text(
                    githubAuthorizationStore.credentialSource == .githubAppDeviceFlow
                        ? String(localized: "GitHub App connected")
                        : String(localized: "Read-only token saved")
                )
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
                .foregroundStyle(.green)
        case .missing:
            Label("No token saved", systemImage: "key")
                .foregroundStyle(.secondary)
        case .failed(let error):
            Label {
                Text(error.localizedDescription)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
        }
    }

    /// General app preferences shown by default.
    private var generalPane: some View {
        Form {
            Section {
                Picker("Language", selection: $languageRaw) {
                    Text("System").tag(AppLanguage.system.rawValue)
                    Text(verbatim: "English").tag(AppLanguage.english.rawValue)
                    Text(verbatim: "Deutsch").tag(AppLanguage.german.rawValue)
                }
            } footer: {
                Text("Takes effect after relaunching CodingBuddy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("Auto").tag(AppearanceMode.auto.rawValue)
                    Text("Light").tag(AppearanceMode.light.rawValue)
                    Text("Dark").tag(AppearanceMode.dark.rawValue)
                }
            }

            if FeatureFlag.defaultEditorPreference.isEnabled {
                Section {
                    LabeledContent("Default editor") {
                        HStack(spacing: 8) {
                            Text(verbatim: defaultEditorPreference.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Choose App...") {
                                chooseDefaultEditor()
                            }
                            Button("Reset") {
                                resetDefaultEditor()
                            }
                            .disabled(defaultEditorPreference == .systemDefault)
                        }
                    }
                } footer: {
                    Text("Used when CodingBuddy opens Markdown, JSON, YAML, and other text files from repository tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: languageRaw) {
            AppLanguage(rawValue: languageRaw)?.apply()
        }
        // Applied here as well: the main window (and its onChange) may be
        // closed while the user switches the appearance in Settings.
        .onChange(of: appearanceRaw) {
            AppearanceMode(rawValue: appearanceRaw)?.apply()
        }
    }

    /// Editor preference represented by the current AppStorage values.
    private var defaultEditorPreference: DefaultTextEditorPreference {
        DefaultTextEditorPreference.fromStoredValues(
            bundleIdentifier: editorBundleIdentifier,
            applicationPath: editorApplicationPath,
            displayName: editorDisplayName
        )
    }

    /// Presents a native application picker and stores the selected app.
    private func chooseDefaultEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.message = String(localized: "Choose the app CodingBuddy should use for Markdown and other text files.")
        panel.prompt = String(localized: "Choose Default Editor")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveDefaultEditor(url)
    }

    /// Stores the selected application bundle metadata for later relaunches.
    private func saveDefaultEditor(_ url: URL) {
        switch DefaultTextEditorPreference.application(at: url) {
        case .systemDefault:
            resetDefaultEditor()
        case .application(let bundleIdentifier, let applicationURL, let displayName):
            editorBundleIdentifier = bundleIdentifier ?? ""
            editorApplicationPath = applicationURL.path
            editorDisplayName = displayName
        }
    }

    /// Resets CodingBuddy to Launch Services' system default editor.
    private func resetDefaultEditor() {
        editorBundleIdentifier = ""
        editorApplicationPath = ""
        editorDisplayName = ""
    }
}

/// One independently identified package-manager executable preference row.
private struct PackageExecutableSettingsRow: View {
    /// Package manager whose executable override is configured.
    let manager: PackageManagerKind
    /// Editable executable path, empty when automatic discovery is used.
    @Binding var path: String
    /// Action that presents an executable picker.
    var choose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(manager.displayName, systemImage: manager.systemImage)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
            TextField(text: $path, prompt: Text("Automatic")) {
                EmptyView()
            }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)
                .layoutPriority(1)
                .accessibilityLabel(formattedLabel("Executable path for %@"))
            Button("Choose…", action: choose)
                .fixedSize()
                .accessibilityLabel(formattedLabel("Choose %@ executable"))
            Button("Reset") { path = "" }
                .fixedSize()
                .disabled(path.isEmpty)
                .accessibilityLabel(formattedLabel("Reset %@ executable"))
        }
    }

    private func formattedLabel(_ key: LocalizedStringResource) -> String {
        String(format: String(localized: key), manager.displayName)
    }
}

/// Sheet for saving or replacing the GitHub token from Settings.
private struct GitHubTokenSettingsSheet: View {
    /// Store that persists the token without exposing its value.
    var store: GitHubAuthorizationStore
    /// Called after a token is saved successfully.
    var onSaved: () -> Void

    /// Dismisses the sheet after save or cancel.
    @Environment(\.dismiss) private var dismiss
    /// Token text typed by the user. It is never shown again after save.
    @State private var token = ""

    /// Compact token setup form.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read-only GitHub Token")
                .font(.title3)
                .fontWeight(.semibold)

            Text("For monitoring, use a fine-grained token with read-only Metadata, Pull requests, Issues, Checks, and Commit statuses. Read-only Review Desk inspection also requires Administration: read. CodingBuddy never uses this token for writes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Token", text: $token)
                .textFieldStyle(.roundedBorder)

            if case .failed(let error) = store.state {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Token") {
                    Task {
                        if await store.saveToken(token) {
                            onSaved()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Native GitHub App device-flow sheet with a short-lived browser code.
private struct GitHubAppSignInSheet: View {
    /// Asynchronous device-flow element that VoiceOver should announce next.
    private enum AccessibilityTarget: Hashable {
        /// One-time code and its copy action are ready.
        case code
        /// CodingBuddy is waiting for GitHub approval.
        case waiting
        /// A token-safe error requires attention.
        case error
    }

    /// Authorization store that owns token-safe device-flow operations.
    var store: GitHubAuthorizationStore
    /// Called after the credential bundle reaches Keychain.
    var onSaved: () -> Void

    /// Dismisses the sheet after success or cancellation.
    @Environment(\.dismiss) private var dismiss
    /// Short-lived authorization retained only while this sheet exists.
    @State private var authorization: GitHubDeviceAuthorization?
    /// Whether the initial device-code request is running.
    @State private var isRequesting = true
    /// Whether CodingBuddy is polling for browser approval.
    @State private var isWaiting = false
    /// Stable task identity incremented only for an explicit retry.
    @State private var signInAttempt = 0
    /// VoiceOver follows code, waiting, and error transitions driven by async work.
    @AccessibilityFocusState private var accessibilityTarget: AccessibilityTarget?

    /// Device-flow status and browser actions.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with GitHub")
                .font(.title3)
                .fontWeight(.semibold)

            if isRequesting {
                ProgressView("Requesting a secure sign-in code...")
                    .controlSize(.small)
            } else if let authorization {
                Text("Enter this one-time code on GitHub. CodingBuddy will continue when access is approved.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(authorization.userCode)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("GitHub sign-in code")
                        .accessibilityValue(authorization.userCode)
                        .accessibilityFocused($accessibilityTarget, equals: .code)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authorization.userCode, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy code")
                    .accessibilityLabel("Copy GitHub sign-in code")
                    .accessibilityHint("Copies the one-time code to the clipboard.")
                    Button("Open GitHub") {
                        NSWorkspace.shared.open(authorization.verificationURL)
                    }
                    .accessibilityHint("Opens the secure GitHub device authorization page.")
                }

                if isWaiting {
                    ProgressView("Waiting for GitHub approval...")
                        .controlSize(.small)
                }
            }

            if let error = store.signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityFocused($accessibilityTarget, equals: .error)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if store.signInError != nil {
                    Button("Try Again") {
                        store.clearSignInError()
                        authorization = nil
                        isRequesting = true
                        signInAttempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: signInAttempt) {
            guard let requested = await store.beginGitHubAppSignIn() else {
                isRequesting = false
                return
            }
            authorization = requested
            isRequesting = false
            accessibilityTarget = .code
            isWaiting = true
            AccessibilityNotification.Announcement(
                String(localized: "GitHub sign-in code is ready. Copy it, then open GitHub to continue.")
            ).post()
            let saved = await store.completeGitHubAppSignIn(requested)
            isWaiting = false
            if saved {
                onSaved()
                dismiss()
            } else if store.signInError != nil {
                accessibilityTarget = .error
            }
        }
    }
}

#Preview {
    SettingsView()
}
