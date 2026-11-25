import SaturnCore
import SaturnUI
import SwiftUI

struct WorkflowsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var editor: WorkflowEditor?
    @State private var pendingAction: PendingAction?
    @State private var isConfirmingDelete = false
    @State private var isTestRunPresented = false
    @State private var isHistoryPresented = false
    @State private var isInspectorPanelOpen = false
    @AppStorage("workflowStepsLayout") private var stepsLayout = StepsLayout.list

    private struct PendingAction: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }

    var body: some View {
        let config = workspace.config(for: project)
        VStack(alignment: .leading, spacing: 18) {
            intro(config: config)
            layout(config: config)
        }
        .onAppear {
            openFirst(in: config)
            takeTestRunRequest(config: config)
        }
        .onChange(of: model.testRunRequest) { takeTestRunRequest(config: workspace.config(for: project)) }
        .onChange(of: model.workflowMenuAction, initial: true) { takeMenuAction(config: workspace.config(for: project)) }
        .onChange(of: project.id) { _, _ in
            editor = nil
            openFirst(in: workspace.config(for: project))
        }
        .onChange(of: editor.map(ObjectIdentifier.init), initial: true) {
            if let id = project.id { workspace.workflowEditors[id] = editor }
        }
        .onChange(of: editor?.selection) { _, selection in
            isInspectorPanelOpen = selection != nil && selection != .workflow
        }
        .onChange(of: editor?.report != nil || editor?.errorMessage != nil) { _, hasNews in
            if hasNews { isInspectorPanelOpen = true }
        }
        .confirmationDialog("Discard unsaved changes to “\(editor?.draft.name ?? "")”?", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("Discard Changes", role: .destructive) {
                pendingAction = nil
                action.perform()
            }
            Button("Keep Editing", role: .cancel) { pendingAction = nil }
        }
        .confirmationDialog("Delete “\(editor?.draft.name ?? "workflow")”?", isPresented: $isConfirmingDelete) {
            Button("Delete Workflow", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes .saturn/workflows/\(editor?.draft.id ?? "").yaml. Runs already in flight keep the version they started with.")
        }
    }

    private func intro(config: ProjectConfig) -> some View {
        SectionIntro(title: "Workflows", subtitle: subtitle(config: config)) {
            if let editor {
                headerActions(editor, issueCount: workspace.workflowIssues(editor, config: config).count)
            } else {
                Button("New workflow") { newWorkflow(from: nil, config: config) }
                    .buttonStyle(CompactPrimaryPillStyle())
            }
        }
    }

    private func subtitle(config: ProjectConfig) -> String {
        let base = "How a chat moves from your request to main. Each chat picks one"
        guard let name = config.defaultWorkflowDefinition?.name else { return base + "." }
        return base + "; \(name) is the default."
    }

    private func layout(config: ProjectConfig) -> some View {
        GeometryReader { proxy in
            let mode = WorkflowsLayoutMode(width: proxy.size.width)
            HStack(alignment: .top, spacing: WorkflowsLayoutMode.columnSpacing) {
                if mode.showsSidebar {
                    WorkflowSidebar(
                        config: config,
                        editor: editor,
                        hasConfig: workspace.hasConfig(project),
                        project: project,
                        open: openFromList,
                        newBlank: { newBlank(config: config) },
                        duplicate: { duplicate($0, config: config) },
                        delete: confirmDelete
                    )
                    .frame(width: WorkflowsLayoutMode.sidebarWidth)
                }
                if let editor {
                    editorArea(editor, config: config, mode: mode, height: proxy.size.height)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !mode.showsSidebar {
                            workflowMenu(config: config)
                        }
                        EmptyState("No workflow selected", message: "Workflows live in .saturn/workflows/ in this repository, versioned with your code. Pick one, or start a new one.") {
                            Button("New workflow") { newWorkflow(from: nil, config: config) }
                                .buttonStyle(CompactPrimaryPillStyle())
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func steps(_ editor: WorkflowEditor, roles: [RoleDefinition]) -> some View {
        switch stepsLayout {
        case .list: WorkflowStepList(editor: editor, roles: roles)
        case .canvas: WorkflowCanvas(editor: editor, roles: roles)
        }
    }

    private func openFromList(_ workflow: WorkflowDefinition) {
        guard editor?.isNew == true || editor?.saved?.id != workflow.id else { return }
        confirmLeaving { open(workflow, isNew: false) }
    }

    private func newBlank(config: ProjectConfig) {
        confirmLeaving { newWorkflow(from: nil, config: config) }
    }

    private func duplicate(_ workflow: WorkflowDefinition, config: ProjectConfig) {
        confirmLeaving { newWorkflow(from: workflow, config: config) }
    }

    private func confirmDelete(_ workflow: WorkflowDefinition) {
        confirmLeaving {
            open(workflow, isNew: false)
            isConfirmingDelete = true
        }
    }

    private func workflowMenu(config: ProjectConfig) -> some View {
        WorkflowListMenu(
            config: config,
            editor: editor,
            hasConfig: workspace.hasConfig(project),
            open: openFromList,
            newBlank: { newBlank(config: config) },
            duplicate: { duplicate($0, config: config) },
            delete: confirmDelete
        )
    }

    private func editorArea(_ editor: WorkflowEditor, config: ProjectConfig, mode: WorkflowsLayoutMode, height: CGFloat) -> some View {
        let issues = workspace.workflowIssues(editor, config: config)
        let runs = editor.saved.map { workspace.activeRuns(ofWorkflow: $0.id, in: project) } ?? []
        let inspector = WorkflowInspector(
            editor: editor,
            roles: config.roles,
            agents: config.agents,
            checks: config.checks?.checks ?? [],
            issues: issues,
            activeRuns: runs,
            suggestedLabels: workspace.suggestedWorkflowLabels(config, project: project)
        )
        return HStack(alignment: .top, spacing: WorkflowsLayoutMode.columnSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                header(editor, config: config, mode: mode)
                if mode.showsInspectorColumn {
                    steps(editor, roles: config.roles)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CanvasWithInspectorPanel(
                        editor: editor,
                        isPanelOpen: isInspectorPanelOpen,
                        panelHeight: max(220, min(440, height * 0.45)),
                        closePanel: { closeInspectorPanel(editor) },
                        canvas: { steps(editor, roles: config.roles) },
                        inspector: { inspector }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)
            if mode.showsInspectorColumn {
                inspector
                    .frame(width: WorkflowsLayoutMode.inspectorWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isTestRunPresented) {
            TestRunSheet(editor: editor)
        }
    }

    private func closeInspectorPanel(_ editor: WorkflowEditor) {
        isInspectorPanelOpen = false
        editor.select(.workflow)
    }

    private func header(_ editor: WorkflowEditor, config: ProjectConfig, mode: WorkflowsLayoutMode) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                nameAndStatus(editor)
                Spacer(minLength: 12)
                editingTools(editor, config: config, mode: mode)
            }
            VStack(alignment: .leading, spacing: 8) {
                nameAndStatus(editor)
                editingTools(editor, config: config, mode: mode)
            }
        }
    }

    private func nameAndStatus(_ editor: WorkflowEditor) -> some View {
        HStack(spacing: 8) {
            Text(editor.draft.name.isEmpty ? "Untitled workflow" : editor.draft.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .help(editor.draft.name)
            Button {
                isHistoryPresented.toggle()
            } label: {
                Text("v\(editor.draft.version) · History")
                    .font(Tokens.mono(11.5))
                    .foregroundStyle(Tokens.text2)
            }
            .buttonStyle(.plain)
            .disabled(editor.isNew)
            .fixedSize()
            .help("Earlier versions, with their runs and average cost. Running tasks keep the version they started with.")
            .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                WorkflowHistoryView(project: project, editor: editor) { isHistoryPresented = false }
            }
            Button {
                editor.select(.trigger)
            } label: {
                TagPill(text: editor.draft.trigger.summary, color: Tokens.done, background: Tokens.doneBackground)
            }
            .buttonStyle(.plain)
            .help("Edit what starts this workflow")
            if editor.isDirty {
                TagPill(text: editor.isNew ? "Not saved" : editor.willBumpVersion ? "Edited · saves as v\(editor.nextVersion)" : "Layout edited", color: Tokens.need, background: Tokens.needBackground)
            }
        }
    }

    private func editingTools(_ editor: WorkflowEditor, config: ProjectConfig, mode: WorkflowsLayoutMode) -> some View {
        HStack(spacing: 8) {
            if !mode.showsSidebar {
                workflowMenu(config: config)
            }
            CapsuleTabs(StepsLayout.allCases, selection: $stepsLayout, title: \.title)
                .fixedSize()
                .help("Show the steps as a list, or as a canvas you can drag and connect")
            AddStepMenu(roles: config.roles, editor: editor)
            if !mode.showsInspectorColumn {
                Toggle(isOn: Binding(
                    get: { isInspectorPanelOpen },
                    set: { isOpen in
                        if isOpen { isInspectorPanelOpen = true } else { closeInspectorPanel(editor) }
                    }
                )) {
                    Label("Inspector", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .toggleStyle(.button)
                .fixedSize()
                .help("Show the settings for the selected step, or for the whole workflow")
            }
        }
    }

    private func headerActions(_ editor: WorkflowEditor, issueCount: Int) -> some View {
        HStack(spacing: 8) {
            if !editor.isNew {
                Button("Revert") { editor.revert() }
                    .buttonStyle(CompactSecondaryPillStyle())
                    .disabled(!editor.isDirty)
                    .help("Throw away unsaved changes")
            }
            Button {
                if editor.script.outcomes.keys.contains(where: { editor.draft.step($0) == nil }) {
                    editor.script.outcomes = editor.script.outcomes.filter { editor.draft.step($0.key) != nil }
                }
                isTestRunPresented = true
            } label: {
                Label("Test run", systemImage: "play.fill")
            }
            .buttonStyle(CompactSecondaryPillStyle())
            .disabled(editor.draft.steps.isEmpty)
            .help("Dry-run this workflow on a sample task with every agent stubbed")
            if !editor.isNew, editor.isDirty, editor.nextVersion != editor.draft.version {
                TextField("What changed?", text: Binding(get: { editor.changeNote }, set: { editor.changeNote = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .help("A short note for the version history")
            }
            Button(!editor.isNew && editor.isDirty && editor.nextVersion != editor.draft.version ? "Save as v\(editor.nextVersion)" : "Save") { save(editor) }
                .buttonStyle(CompactPrimaryPillStyle())
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty || editor.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(issueCount > 0 ? "Save anyway; the problems are listed in the inspector" : "Write the workflow to .saturn/workflows")
        }
    }

    private func confirmLeaving(_ action: @escaping () -> Void) {
        if editor?.isDirty == true {
            pendingAction = PendingAction(perform: action)
        } else {
            action()
        }
    }

    private func open(_ workflow: WorkflowDefinition, isNew: Bool) {
        if !isNew, let editor, !editor.isNew, editor.saved?.id == workflow.id { return }
        editor = WorkflowEditor(workflow: workflow, isNew: isNew)
    }

    private func takeTestRunRequest(config: ProjectConfig) {
        guard let request = model.testRunRequest, request.project == workspace.ref(of: project), let workflow = config.workflow(request.workflow) else { return }
        model.testRunRequest = nil
        confirmLeaving {
            open(workflow, isNew: false)
            isTestRunPresented = true
        }
    }

    private func takeMenuAction(config: ProjectConfig) {
        guard let action = model.workflowMenuAction, action.project == workspace.ref(of: project) else { return }
        model.workflowMenuAction = nil
        switch action.kind {
        case .newWorkflow: newBlank(config: config)
        case .history: isHistoryPresented = editor != nil
        }
    }

    private func openFirst(in config: ProjectConfig) {
        guard editor == nil, let first = config.workflows.first else { return }
        open(first, isNew: false)
    }

    private func newWorkflow(from source: WorkflowDefinition?, config: ProjectConfig) {
        let name = source.map { "\($0.name) copy" } ?? "New workflow"
        let id = ProjectConfigLoader.newWorkflowID(for: name, existing: config.workflows)
        let workflow = source?.duplicated(id: id, name: name) ?? .blank(id: id, name: name)
        open(workflow, isNew: true)
    }

    private func save(_ editor: WorkflowEditor) {
        let config = workspace.config(for: project)
        var draft = editor.draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if editor.isNew {
            draft.id = ProjectConfigLoader.newWorkflowID(for: draft.name, existing: config.workflows)
        }
        do {
            let written = try workspace.saveWorkflow(draft, comparedTo: editor.saved, note: editor.changeNote, in: project)
            editor.markSaved(written)
            editor.errorMessage = nil
        } catch {
            editor.errorMessage = "Couldn’t save the workflow: \(error.localizedDescription)"
        }
    }

    private func deleteCurrent() {
        guard let editor else { return }
        if editor.isNew {
            self.editor = nil
            openFirst(in: workspace.config(for: project))
            return
        }
        do {
            try workspace.deleteWorkflow(editor.draft.id, in: project)
            self.editor = nil
            openFirst(in: workspace.config(for: project))
        } catch {
            editor.errorMessage = "Couldn’t delete the workflow: \(error.localizedDescription)"
        }
    }
}

private struct WorkflowSidebar: View {
    let config: ProjectConfig
    let editor: WorkflowEditor?
    let hasConfig: Bool
    let project: Project
    let open: (WorkflowDefinition) -> Void
    let newBlank: () -> Void
    let duplicate: (WorkflowDefinition) -> Void
    let delete: (WorkflowDefinition) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workflows
                if !hasConfig {
                    Text("This project has no .saturn/ folder yet. Add the default workflows, or start a new one.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
                if let editor {
                    Rectangle().fill(Tokens.hair).frame(height: 1).padding(.horizontal, 12)
                    RolePaletteList(roles: config.roles, editor: editor)
                    StepPalette(editor: editor)
                }
            }
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
    }

    private var workflows: some View {
        VStack(alignment: .leading, spacing: 2) {
            IssueList(issues: config.unreadableWorkflowIssues)
            if let editor, editor.isNew {
                row(name: editor.draft.name, detail: "Not saved · \(editor.draft.steps.count) steps", isDefault: false, issueCount: 0, isSelected: true) {}
            }
            let defaultID = config.defaultWorkflowDefinition?.id
            ForEach(config.workflows) { workflow in
                let isSelected = editor?.isNew == false && editor?.saved?.id == workflow.id
                row(name: workflow.name, detail: detail(of: workflow), isDefault: workflow.id == defaultID, issueCount: config.issueCount(forWorkflow: workflow.id), isSelected: isSelected) {
                    open(workflow)
                }
                .contextMenu {
                    Button("Duplicate") { duplicate(workflow) }
                    Button("Delete…", role: .destructive) { delete(workflow) }
                }
            }
            if config.workflows.isEmpty && editor?.isNew != true {
                Text("No workflows yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text2)
                    .padding(.horizontal, 12)
            }
            Menu {
                Button("Blank workflow", action: newBlank)
                if let current = editor?.draft {
                    Button("Duplicate “\(current.name)”") { duplicate(current) }
                }
            } label: {
                Text("+ New workflow").font(.system(size: 12.5)).foregroundStyle(Tokens.link)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .help("New workflow, from blank or by duplicating this one")
            if let editor, !editor.isNew, let current = editor.saved {
                Button("Delete “\(current.name)”…", role: .destructive) { delete(current) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.danger.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .help("Remove this workflow’s YAML file")
            }
        }
    }

    private func detail(of workflow: WorkflowDefinition) -> String {
        let summary = workflow.description.split(whereSeparator: \.isNewline).first.map(String.init)
        return summary ?? "v\(workflow.version) · \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")"
    }

    private func row(name: String, detail: String, isDefault: Bool, issueCount: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                        if isDefault {
                            Text("Default").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.accent)
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(Tokens.text2).lineLimit(2)
                }
                Spacer(minLength: 4)
                if issueCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.need)
                        .accessibilityLabel("\(issueCount) problem\(issueCount == 1 ? "" : "s")")
                        .help("\(issueCount) problem\(issueCount == 1 ? "" : "s") in this workflow")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Tokens.selection : Color.clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RolePaletteList: View {
    let roles: [RoleDefinition]
    @Bindable var editor: WorkflowEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 10)
            Text("Click to add, or drag onto the canvas")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(roles) { role in
                let uses = editor.draft.steps.filter { $0.agent?.rawValue == role.id }.count
                PaletteRow(payload: PaletteItem.role(role.id).payload, help: "Add an agent step done by \(role.name)") {
                    editor.addStep(.agent, role: role, at: nil)
                } icon: {
                    AgentAvatar(size: 22, appearance: RoleAppearance(role: role))
                } title: {
                    Text(role.name)
                } trailing: {
                    if uses > 0 {
                        Text("\(uses) step\(uses == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
    }
}

private struct StepPalette: View {
    @Bindable var editor: WorkflowEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steps").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(StepType.allCases, id: \.self) { type in
                PaletteRow(payload: PaletteItem.type(type).payload, help: type.paletteHelp) {
                    editor.addStep(type, role: nil, at: nil)
                } icon: {
                    Image(systemName: type.paletteSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(type.paletteColor)
                        .frame(width: 22, height: 22)
                        .background(Tokens.fill, in: .rect(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                } title: {
                    Text(type.paletteTitle)
                } trailing: {
                    EmptyView()
                }
            }
        }
    }
}

private struct PaletteRow<Icon: View, Title: View, Trailing: View>: View {
    let payload: String
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                title.font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                trailing
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Tokens.hover, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .draggable(payload) {
            HStack(spacing: 8) {
                icon
                title.font(.system(size: 13))
            }
            .padding(8)
            .background(Tokens.menu, in: .rect(cornerRadius: 9))
        }
        .help(help)
    }
}

struct CanvasWithInspectorPanel<Canvas: View, Inspector: View>: View {
    let editor: WorkflowEditor
    let isPanelOpen: Bool
    let panelHeight: CGFloat
    let closePanel: () -> Void
    @ViewBuilder let canvas: Canvas
    @ViewBuilder let inspector: Inspector

    var body: some View {
        VStack(spacing: 12) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if isPanelOpen {
                InspectorPanel(title: panelTitle, close: closePanel) {
                    inspector
                }
                .frame(height: panelHeight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isPanelOpen)
    }

    private var panelTitle: String {
        switch editor.selection {
        case .workflow: "Workflow settings"
        case .trigger: "Trigger"
        case .end: "End"
        case .step: editor.selectedStep?.title ?? "Step"
        }
    }
}

private struct InspectorPanel<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Close inspector")
                .help("Close the inspector")
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .raisedCard()
    }
}
