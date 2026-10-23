import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkflowsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var editor: WorkflowEditor?
    @State private var pendingAction: PendingAction?
    @State private var isConfirmingDelete = false
    @State private var isTestRunPresented = false

    private struct PendingAction: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }

    var body: some View {
        let config = model.config(for: project)
        HStack(alignment: .top, spacing: 14) {
            WorkflowSidebar(
                config: config,
                editor: editor,
                hasConfig: model.hasConfig(project),
                project: project,
                open: { workflow in
                    guard editor?.isNew == true || editor?.saved?.id != workflow.id else { return }
                    confirmLeaving { open(workflow, isNew: false) }
                },
                newBlank: { confirmLeaving { newWorkflow(from: nil, config: config) } },
                duplicate: { workflow in confirmLeaving { newWorkflow(from: workflow, config: config) } },
                delete: { workflow in
                    confirmLeaving {
                        open(workflow, isNew: false)
                        isConfirmingDelete = true
                    }
                }
            )
            .frame(width: 236)
            if let editor {
                editorArea(editor, config: config)
            } else {
                EmptyState("No workflow selected", message: "Workflows live in .ensemble/workflows/ in this repository, versioned with your code. Pick one, or start a new one.") {
                    Button("New workflow") { newWorkflow(from: nil, config: config) }
                        .buttonStyle(.primaryPill)
                }
            }
        }
        .onAppear { openFirst(in: config) }
        .onChange(of: project.id) { _, _ in
            editor = nil
            openFirst(in: model.config(for: project))
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
            Text("Removes .ensemble/workflows/\(editor?.draft.id ?? "").yaml. Runs already in flight keep the version they started with.")
        }
    }

    private func editorArea(_ editor: WorkflowEditor, config: ProjectConfig) -> some View {
        let issues = liveIssues(editor, config: config)
        let runs = editor.saved.map { model.activeRuns(ofWorkflow: $0.id, in: project) } ?? []
        return VStack(alignment: .leading, spacing: 12) {
            header(editor, issueCount: issues.count)
            HStack(alignment: .top, spacing: 14) {
                WorkflowCanvas(editor: editor, roles: config.roles)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                WorkflowInspector(
                    editor: editor,
                    roles: config.roles,
                    issues: issues,
                    activeRuns: runs,
                    suggestedLabels: suggestedLabels(config)
                )
                .frame(width: 310)
            }
        }
        .sheet(isPresented: $isTestRunPresented) {
            TestRunSheet(editor: editor)
        }
    }

    private func header(_ editor: WorkflowEditor, issueCount: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(editor.draft.name.isEmpty ? "Untitled workflow" : editor.draft.name)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("v\(editor.draft.version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                    if editor.isDirty {
                        Text(editor.isNew ? "Not saved" : editor.willBumpVersion ? "Edited · saves as v\(editor.nextVersion)" : "Layout edited")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Button {
                    editor.select(.trigger)
                } label: {
                    Text(editor.draft.trigger.summary)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.successText)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Theme.success.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Edit what starts this workflow")
            }
            Spacer(minLength: 12)
            if !editor.isNew {
                Button("Revert") { editor.revert() }
                    .buttonStyle(.pill)
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
            .buttonStyle(.pill)
            .disabled(editor.draft.steps.isEmpty)
            .help("Dry-run this workflow on a sample task with every agent stubbed")
            Button("Save") { save(editor) }
                .buttonStyle(.primaryPill)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty || editor.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(issueCount > 0 ? "Save anyway; the problems are listed in the inspector" : "Write the workflow to .ensemble/workflows")
        }
    }

    private func liveIssues(_ editor: WorkflowEditor, config: ProjectConfig) -> [ConfigIssue] {
        var draft = editor.draft
        if editor.isNew {
            draft.id = ProjectConfigLoader.newWorkflowID(for: draft.name, existing: config.workflows)
        }
        var issues = ConfigValidator.validate(ProjectConfig(roles: config.roles, workflows: [draft]))
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ConfigIssue(file: "", message: "a workflow needs a name"))
        }
        return issues
    }

    private func suggestedLabels(_ config: ProjectConfig) -> [String] {
        let labels = config.workflows.flatMap(\.trigger.labels) + project.settings.githubMappings.map(\.label)
        return Array(Set(labels)).sorted()
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
        let config = model.config(for: project)
        var draft = editor.draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if editor.isNew {
            draft.id = ProjectConfigLoader.newWorkflowID(for: draft.name, existing: config.workflows)
        }
        do {
            let written = try model.saveWorkflow(draft, comparedTo: editor.saved, in: project)
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
            openFirst(in: model.config(for: project))
            return
        }
        do {
            try model.deleteWorkflow(editor.draft.id, in: project)
            self.editor = nil
            openFirst(in: model.config(for: project))
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
                    Text("This project has no .ensemble/ folder yet. Add the defaults in Settings › Roles, or start a new workflow.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                }
                if let editor {
                    RolePaletteList(roles: config.roles, editor: editor)
                    StepPalette(editor: editor)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
        .card(cornerRadius: 18)
    }

    private var workflows: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Workflows").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Menu {
                    Button("Blank workflow", action: newBlank)
                    if let current = editor?.draft {
                        Button("Duplicate “\(current.name)”") { duplicate(current) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("New workflow")
                .help("New workflow, from blank or by duplicating this one")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            IssueList(issues: unreadable)
            if let editor, editor.isNew {
                row(name: editor.draft.name, detail: "Not saved · \(editor.draft.steps.count) steps", issueCount: 0, isSelected: true) {}
            }
            ForEach(config.workflows) { workflow in
                let isSelected = editor?.isNew == false && editor?.saved?.id == workflow.id
                let issueCount = config.issues.filter { $0.file.hasSuffix("/workflows/\(workflow.id).yaml") || $0.file.hasSuffix("/workflows/\(workflow.id).yml") }.count
                row(name: workflow.name, detail: "v\(workflow.version) · \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")", issueCount: issueCount, isSelected: isSelected) {
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
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
            }
            if let editor, !editor.isNew, let current = editor.saved {
                Button("Delete “\(current.name)”…", role: .destructive) { delete(current) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .help("Remove this workflow’s YAML file")
            }
        }
    }

    private var unreadable: [ConfigIssue] {
        let known = Set(config.workflows.flatMap { ["\(ProjectConfig.directoryName)/workflows/\($0.id).yaml", "\(ProjectConfig.directoryName)/workflows/\($0.id).yml"] })
        return config.issues.filter { $0.file.contains("/workflows/") && !known.contains($0.file) }
    }

    private func row(name: String, detail: String, issueCount: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.link : Theme.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if issueCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("\(issueCount) problem\(issueCount == 1 ? "" : "s")")
                        .help("\(issueCount) problem\(issueCount == 1 ? "" : "s") in this workflow")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.accent.opacity(0.28) : Color.clear, in: .rect(cornerRadius: 9, style: .continuous))
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
            Text("Roles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText).padding(.horizontal, 10)
            Text("Click to add, or drag onto the canvas")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if roles.isEmpty {
                Text("No roles in .ensemble/roles yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
            }
            ForEach(roles) { role in
                let uses = editor.draft.steps.filter { $0.role == role.id }.count
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
                        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 7, style: .continuous))
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
            .background(Color.white.opacity(0.035), in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .draggable(payload) {
            HStack(spacing: 8) {
                icon
                title.font(.system(size: 13))
            }
            .padding(8)
            .background(Color(hex: 0x2A2A30), in: .rect(cornerRadius: 9))
        }
        .help(help)
    }
}
