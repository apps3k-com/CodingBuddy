//
//  SettingsView.swift
//  EnvVarBuddy
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.auto.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalPane
            }
        }
        .scenePadding()
        .frame(width: 440)
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
    }
}

#Preview {
    SettingsView()
}
