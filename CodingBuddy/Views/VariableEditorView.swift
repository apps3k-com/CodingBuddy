//
//  VariableEditorView.swift
//  CodingBuddy
//

import SwiftUI

/// Editor for creating or safely replacing one zsh environment assignment.
struct VariableEditorView: View {
    /// Distinguishes creation in a target file from editing a revalidated source line.
    enum Mode: Identifiable {
        /// Creates a new assignment in the selected shell configuration file.
        case new(ShellConfigFile)
        /// Edits an existing assignment while retaining its source identity.
        case edit(EnvVariable)

        /// Stable sheet identity tied to the creation target or source assignment.
        var id: String {
            switch self {
            case .new(let file): "new-\(file.rawValue)"
            case .edit(let variable): "edit-\(variable.id)"
            }
        }
    }

    /// Store that performs backup-first, source-revalidated mutations.
    let store: EnvStore
    /// Shared authentication state that controls cleartext lifetime.
    var secrets: SecretsGuard
    /// Creation or edit context represented by this sheet.
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rawValue: String
    @State private var exported: Bool
    @State private var targetFile: ShellConfigFile
    @State private var editAsList: Bool

    /// Initializes draft state from the requested creation target or assignment.
    init(store: EnvStore, secrets: SecretsGuard, mode: Mode) {
        self.store = store
        self.secrets = secrets
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
            return String(localized: "Command substitution ($(…) or `…`) is not supported.")
        }
        if ShellQuoting.bestQuoting(for: rawValue, preferred: .double) == nil {
            return String(localized: "This quote combination cannot be written safely.")
        }
        return nil
    }

    private var duplicateHint: String? {
        guard isNew, nameIsValid,
              let existing = store.variables.first(where: { $0.name == name }) else { return nil }
        return String(localized: "“\(name)” is already defined in \(existing.file.rawValue) — the last assignment in load order wins.")
    }

    private var canSave: Bool {
        nameIsValid && valueProblem == nil
    }

    /// Whether this sheet owns cleartext revealed from a protected existing variable.
    private var protectsRevealedSecret: Bool {
        guard FeatureFlag.secretsProtection.isEnabled,
              case .edit(let variable) = mode
        else { return false }
        return SecretDetector.isSensitive(name: variable.name)
    }

    /// Whether dismissing this sheet would lose a meaningful draft change.
    private var hasUnsavedChanges: Bool {
        switch mode {
        case .new(let file):
            return !name.isEmpty || !rawValue.isEmpty || targetFile != file
        case .edit(let variable):
            return name != variable.name
                || rawValue != variable.rawValue
                || exported != variable.assignment.hasExport
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .monospaced()
                    if !name.isEmpty && !nameIsValid {
                        ValidationHint(String(localized: "Names consist of letters, digits and _ and must not start with a digit."))
                    }
                    if let duplicateHint {
                        ValidationHint(duplicateHint, severity: .info)
                    }
                }

                Section {
                    if editAsList {
                        PathEditorView(rawValue: $rawValue)
                    } else {
                        TextField("Value", text: $rawValue, axis: .vertical)
                            .monospaced()
                            .lineLimit(1...4)
                    }
                    if rawValue.contains(":") || editAsList {
                        Toggle("Edit as list (PATH-style)", isOn: $editAsList)
                            .toggleStyle(.checkbox)
                    }
                    if let valueProblem {
                        ValidationHint(valueProblem)
                    }
                } footer: {
                    Text("The value is written verbatim — $VARIABLES remain unexpanded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if isNew {
                        Picker("File", selection: $targetFile) {
                            ForEach(ShellConfigFile.allCases) { file in
                                Text(file.rawValue).tag(file)
                            }
                        }
                    } else {
                        LabeledContent("File", value: targetFile.rawValue)
                        Toggle("Visible to child processes (export)", isOn: $exported)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                (isNew ? Text("New Variable") : Text("Edit Variable"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 480, height: editAsList ? 520 : 400)
        .protectsSecretDraft(
            secrets: secrets,
            protectsRevealedSecret: protectsRevealedSecret,
            currentName: name,
            hasUnsavedChanges: hasUnsavedChanges,
            canSave: canSave,
            saveAndDismiss: save,
            clearAndDismiss: clearAndDismiss,
            reportAutomaticDiscard: {
                store.lastError = String(localized: "The unlock period ended. CodingBuddy discarded the unsaved cleartext draft.")
            }
        )
    }

    @discardableResult
    private func save() -> Bool {
        let saved = switch mode {
        case .new:
            store.addAll([(name: name, rawValue: rawValue)], to: targetFile)
        case .edit(let variable):
            store.update(variable, name: name, rawValue: rawValue, exported: exported)
        }
        if saved { dismiss() }
        return saved
    }

    /// Removes the cleartext draft before closing the sheet.
    private func clearAndDismiss() {
        rawValue = ""
        name = ""
        dismiss()
    }
}

/// Compact validation feedback shown before a shell-file write is allowed.
private struct ValidationHint: View {
    /// Visual urgency of a validation message.
    enum Severity {
        /// Input cannot currently be saved safely.
        case warning
        /// Input is valid but has a noteworthy consequence.
        case info
    }

    /// Localized validation explanation.
    let text: String
    /// Visual urgency used for symbol and tint selection.
    var severity: Severity

    /// Creates a hint that defaults to write-blocking warning presentation.
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
