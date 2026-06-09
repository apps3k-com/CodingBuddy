//
//  VariableEditorView.swift
//  EnvVarBuddy
//

import SwiftUI

struct VariableEditorView: View {
    enum Mode: Identifiable {
        case new(ShellConfigFile)
        case edit(EnvVariable)

        var id: String {
            switch self {
            case .new(let file): "new-\(file.rawValue)"
            case .edit(let variable): "edit-\(variable.id)"
            }
        }
    }

    let store: EnvStore
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rawValue: String
    @State private var exported: Bool
    @State private var targetFile: ShellConfigFile
    @State private var editAsList: Bool

    init(store: EnvStore, mode: Mode) {
        self.store = store
        self.mode = mode
        switch mode {
        case .new(let file):
            _name = State(initialValue: "")
            _rawValue = State(initialValue: "")
            _exported = State(initialValue: true)
            _targetFile = State(initialValue: file)
            _editAsList = State(initialValue: false)
        case .edit(let variable):
            _name = State(initialValue: variable.name)
            _rawValue = State(initialValue: variable.rawValue)
            _exported = State(initialValue: variable.assignment.hasExport)
            _targetFile = State(initialValue: variable.file)
            _editAsList = State(initialValue: false)
        }
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private var nameIsValid: Bool {
        (try? ShellConfigWriter.validateName(name)) != nil
    }

    private var valueProblem: String? {
        if ShellQuoting.containsCommandSubstitution(rawValue) {
            return "Command Substitution ($(…) oder `…`) wird nicht unterstützt."
        }
        if ShellQuoting.bestQuoting(for: rawValue, preferred: .double) == nil {
            return "Diese Quote-Kombination kann nicht sicher geschrieben werden."
        }
        return nil
    }

    private var duplicateHint: String? {
        guard isNew, nameIsValid,
              let existing = store.variables.first(where: { $0.name == name }) else { return nil }
        return "„\(name)“ ist bereits in \(existing.file.rawValue) definiert — es gilt die letzte Zuweisung in der Ladereihenfolge."
    }

    private var canSave: Bool {
        nameIsValid && valueProblem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .monospaced()
                    if !name.isEmpty && !nameIsValid {
                        ValidationHint("Namen bestehen aus Buchstaben, Ziffern und _ und beginnen nicht mit einer Ziffer.")
                    }
                    if let duplicateHint {
                        ValidationHint(duplicateHint, severity: .info)
                    }
                }

                Section {
                    if editAsList {
                        PathEditorView(rawValue: $rawValue)
                    } else {
                        TextField("Wert", text: $rawValue, axis: .vertical)
                            .monospaced()
                            .lineLimit(1...4)
                    }
                    if rawValue.contains(":") || editAsList {
                        Toggle("Als Liste bearbeiten (PATH-Stil)", isOn: $editAsList)
                            .toggleStyle(.checkbox)
                    }
                    if let valueProblem {
                        ValidationHint(valueProblem)
                    }
                } footer: {
                    Text("Der Wert wird wortwörtlich geschrieben — $VARIABLEN bleiben unausgewertet erhalten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if isNew {
                        Picker("Datei", selection: $targetFile) {
                            ForEach(ShellConfigFile.allCases) { file in
                                Text(file.rawValue).tag(file)
                            }
                        }
                    } else {
                        LabeledContent("Datei", value: targetFile.rawValue)
                        Toggle("Mit export für Kindprozesse sichtbar", isOn: $exported)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text(isNew ? "Neue Variable" : "Variable bearbeiten")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 480, height: editAsList ? 520 : 400)
    }

    private func save() {
        switch mode {
        case .new:
            store.addAll([(name: name, rawValue: rawValue)], to: targetFile)
        case .edit(let variable):
            store.update(variable, name: name, rawValue: rawValue, exported: exported)
        }
        dismiss()
    }
}

private struct ValidationHint: View {
    enum Severity { case warning, info }

    let text: String
    var severity: Severity

    init(_ text: String, severity: Severity = .warning) {
        self.text = text
        self.severity = severity
    }

    var body: some View {
        Label(text, systemImage: severity == .warning ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(severity == .warning ? .orange : .secondary)
    }
}
