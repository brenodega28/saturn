import SaturnCore
import SaturnUI
import SwiftUI

struct StepAddition: Identifiable {
    let id: String
    let title: String
    let type: StepType
    let role: RoleDefinition?

    static func roleItems(_ roles: [RoleDefinition]) -> [StepAddition] {
        roles.map { StepAddition(id: "role-\($0.id)", title: $0.name, type: .agent, role: $0) }
    }

    static var typeItems: [StepAddition] {
        StepType.allCases.map { StepAddition(id: "type-\($0.rawValue)", title: $0.paletteTitle, type: $0, role: nil) }
    }

    @MainActor
    func add(to editor: WorkflowEditor) {
        editor.addStep(type, role: role, at: nil)
    }
}

struct AddStepMenu: View {
    let roles: [RoleDefinition]
    let editor: WorkflowEditor

    var body: some View {
        Menu {
            Section("Agent step done by") {
                ForEach(StepAddition.roleItems(roles)) { item in
                    Button(item.title) { item.add(to: editor) }
                }
            }
            Section("Steps") {
                ForEach(StepAddition.typeItems) { item in
                    Button {
                        item.add(to: editor)
                    } label: {
                        Label(item.title, systemImage: item.type.paletteSymbol)
                    }
                    .help(item.type.paletteHelp)
                }
            }
        } label: {
            Label("Add step", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Add a step done by the Lead, a builder or a checker, or a parallel build, condition, approval or notify step")
    }
}

struct WorkflowListMenu: View {
    let config: ProjectConfig
    let editor: WorkflowEditor?
    let hasConfig: Bool
    let open: (WorkflowDefinition) -> Void
    let newBlank: () -> Void
    let duplicate: (WorkflowDefinition) -> Void
    let delete: (WorkflowDefinition) -> Void

    var body: some View {
        Menu {
            Section("Workflows") {
                if let editor, editor.isNew {
                    Button {} label: {
                        Label("\(editor.draft.name) (not saved)", systemImage: "checkmark")
                    }
                    .disabled(true)
                }
                ForEach(config.workflows) { workflow in
                    Button {
                        open(workflow)
                    } label: {
                        if isCurrent(workflow) {
                            Label(rowTitle(workflow), systemImage: "checkmark")
                        } else {
                            Text(rowTitle(workflow))
                        }
                    }
                }
                if config.workflows.isEmpty && editor?.isNew != true {
                    Text("No workflows yet")
                }
            }
            Section {
                Button("New blank workflow", action: newBlank)
                if let current = editor?.draft {
                    Button("Duplicate “\(current.name)”") { duplicate(current) }
                }
                if let editor, !editor.isNew, let current = editor.saved {
                    Button("Delete “\(current.name)”…", role: .destructive) { delete(current) }
                }
            }
            if !unreadable.isEmpty {
                Section("Couldn’t read") {
                    ForEach(Array(unreadable.enumerated()), id: \.offset) { _, issue in
                        Text("\((issue.file as NSString).lastPathComponent): \(issue.message)")
                    }
                }
            }
            if !hasConfig {
                Section {
                    Text("No .saturn/ folder yet. Add the default workflows.")
                }
            }
        } label: {
            Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Switch workflow, start a new one, duplicate or delete this one")
    }

    private func isCurrent(_ workflow: WorkflowDefinition) -> Bool {
        editor?.isNew == false && editor?.saved?.id == workflow.id
    }

    private func rowTitle(_ workflow: WorkflowDefinition) -> String {
        let problems = issueCount(workflow)
        let suffix = problems > 0 ? " · \(problems) problem\(problems == 1 ? "" : "s")" : ""
        return "\(workflow.name)  v\(workflow.version)\(suffix)"
    }

    private func issueCount(_ workflow: WorkflowDefinition) -> Int {
        config.issueCount(forWorkflow: workflow.id)
    }

    private var unreadable: [ConfigIssue] {
        config.unreadableWorkflowIssues
    }
}

extension ProjectConfig {
    func issueCount(forWorkflow id: String) -> Int {
        issues.filter { $0.file.hasSuffix("/workflows/\(id).yaml") || $0.file.hasSuffix("/workflows/\(id).yml") }.count
    }

    var unreadableWorkflowIssues: [ConfigIssue] {
        let known = Set(workflows.flatMap { ["\(ProjectConfig.directoryName)/workflows/\($0.id).yaml", "\(ProjectConfig.directoryName)/workflows/\($0.id).yml"] })
        return issues.filter { $0.file.contains("/workflows/") && !known.contains($0.file) }
    }
}
