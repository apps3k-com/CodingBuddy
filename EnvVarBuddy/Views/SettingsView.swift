//
//  SettingsView.swift
//  EnvVarBuddy
//

import SwiftUI

/// Presented as a sheet over the main window — window-modal on purpose, so
/// it neither spawns a second window nor leaves the app interactive behind it.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(SecretsGuard.unlockDurationKey) private var unlockDuration = SecretsGuard.defaultUnlockDuration

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    generalPane
                }
                Tab("Security", systemImage: "lock.shield") {
                    securityPane
                }
            }
            .scenePadding()

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 440, height: 400)
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
                Text("Takes effect after relaunching EnvVarBuddy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("Auto").tag(AppearanceMode.auto.rawValue)
                    Text("Light").tag(AppearanceMode.light.rawValue)
                    Text("Dark").tag(AppearanceMode.dark.rawValue)
                }
                .pickerStyle(.segmented)
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
}

#Preview {
    SettingsView()
}
