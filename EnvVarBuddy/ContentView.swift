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
        case .all: "Alle Variablen"
        case .file(let file): file.displayName
        }
    }
}

struct ContentView: View {
    @State private var store = EnvStore()
    @State private var scope: SidebarScope? = .all

    var body: some View {
        NavigationSplitView {
            List(selection: $scope) {
                Label("Alle Variablen", systemImage: "list.bullet")
                    .tag(SidebarScope.all)
                Section("Dateien") {
                    ForEach(ShellConfigFile.allCases) { file in
                        Label(file.displayName, systemImage: "doc.text")
                            .foregroundStyle(store.existingFiles.contains(file) ? .primary : .secondary)
                            .badge(store.variables(in: file).count)
                            .tag(SidebarScope.file(file))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VariableListView(store: store, scope: scope ?? .all)
        }
        .alert(
            "Fehler",
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
}
