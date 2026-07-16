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
    /// Whether the GitHub token removal confirmation is visible.
    @State private var showsRemoveGitHubTokenConfirmation = false

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
                        HStack(spacing: 8) {
                            Button(githubAuthorizationStore.hasSavedToken ? "Replace Token..." : "Add Token...") {
                                showsGitHubTokenSheet = true
                            }
                            Button("Remove Token", role: .destructive) {
                                showsRemoveGitHubTokenConfirmation = true
                            }
                            .disabled(!githubAuthorizationStore.hasSavedToken)
                        }
                    }
                } header: {
                    Text("GitHub token")
                } footer: {
                    Text("Used by Agent PR Monitor to read pull request, issue, check, and review status from GitHub.")
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
        .confirmationDialog("Remove GitHub token?", isPresented: $showsRemoveGitHubTokenConfirmation) {
            Button("Remove Token", role: .destructive) {
                if githubAuthorizationStore.deleteToken() {
                    onGitHubAuthorizationChange(.removed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the token from Keychain. You will need to add a token again to use Agent PR Monitor.")
        }
    }

    /// Status label for the saved GitHub token without exposing its value.
    @ViewBuilder private var githubAuthorizationStatusLabel: some View {
        switch githubAuthorizationStore.state {
        case .authorized:
            Label("Token saved", systemImage: "checkmark.seal.fill")
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
    let manager: PackageManagerKind
    @Binding var path: String
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
            Text("GitHub Token")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Use a fine-grained personal access token with read-only Metadata, Pull requests, Issues, Checks, and Commit statuses permissions.")
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
                    if store.saveToken(token) {
                        onSaved()
                        dismiss()
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

#Preview {
    SettingsView()
}
