//
//  SettingsView.swift
//  CodingBuddy
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Presented as a sheet over the main window — window-modal on purpose, so
/// it neither spawns a second window nor leaves the app interactive behind it.
struct SettingsView: View {
    /// Settings sections exposed by the sheet's segmented control.
    private enum Pane: Hashable {
        case general
        case security
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane = .general
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(DefaultTextEditorPreference.bundleIdentifierKey) private var editorBundleIdentifier = ""
    @AppStorage(DefaultTextEditorPreference.applicationPathKey) private var editorApplicationPath = ""
    @AppStorage(DefaultTextEditorPreference.displayNameKey) private var editorDisplayName = ""
    @AppStorage(SecretsGuard.unlockDurationKey) private var unlockDuration = SecretsGuard.defaultUnlockDuration

    var body: some View {
        // No TabView here: inside a sheet it draws its own bordered box,
        // which clashes with the grouped form and the sheet background.
        VStack(spacing: 0) {
            Picker(selection: $pane) {
                Text("General").tag(Pane.general)
                Text("Security").tag(Pane.security)
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
        .frame(width: 480, height: 430)
    }

    private var securityPane: some View {
        Form {
            Section {
                Picker("Keep secrets revealed for", selection: $unlockDuration) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("Until quit").tag(-1.0)
                }
            } footer: {
                Text("Values that look like secrets (TOKEN, KEY, PASSWORD, …) are masked until you authenticate with Touch ID or your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

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

#Preview {
    SettingsView()
}
