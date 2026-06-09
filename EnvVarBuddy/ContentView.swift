//
//  ContentView.swift
//  EnvVarBuddy
//

import SwiftUI

enum SidebarScope: Hashable {
    case all
    case file(ShellConfigFile)

    var file: ShellConfigFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    var title: String {
        switch self {
        case .all: String(localized: "All Variables")
        case .file(let file): file.rawValue
        }
    }
}

struct ContentView: View {
    @State private var store = EnvStore()
    @State private var secrets = SecretsGuard()
    @State private var scope: SidebarScope? = .all

    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                Label("All Variables", systemImage: "list.bullet")
                    .tag(SidebarScope.all)
                Section("Files") {
                    ForEach(ShellConfigFile.allCases) { file in
                        Label(file.rawValue, systemImage: "doc.text")
                            .foregroundStyle(store.existingFiles.contains(file) ? .primary : .secondary)
                            .badge(store.variables(in: file).count)
                            .tag(SidebarScope.file(file))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VariableListView(store: store, secrets: secrets, scope: scope ?? .all)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environment(MenuActions())
}
