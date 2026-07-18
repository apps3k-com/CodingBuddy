//
//  GitHubProjectsView.swift
//  CodingBuddy
//

import Accessibility
import SwiftUI

/// Native GitHub Projects table, board, drift inspector, and guarded move surface.
struct GitHubProjectsView: View {
    /// Root-owned Project workspace state.
    @Bindable var store: GitHubProjectsStore
    /// Opens the shared GitHub authorization Settings pane.
    let openSettings: () -> Void
    /// Selected Project item shared by Table, Board, and inspector.
    @State private var selectedItemID: String?
    /// Whether lifecycle and drift semantics are being edited.
    @State private var showsPolicySheet = false
    /// VoiceOver focus for async, failure, and ambiguous-write status changes.
    @AccessibilityFocusState private var statusBandFocused: Bool

    /// Width at which the item inspector can remain beside the Project content.
    private let sideBySideInspectorMinimumWidth: CGFloat = 820

    /// Selected row from the one shared projection.
    private var selectedRow: GitHubProjectBoardRow? {
        store.projection?.rows.first { $0.id == selectedItemID }
    }

    /// Main Project workspace.
    var body: some View {
        VStack(spacing: 0) {
            sourceBar
            Divider()
            statusArea
            workspace
        }
        .navigationTitle("Projects")
        .toolbar { projectToolbar }
        .searchable(text: searchBinding, prompt: "Search Project items")
        .confirmationDialog(
            "Confirm Project move",
            isPresented: pendingConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Move", role: store.pendingPreflight?.risk == .contradictory ? .destructive : nil) {
                store.confirmPendingMove()
            }
            Button("Cancel", role: .cancel) {
                store.cancelPendingMove()
            }
        } message: {
            Text(moveConfirmationMessage)
        }
        .sheet(isPresented: $showsPolicySheet) {
            if let snapshot = store.snapshot,
               let fieldID = store.preferences.selectedFieldID,
               let field = snapshot.fields.first(where: { $0.id == fieldID }),
               let policy = store.preferences.policy {
                GitHubProjectPolicyView(
                    field: field,
                    workflows: snapshot.workflows,
                    fieldsComplete: snapshot.coverage.fieldsComplete,
                    workflowsComplete: snapshot.coverage.workflowsComplete,
                    policy: policy
                ) { policy in
                    store.updatePolicy(policy)
                    showsPolicySheet = false
                }
            }
        }
        .onChange(of: store.projection?.tableItemIDs) {
            guard let selectedItemID,
                  store.projection?.tableItemIDs.contains(selectedItemID) != true else { return }
            self.selectedItemID = nil
        }
        .task(id: statusAnnouncement) {
            await focusAndAnnounceStatus()
        }
    }

    /// Organization, Project, and field controls.
    private var sourceBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                organizationField
                    .frame(minWidth: 130, idealWidth: 170, maxWidth: 220)
                loadProjectsButton
                projectPicker
                    .frame(minWidth: 180, maxWidth: 280)
                fieldPicker
                    .frame(minWidth: 150, maxWidth: 220)
                Spacer(minLength: 8)
                authorizationButton
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    organizationField
                    loadProjectsButton
                    Spacer(minLength: 4)
                    authorizationButton
                }
                HStack(spacing: 8) {
                    projectPicker
                        .frame(maxWidth: .infinity)
                    fieldPicker
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Organization login shared by both source-bar arrangements.
    private var organizationField: some View {
        TextField("Organization", text: organizationBinding)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("GitHub organization")
            .onSubmit { store.discoverProjects() }
            .disabled(sourceControlsLocked)
    }

    /// Bounded organization Project discovery action.
    private var loadProjectsButton: some View {
        Button {
            store.discoverProjects()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Load organization Projects")
        .accessibilityLabel("Load organization Projects")
        .disabled(
            sourceControlsLocked
                || store.preferences.organizationLogin.isEmpty
                || store.discoveryState == .loading
        )
    }

    /// Project selection shared by both source-bar arrangements.
    private var projectPicker: some View {
        Picker("Project", selection: projectBinding) {
            if store.preferences.selectedProjectID == nil {
                Text("Choose Project").tag(String?.none)
            }
            ForEach(store.projectList?.projects ?? []) { project in
                Text(project.title).tag(Optional(project.id))
            }
        }
        .labelsHidden()
        .accessibilityLabel("GitHub Project")
        .disabled(sourceControlsLocked || store.projectList == nil)
    }

    /// Board-field selection shared by both source-bar arrangements.
    private var fieldPicker: some View {
        Picker("Field", selection: fieldBinding) {
            if store.preferences.selectedFieldID == nil {
                Text("Choose field").tag(String?.none)
            }
            ForEach(store.snapshot?.fields ?? []) { field in
                Text(field.name).tag(Optional(field.id))
            }
        }
        .labelsHidden()
        .accessibilityLabel("Board field")
        .disabled(
            sourceControlsLocked
                || store.snapshot == nil
                || store.snapshot?.fields.isEmpty == true
        )
    }

    /// Shared authorization Settings action.
    private var authorizationButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "person.badge.key")
        }
        .help("Open GitHub authorization settings")
        .accessibilityLabel("Open GitHub authorization settings")
    }

    /// Compact fail-closed status messages that do not replace retained data.
    @ViewBuilder
    private var statusArea: some View {
        Group {
            if store.discoveryState == .loading || store.snapshotState == .loading {
                statusRow(icon: "arrow.clockwise", text: String(localized: "Loading GitHub Projects..."))
            }
            if case .failed(let message) = store.discoveryState {
                statusRow(icon: "exclamationmark.triangle.fill", text: message, color: .orange)
            }
            if case .failed(let message) = store.snapshotState {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    text: staleSnapshotMessage(refreshFailure: message),
                    color: .orange
                )
            }
            if store.projectList?.isTruncated == true {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    text: String(localized: "Project discovery reached the configured safety limit."),
                    color: .orange
                )
            }
            if let snapshot = store.snapshot, !snapshot.coverage.isComplete {
                statusRow(
                    icon: "lock.fill",
                    text: String(localized: "Project evidence is incomplete. Changes are disabled."),
                    color: .orange
                )
            }
            if store.assessment?.state == .partial {
                statusRow(
                    icon: "questionmark.circle.fill",
                    text: String(localized: "Drift assessment is incomplete. Known findings are shown, but CodingBuddy cannot confirm an all-clear."),
                    color: .orange
                )
            }
            if store.snapshot?.project.viewerCanUpdate == false {
                statusRow(
                    icon: "lock.fill",
                    text: String(localized: "Read-only access. GitHub does not allow this account to update Project items."),
                    color: .orange
                )
            }
            if store.assessment?.state == .configurationRequired {
                configurationRequiredStatus
            }
            moveStatus
        }
        .accessibilityFocused($statusBandFocused)
    }

    /// Explains why drift cannot be cleared and offers the required local action.
    private var configurationRequiredStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lifecycle policy requires configuration")
                    .fontWeight(.medium)
                Text("Assign every field option a lifecycle role before assessing drift or moving items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Configure policy") { showsPolicySheet = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    /// Mutation status and explicit ambiguous-write reconciliation.
    @ViewBuilder
    private var moveStatus: some View {
        switch store.moveState {
        case .preflighting:
            statusRow(icon: "checkmark.shield", text: String(localized: "Validating current Project state..."))
        case .executing:
            statusRow(icon: "arrow.up.arrow.down", text: String(localized: "Applying Project move..."))
        case .ambiguous:
            HStack(spacing: 8) {
                Label(ambiguousMoveStatusMessage, systemImage: "questionmark.diamond.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Verify on GitHub") { store.verifyAmbiguousMove() }
                    .disabled(store.snapshotState == .loading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.08))
            .accessibilityElement(children: .contain)
        case .drifted:
            dismissibleStatus(
                icon: "arrow.triangle.2.circlepath",
                text: String(localized: "Project state changed. Review the refreshed item."),
                color: .orange
            )
        case .failed(let message), .succeeded(let message):
            dismissibleStatus(
                icon: store.moveState.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill",
                text: message,
                color: store.moveState.isSuccess ? .green : .red
            )
        case .idle, .awaitingConfirmation:
            EmptyView()
        }
    }

    /// Table or Board plus an optional evidence inspector.
    @ViewBuilder
    private var workspace: some View {
        if let projection = store.projection, projection.rows.isEmpty {
            emptyProjectContent
        } else if let projection = store.projection {
            GeometryReader { proxy in
                if let selectedRow, proxy.size.width < sideBySideInspectorMinimumWidth {
                    VSplitView {
                        projectContent(projection)
                            .frame(minHeight: 150, maxHeight: .infinity)
                        projectInspector(row: selectedRow, projection: projection)
                            .frame(minHeight: 130, idealHeight: 210, maxHeight: 300)
                    }
                } else {
                    HSplitView {
                        projectContent(projection)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        if let selectedRow {
                            projectInspector(row: selectedRow, projection: projection)
                                .frame(minWidth: 280, idealWidth: 330, maxWidth: 390)
                        }
                    }
                }
            }
        } else if store.snapshotState == .loading || store.discoveryState == .loading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let projectList = store.projectList, projectList.projects.isEmpty {
            ContentUnavailableView {
                Label("No accessible Projects", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text("No organization Projects are visible to the current GitHub authorization. Check organization access and Project permissions.")
            } actions: {
                Button("Open GitHub authorization settings", systemImage: "person.badge.key") { openSettings() }
                Button("Load organization Projects", systemImage: "arrow.clockwise") { store.discoverProjects() }
            }
        } else if let snapshot = store.snapshot, snapshot.fields.isEmpty {
            if snapshot.coverage.fieldsComplete {
                ContentUnavailableView {
                    Label("No single-select fields", systemImage: "rectangle.3.group.bubble")
                } description: {
                    Text("This Project has no single-select fields available for a table or board.")
                } actions: {
                    Button("Refresh Project", systemImage: "arrow.clockwise") { store.refreshSnapshot() }
                }
            } else {
                ContentUnavailableView {
                    Label("Project fields unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text("GitHub did not provide a complete field list. Refresh before choosing a board field.")
                } actions: {
                    Button("Refresh Project", systemImage: "arrow.clockwise") { store.refreshSnapshot() }
                }
            }
        } else if store.snapshot != nil {
            ContentUnavailableView(
                "Choose a board field",
                systemImage: "rectangle.3.group",
                description: Text("Select a single-select field to define the table values and board columns.")
            )
        } else {
            ContentUnavailableView(
                "Choose a GitHub Project",
                systemImage: "rectangle.3.group"
            )
        }
    }

    /// Current Table or Board representation without inspector layout policy.
    @ViewBuilder
    private func projectContent(_ projection: GitHubProjectBoardProjection) -> some View {
        switch store.preferences.viewMode {
        case .table: projectTable(projection)
        case .board: projectBoard(projection)
        }
    }

    /// Selected evidence inspector shared by horizontal and vertical split layouts.
    private func projectInspector(
        row: GitHubProjectBoardRow,
        projection: GitHubProjectBoardProjection
    ) -> some View {
        GitHubProjectInspector(
            row: row,
            assessment: store.assessment,
            field: projection.field,
            movesEnabled: store.movesAreEnabled,
            requestMove: store.requestMove
        )
    }

    /// Distinguishes an empty Project from local filters and archived-only content.
    @ViewBuilder
    private var emptyProjectContent: some View {
        if store.snapshot?.items.isEmpty == true {
            if store.snapshot?.coverage.itemsComplete == true {
                ContentUnavailableView(
                    "No Project items",
                    systemImage: "tray",
                    description: Text("This Project snapshot contains no items.")
                )
            } else {
                ContentUnavailableView {
                    Label("Project items unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text("GitHub did not provide a complete item list. Refresh before evaluating this Project.")
                } actions: {
                    Button("Refresh Project", systemImage: "arrow.clockwise") { store.refreshSnapshot() }
                }
            }
        } else if hasRestrictiveFilters {
            ContentUnavailableView {
                Label("No matching Project items", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Change the search or Project filters to show items.")
            } actions: {
                Button("Reset Filters", systemImage: "arrow.counterclockwise") { resetFilters() }
            }
        } else if store.preferences.filter.includesArchived == false {
            ContentUnavailableView {
                Label("No active Project items", systemImage: "archivebox")
            } description: {
                Text("This Project contains only archived items.")
            } actions: {
                Button("Show archived items", systemImage: "archivebox") { showArchivedItems() }
            }
        } else {
            ContentUnavailableView(
                "No visible Project items",
                systemImage: "eye.slash",
                description: Text("GitHub did not return any items that can be shown for this field.")
            )
        }
    }

    /// Dense native table representation.
    private func projectTable(_ projection: GitHubProjectBoardProjection) -> some View {
        Table(projection.rows, selection: $selectedItemID) {
            TableColumn("Type") { row in
                Image(systemName: row.item.content.kind.systemImage)
                    .accessibilityLabel(row.item.content.kind.displayName)
            }
            .width(34)
            TableColumn("Title") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.item.content.title.isEmpty ? row.item.content.referenceLabel : row.item.content.title)
                        .lineLimit(2)
                    Text(row.item.content.referenceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu { moveMenu(row: row, field: projection.field) }
            }
            TableColumn("Repository") { row in
                if row.scopeMembership == .unknown {
                    Label("Unknown", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Text(row.item.content.repository?.displayName ?? String(localized: "Unavailable"))
                        .foregroundStyle(row.item.content.repository == nil ? .secondary : .primary)
                }
            }
            TableColumn(projection.field.name) { row in
                projectValueLabel(row: row)
            }
            TableColumn("Drift") { row in
                driftLabel(row.findings)
            }
            .width(min: 80, ideal: 105)
        }
        .accessibilityLabel("GitHub Project table")
    }

    /// Horizontal native-scrolling Kanban representation.
    private func projectBoard(_ projection: GitHubProjectBoardProjection) -> some View {
        let rowsByColumn = Dictionary(grouping: projection.rows, by: \.columnID)
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(projection.columns) { column in
                    boardColumn(
                        column,
                        rows: rowsByColumn[column.id] ?? [],
                        field: projection.field
                    )
                }
            }
            .padding(12)
        }
        .accessibilityLabel("GitHub Project board")
    }

    /// One pre-grouped board lane with independent lazy vertical rendering.
    private func boardColumn(
        _ column: GitHubProjectBoardColumn,
        rows: [GitHubProjectBoardRow],
        field: GitHubProjectSingleSelectField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                projectValueLabel(column: column)
                Spacer(minLength: 4)
                Text(rows.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(LocalizedCountText.items(rows.count))
            }
            .font(.headline)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        boardCard(row: row, column: column, field: field)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.displayName)
    }

    /// One selectable board item with a complete unavailable-content fallback.
    private func boardCard(
        row: GitHubProjectBoardRow,
        column: GitHubProjectBoardColumn,
        field: GitHubProjectSingleSelectField
    ) -> some View {
        Button {
            selectedItemID = row.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(itemDisplayTitle(row))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack {
                    Text(row.item.content.referenceLabel)
                    Spacer(minLength: 6)
                    driftLabel(row.findings)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(boardCardBackground(row))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu { moveMenu(row: row, field: field) }
        .accessibilityLabel(boardCardAccessibilityLabel(row: row, column: column))
        .accessibilityHint("Selects the item and opens its evidence inspector.")
    }

    /// Stable board-card selection color without expanding the card builder type.
    private func boardCardBackground(_ row: GitHubProjectBoardRow) -> Color {
        selectedItemID == row.id
            ? Color.accentColor.opacity(0.14)
            : Color(nsColor: .controlBackgroundColor)
    }

    /// Shared filtering, view, refresh, and policy controls.
    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: viewModeBinding) {
                ForEach(GitHubProjectViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Project view")

            Menu {
                ForEach(store.snapshot?.repositories ?? []) { repository in
                    Toggle(repository.displayName, isOn: repositoryFilterBinding(repository.canonicalID))
                }
                Divider()
                Toggle("Include archived items", isOn: archivedItemsBinding)
            } label: {
                Label("Repositories", systemImage: "shippingbox")
            }
            .help("Filter repositories")
            .accessibilityLabel("Filter repositories")

            Menu {
                ForEach(GitHubProjectDriftCategory.allCases, id: \.self) { category in
                    Toggle(category.displayName, isOn: driftFilterBinding(category))
                }
            } label: {
                Label("Drift", systemImage: "waveform.path.ecg")
            }
            .help("Filter planning drift")
            .accessibilityLabel("Filter planning drift")

            Button {
                showsPolicySheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Configure lifecycle policy")
            .accessibilityLabel("Configure lifecycle policy")
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(
                sourceControlsLocked
                    || store.snapshot == nil
                    || store.preferences.selectedFieldID == nil
            )

            Button {
                store.refreshSnapshot()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Project")
            .accessibilityLabel(refreshProjectAccessibilityLabel)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.preferences.selectedProjectID == nil || !store.moveState.allowsNewMove)
        }
    }

    /// Context menu that routes every field change through the guarded store.
    @ViewBuilder
    private func moveMenu(row: GitHubProjectBoardRow, field: GitHubProjectSingleSelectField) -> some View {
        Menu("Move to") {
            ForEach(field.options) { option in
                Button(option.name) { store.requestMove(itemID: row.id, destinationOptionID: option.id) }
                    .disabled(row.selectedOption?.id == option.id)
            }
            Divider()
            Button("No value") { store.requestMove(itemID: row.id, destinationOptionID: nil) }
                .disabled(!row.hasAnyValue)
        }
        .disabled(!store.movesAreEnabled)
    }

    /// Exact row value label that distinguishes removed options from a genuinely empty field.
    private func projectValueLabel(row: GitHubProjectBoardRow) -> some View {
        projectValueLabel(
            option: row.selectedOption,
            unavailableValue: row.hasUnavailableValue ? row.selectedValue : nil,
            isAmbiguous: row.hasAmbiguousValue
        )
    }

    /// Exact column value label shared by board headings and card accessibility.
    private func projectValueLabel(column: GitHubProjectBoardColumn) -> some View {
        projectValueLabel(
            option: column.option,
            unavailableValue: column.unavailableValue,
            isAmbiguous: column.representsAmbiguousValue
        )
    }

    /// Value label with semantic iconography rather than color-only meaning.
    private func projectValueLabel(
        option: GitHubProjectSingleSelectOption?,
        unavailableValue: GitHubProjectSingleSelectValue?,
        isAmbiguous: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if unavailableValue != nil || isAmbiguous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(option?.color.swiftUIColor ?? .secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(projectValueDisplayName(
                option: option,
                unavailableValue: unavailableValue,
                isAmbiguous: isAmbiguous
            ))
                .lineLimit(1)
        }
    }

    /// Compact drift count preserving a text label for assistive technology.
    private func driftLabel(_ findings: [GitHubProjectDriftFinding]) -> some View {
        let assessmentState = store.assessment?.state
        let hasKnownDrift = !findings.isEmpty
        return Label {
            Text(findings.count, format: .number)
        } icon: {
            Image(systemName: hasKnownDrift
                ? "exclamationmark.triangle.fill"
                : assessmentState == .complete ? "checkmark.circle" : "questionmark.circle")
                .foregroundStyle(hasKnownDrift ? Color.orange : Color.secondary)
        }
        .accessibilityLabel(driftAccessibilityLabel(findings))
    }

    /// Reusable narrow status band.
    private func statusRow(icon: String, text: String, color: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.07))
        .accessibilityElement(children: .combine)
    }

    /// Terminal mutation notice with explicit dismissal.
    private func dismissibleStatus(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
            Spacer()
            Button {
                store.clearMoveNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.07))
        .accessibilityElement(children: .contain)
    }

    /// Visible title with a provider-safe fallback for redacted or untitled content.
    private func itemDisplayTitle(_ row: GitHubProjectBoardRow) -> String {
        let title = row.item.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? row.item.content.referenceLabel : title
    }

    /// Complete board-card identity, including a useful fallback for unavailable content.
    private func boardCardAccessibilityLabel(
        row: GitHubProjectBoardRow,
        column: GitHubProjectBoardColumn
    ) -> String {
        String(
            format: String(localized: "%@, %@, %@, %@, %@"),
            locale: .current,
            itemDisplayTitle(row),
            row.item.content.referenceLabel,
            row.item.content.kind.displayName,
            column.displayName,
            driftAccessibilityLabel(row.findings)
        )
    }

    /// VoiceOver drift result that never presents incomplete evidence as an all-clear.
    private func driftAccessibilityLabel(_ findings: [GitHubProjectDriftFinding]) -> String {
        if !findings.isEmpty {
            let count = LocalizedCountText.driftFindings(findings.count)
            switch store.assessment?.state {
            case .partial:
                return String(
                    format: String(localized: "%@. Drift assessment incomplete."),
                    locale: .current,
                    count
                )
            case .configurationRequired:
                return String(
                    format: String(localized: "%@. Lifecycle policy requires configuration."),
                    locale: .current,
                    count
                )
            case .complete, nil:
                return count
            }
        }

        switch store.assessment?.state {
        case .complete: return String(localized: "No drift found")
        case .partial: return String(localized: "Drift assessment incomplete")
        case .configurationRequired: return String(localized: "Lifecycle policy requires configuration")
        case nil: return String(localized: "Drift assessment unavailable")
        }
    }

    /// Refresh control identity with both relative age and exact local capture time.
    private var refreshProjectAccessibilityLabel: String {
        guard let snapshot = store.snapshot else { return String(localized: "Refresh Project") }
        return String(
            format: String(localized: "Refresh Project. Snapshot age: %@. Captured: %@."),
            locale: .current,
            snapshot.capturedAt.formatted(.relative(presentation: .named)),
            snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    /// Retained-data failure copy that identifies exactly how old the shown snapshot is.
    private func staleSnapshotMessage(refreshFailure: String) -> String {
        guard let snapshot = store.snapshot else { return refreshFailure }
        return String(
            format: String(localized: "Showing snapshot captured %@ (%@). Refresh failed: %@"),
            locale: .current,
            snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened),
            snapshot.capturedAt.formatted(.relative(presentation: .named)),
            refreshFailure
        )
    }

    /// Highest-priority dynamic status for native VoiceOver live announcements.
    private var statusAnnouncement: String? {
        switch store.moveState {
        case .ambiguous:
            return ambiguousMoveStatusMessage
        case .failed(let message), .succeeded(let message):
            return message
        case .drifted:
            return String(localized: "Project state changed. Review the refreshed item.")
        case .preflighting:
            return String(localized: "Validating current Project state...")
        case .executing:
            return String(localized: "Applying Project move...")
        case .idle, .awaitingConfirmation:
            break
        }
        if case .failed(let message) = store.snapshotState {
            return staleSnapshotMessage(refreshFailure: message)
        }
        if case .failed(let message) = store.discoveryState { return message }
        if store.discoveryState == .loading || store.snapshotState == .loading {
            return String(localized: "Loading GitHub Projects...")
        }
        var persistentStatuses: [String] = []
        if store.assessment?.state == .configurationRequired {
            persistentStatuses.append(String(localized: "Lifecycle policy requires configuration"))
        } else if store.assessment?.state == .partial {
            persistentStatuses.append(String(localized: "Drift assessment is incomplete. Known findings are shown, but CodingBuddy cannot confirm an all-clear."))
        }
        if store.snapshot?.project.viewerCanUpdate == false {
            persistentStatuses.append(String(localized: "Read-only access. GitHub does not allow this account to update Project items."))
        }
        return persistentStatuses.isEmpty ? nil : persistentStatuses.joined(separator: " ")
    }

    /// Verification-specific copy whose loading and failure transitions retrigger VoiceOver.
    private var ambiguousMoveStatusMessage: String {
        switch store.snapshotState {
        case .loading:
            return String(localized: "Verifying Project move on GitHub...")
        case .failed(let message):
            return String(
                format: String(localized: "Project move remains unverified. GitHub verification failed: %@"),
                locale: .current,
                message
            )
        case .idle, .loaded:
            return String(localized: "Project move needs verification")
        }
    }

    /// Moves VoiceOver to the updated band and posts the native live announcement.
    private func focusAndAnnounceStatus() async {
        guard let announcement = statusAnnouncement else {
            statusBandFocused = false
            return
        }
        await Task.yield()
        guard statusAnnouncement == announcement else { return }
        statusBandFocused = true
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// Organization input bridge.
    private var organizationBinding: Binding<String> {
        Binding(get: { store.preferences.organizationLogin }, set: store.setOrganizationLogin)
    }

    /// Prevents source changes while one move is awaiting, executing, or verifying provider state.
    private var sourceControlsLocked: Bool {
        !store.moveState.allowsNewMove
    }

    /// Project selection bridge.
    private var projectBinding: Binding<String?> {
        Binding(
            get: { store.preferences.selectedProjectID },
            set: { if let id = $0 { store.selectProject(id: id) } }
        )
    }

    /// Field selection bridge.
    private var fieldBinding: Binding<String?> {
        Binding(
            get: { store.preferences.selectedFieldID },
            set: { if let id = $0 { store.selectField(id: id) } }
        )
    }

    /// Display-mode bridge.
    private var viewModeBinding: Binding<GitHubProjectViewMode> {
        Binding(get: { store.preferences.viewMode }, set: store.setViewMode)
    }

    /// Search bridge preserving all other filters.
    private var searchBinding: Binding<String> {
        Binding(get: { store.preferences.filter.searchText }) { value in
            var filter = store.preferences.filter
            filter.searchText = value
            store.setFilter(filter)
        }
    }

    /// Archived-item visibility bridge housed with the repository scope controls.
    private var archivedItemsBinding: Binding<Bool> {
        Binding {
            store.preferences.filter.includesArchived
        } set: { enabled in
            var filter = store.preferences.filter
            filter.includesArchived = enabled
            store.setFilter(filter)
        }
    }

    /// Whether local narrowing controls explain an otherwise non-empty snapshot.
    private var hasRestrictiveFilters: Bool {
        !store.preferences.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.preferences.filter.repositoryIDs.isEmpty
            || !store.preferences.filter.driftCategories.isEmpty
    }

    /// Restores the documented unfiltered, non-archived Project view.
    private func resetFilters() {
        store.setFilter(GitHubProjectBoardFilter())
    }

    /// Reveals archived-only snapshots without changing other local filters.
    private func showArchivedItems() {
        var filter = store.preferences.filter
        filter.includesArchived = true
        store.setFilter(filter)
    }

    /// One repository-toggle bridge.
    private func repositoryFilterBinding(_ repositoryID: String) -> Binding<Bool> {
        Binding {
            store.preferences.filter.repositoryIDs.contains(repositoryID)
        } set: { enabled in
            var filter = store.preferences.filter
            if enabled { filter.repositoryIDs.insert(repositoryID) }
            else { filter.repositoryIDs.remove(repositoryID) }
            store.setFilter(filter)
        }
    }

    /// One drift-category toggle bridge.
    private func driftFilterBinding(_ category: GitHubProjectDriftCategory) -> Binding<Bool> {
        Binding {
            store.preferences.filter.driftCategories.contains(category)
        } set: { enabled in
            var filter = store.preferences.filter
            if enabled { filter.driftCategories.insert(category) }
            else { filter.driftCategories.remove(category) }
            store.setFilter(filter)
        }
    }

    /// Confirmation visibility bridge that revokes the nonce on dismissal.
    private var pendingConfirmationBinding: Binding<Bool> {
        Binding {
            store.pendingPreflight != nil
        } set: { presented in
            if !presented, store.pendingPreflight != nil { store.cancelPendingMove() }
        }
    }

    /// Risk-specific confirmation copy.
    private var moveConfirmationMessage: String {
        guard let preflight = store.pendingPreflight else {
            return String(localized: "Review the current Project item before moving it.")
        }
        let field = store.snapshot?.fields.first { $0.id == preflight.intent.fieldID }
        let item = store.snapshot?.items.first { $0.id == preflight.intent.itemID }
        let itemName = item.map {
            let title = $0.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? $0.content.referenceLabel : title
        } ?? String(localized: "Unavailable item")
        let sourceValue = item?.singleSelectValue(fieldID: preflight.intent.fieldID)
        let current: String
        if let sourceOptionID = preflight.sourceOptionID {
            current = field?.options.first { $0.id == sourceOptionID }?.name
                ?? sourceValue.map { unavailableValueDisplayName(name: $0.name) }
                ?? unavailableValueDisplayName(name: sourceOptionID)
        } else {
            current = String(localized: "No value")
        }
        let destination: String
        if let destinationOptionID = preflight.intent.destinationOptionID {
            destination = field?.options.first { $0.id == destinationOptionID }?.name
                ?? unavailableValueDisplayName(name: destinationOptionID)
        } else {
            destination = String(localized: "No value")
        }
        let risk: String = switch preflight.risk {
        case .terminal: String(localized: "This move enters, leaves, or clears a terminal lifecycle state.")
        case .contradictory: String(localized: "This move conflicts with the current GitHub issue or pull request state.")
        case .unknown: String(localized: "GitHub evidence cannot classify this move safely.")
        case .routine: String(localized: "Review the current Project item before moving it.")
        }
        return String(
            format: String(localized: "Move “%@” from “%@” to “%@”. %@"),
            locale: .current,
            itemName,
            current,
            destination,
            risk
        )
    }

    /// Shared display semantics for current options, removed provider values, and true nil.
    private func projectValueDisplayName(
        option: GitHubProjectSingleSelectOption?,
        unavailableValue: GitHubProjectSingleSelectValue?,
        isAmbiguous: Bool = false
    ) -> String {
        if let option { return option.name }
        if let unavailableValue { return unavailableValueDisplayName(name: unavailableValue.name) }
        if isAmbiguous { return String(localized: "Unavailable value") }
        return String(localized: "No value")
    }

    /// Warning label for one provider value that is no longer selectable.
    private func unavailableValueDisplayName(name: String) -> String {
        String(
            format: String(localized: "Unavailable value: %@"),
            locale: .current,
            name
        )
    }
}

/// Evidence inspector for one selected Project row.
private struct GitHubProjectInspector: View {
    /// Selected shared row.
    let row: GitHubProjectBoardRow
    /// Overall assessment containing evidence gaps.
    let assessment: GitHubProjectDriftAssessment?
    /// Selected field.
    let field: GitHubProjectSingleSelectField
    /// Whether guarded moves can begin.
    let movesEnabled: Bool
    /// Guarded move route.
    let requestMove: (String, String?) -> Void
    /// Selected inspector section.
    @State private var section = Section.details

    /// Inspector sections optimized for scanning rather than nested cards.
    private enum Section: String, CaseIterable {
        /// Provider-backed item details.
        case details
        /// Detected planning drift.
        case drift
        /// Snapshot uncertainty and coverage gaps.
        case evidence

        /// Localized label.
        var label: String {
            switch self {
            case .details: String(localized: "Details")
            case .drift: String(localized: "Drift")
            case .evidence: String(localized: "Evidence")
            }
        }
    }

    /// Inspector content.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.item.content.title.isEmpty ? row.item.content.referenceLabel : row.item.content.title)
                .font(.headline)
                .textSelection(.enabled)
            Text(row.item.content.referenceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Inspector", selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch section {
                    case .details: details
                    case .drift: drift
                    case .evidence: evidence
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            Menu {
                ForEach(field.options) { option in
                    Button(option.name) { requestMove(row.id, option.id) }
                        .disabled(row.selectedOption?.id == option.id)
                }
                Divider()
                Button("No value") { requestMove(row.id, nil) }
                    .disabled(!row.hasAnyValue)
            } label: {
                Label("Move to", systemImage: "arrow.right")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!movesEnabled)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project item inspector")
    }

    /// Provider-backed item details.
    private var details: some View {
        Group {
            LabeledContent("Type", value: row.item.content.kind.displayName)
            LabeledContent("State", value: row.item.content.state.displayName)
            LabeledContent(field.name, value: selectedValueName)
            LabeledContent("Repository", value: row.item.content.repository?.displayName ?? String(localized: "Unavailable"))
            if let url = row.item.content.url {
                Link("Open on GitHub", destination: url)
            }
        }
    }

    /// Explainable findings for the selected item.
    @ViewBuilder
    private var drift: some View {
        if row.findings.isEmpty {
            switch assessment?.state {
            case .complete:
                Label("No drift found", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .partial:
                VStack(alignment: .leading, spacing: 3) {
                    Label("Drift assessment incomplete", systemImage: "questionmark.circle")
                    Text("Missing Project evidence means CodingBuddy cannot rule out drift.")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            case .configurationRequired:
                VStack(alignment: .leading, spacing: 3) {
                    Label("Lifecycle policy requires configuration", systemImage: "slider.horizontal.3")
                    Text("Assign every field option a lifecycle role before assessing drift or moving items.")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            case nil:
                Label("Drift assessment unavailable", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
            }
        } else {
            ForEach(row.findings) { finding in
                VStack(alignment: .leading, spacing: 3) {
                    Label(finding.title, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(finding.severity == .critical ? .red : .orange)
                    Text(finding.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
            }
        }
    }

    /// Snapshot and filter uncertainty relevant to this item.
    @ViewBuilder
    private var evidence: some View {
        if row.scopeMembership == .unknown {
            Label("Repository scope is unavailable", systemImage: "eye.slash")
                .foregroundStyle(.orange)
        }
        if !row.item.fieldValuesComplete {
            Label("Field values are incomplete", systemImage: "lock.fill")
                .foregroundStyle(.orange)
        }
        if row.hasUnavailableValue {
            Label("This field value is no longer available in the Project configuration.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if row.hasAmbiguousValue {
            Label("GitHub returned multiple values for this single-select field.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if !row.item.content.relationCoverage.isComplete {
            Label("Relationships are incomplete", systemImage: "lock.fill")
                .foregroundStyle(.orange)
        }
        ForEach(assessment?.evidenceGaps ?? [], id: \.self) { gap in
            Text(gap)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// Exact field value label that keeps a removed provider option distinct from true nil.
    private var selectedValueName: String {
        if let option = row.selectedOption { return option.name }
        if let value = row.selectedValue {
            return String(
                format: String(localized: "Unavailable value: %@"),
                locale: .current,
                value.name
            )
        }
        if row.hasAmbiguousValue { return String(localized: "Unavailable value") }
        return String(localized: "No value")
    }
}

/// Explicit stable-ID policy editor for lifecycle, relationship, and workflow rules.
private struct GitHubProjectPolicyView: View {
    /// Selected field definition.
    let field: GitHubProjectSingleSelectField
    /// Observable Project workflows available for explicit selection.
    let workflows: [GitHubProjectWorkflow]
    /// Whether absence from the field list proves that a saved option was removed.
    let fieldsComplete: Bool
    /// Whether absence from the workflow list proves that a saved workflow was removed.
    let workflowsComplete: Bool
    /// Saves the complete local-only policy.
    let save: (GitHubProjectDriftPolicy) -> Void
    /// Dismisses without changing the persisted policy.
    @Environment(\.dismiss) private var dismiss
    /// Editable local draft.
    @State private var draft: GitHubProjectDriftPolicy

    /// Creates a sheet-local policy draft.
    init(
        field: GitHubProjectSingleSelectField,
        workflows: [GitHubProjectWorkflow],
        fieldsComplete: Bool,
        workflowsComplete: Bool,
        policy: GitHubProjectDriftPolicy,
        save: @escaping (GitHubProjectDriftPolicy) -> Void
    ) {
        self.field = field
        self.workflows = workflows
        self.fieldsComplete = fieldsComplete
        self.workflowsComplete = workflowsComplete
        self.save = save
        _draft = State(initialValue: policy)
    }

    /// Native policy form.
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Lifecycle roles") {
                    ForEach(field.options) { option in
                        Picker(option.name, selection: roleBinding(option.id)) {
                            Text("Not classified").tag(GitHubProjectLifecycleRole?.none)
                            ForEach(GitHubProjectLifecycleRole.allCases, id: \.self) { role in
                                Text(role.displayName).tag(Optional(role))
                            }
                        }
                    }
                }
                if hasUnavailableReferences {
                    Section("Unavailable references") {
                        Text("This policy still references Project options or workflows that GitHub no longer provides. Saving removes these references.")
                            .foregroundStyle(.secondary)
                        ForEach(staleOptionIDs, id: \.self) { optionID in
                            LabeledContent("Removed field option", value: optionID)
                        }
                        ForEach(staleWorkflowIDs, id: \.self) { workflowID in
                            LabeledContent("Removed workflow", value: workflowID)
                        }
                        Button("Remove unavailable references", systemImage: "trash") {
                            removeUnavailableReferences()
                        }
                    }
                }
                if !fieldsComplete || !workflowsComplete {
                    Section("Incomplete policy evidence") {
                        Text("GitHub returned an incomplete field or workflow list. Missing policy references are preserved until a complete refresh proves they were removed.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Relationship rules") {
                    Toggle("Require related items in this Project", isOn: $draft.requiresRelatedItemsInProject)
                        .toggleStyle(.checkbox)
                    Toggle("Require a closing issue for pull requests", isOn: $draft.requiresClosingIssueForPullRequest)
                        .toggleStyle(.checkbox)
                    Toggle("Flag active parents when every child is terminal", isOn: $draft.completeParentWhenChildrenTerminal)
                        .toggleStyle(.checkbox)
                }
                Section("Required automations") {
                    if workflows.isEmpty {
                        Text("No Project workflows available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workflows) { workflow in
                            Toggle(isOn: workflowBinding(workflow.id)) {
                                HStack {
                                    Text(workflow.name)
                                    if !workflow.isEnabled {
                                        Text("Disabled")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(sanitizedDraft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    /// Optional role binding backed by stable option ID.
    private func roleBinding(_ optionID: String) -> Binding<GitHubProjectLifecycleRole?> {
        Binding {
            draft.roleByOptionID[optionID]
        } set: { role in
            draft.roleByOptionID[optionID] = role
        }
    }

    /// Explicit expected-workflow toggle backed by stable provider ID.
    private func workflowBinding(_ workflowID: String) -> Binding<Bool> {
        Binding {
            draft.expectedWorkflowIDs.contains(workflowID)
        } set: { enabled in
            if enabled { draft.expectedWorkflowIDs.insert(workflowID) }
            else { draft.expectedWorkflowIDs.remove(workflowID) }
        }
    }

    /// Removed option IDs retained by an older provider configuration.
    private var staleOptionIDs: [String] {
        guard fieldsComplete else { return [] }
        let currentIDs = Set(field.options.map(\.id))
        return draft.roleByOptionID.keys.filter { !currentIDs.contains($0) }.sorted()
    }

    /// Removed workflow IDs retained by an older provider configuration.
    private var staleWorkflowIDs: [String] {
        guard workflowsComplete else { return [] }
        let currentIDs = Set(workflows.map(\.id))
        return draft.expectedWorkflowIDs.filter { !currentIDs.contains($0) }.sorted()
    }

    /// Whether the draft contains provider identities that can no longer be selected.
    private var hasUnavailableReferences: Bool {
        !staleOptionIDs.isEmpty || !staleWorkflowIDs.isEmpty
    }

    /// Save-time fail-safe that cannot persist stale provider identities from this editor.
    private var sanitizedDraft: GitHubProjectDriftPolicy {
        let currentOptionIDs = Set(field.options.map(\.id))
        let currentWorkflowIDs = Set(workflows.map(\.id))
        return draft.removingUnavailableReferences(
            currentOptionIDs: currentOptionIDs,
            currentWorkflowIDs: currentWorkflowIDs,
            fieldsComplete: fieldsComplete,
            workflowsComplete: workflowsComplete
        )
    }

    /// Applies the same repair immediately so the user can review the resulting draft.
    private func removeUnavailableReferences() {
        draft = sanitizedDraft
    }
}

private extension GitHubProjectContentKind {
    /// Native symbol for compact table scanning.
    var systemImage: String {
        switch self {
        case .issue: "record.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .draftIssue: "doc.text"
        case .redacted: "eye.slash"
        }
    }
}

private extension GitHubProjectOptionColor {
    /// Semantic SwiftUI color used by Project option swatches.
    var swiftUIColor: Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        }
    }
}

private extension GitHubProjectMoveState {
    /// Whether the state is the verified-success terminal notice.
    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
