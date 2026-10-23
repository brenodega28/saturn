import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadComposer: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var text = ""
    @State private var leadID: String?
    @State private var workflowID: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let leads = model.leadRoles(in: project)
        let workflows = model.config(for: project).workflows
        let lead = leads.first { $0.id == leadID } ?? leads.first
        let workflow = workflows.first { $0.id == workflowID } ?? workflows.first
        VStack(alignment: .leading, spacing: 10) {
            TextField("Describe a new task. The lead plans it and starts the workflow.", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...8)
                .focused($isFocused)
                .accessibilityLabel("New task for the lead")
            HStack(spacing: 8) {
                leadMenu(leads: leads, selected: lead)
                workflowMenu(workflows: workflows, selected: workflow)
                Spacer()
                Button {
                    send(lead: lead, workflow: workflow)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSend(workflow: workflow))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to the lead (⌘↩)")
                .accessibilityLabel("Send to lead")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 12))
        .background(Color(white: 0.19).opacity(0.7), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }

    private func canSend(workflow: WorkflowDefinition?) -> Bool {
        workflow != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(lead: RoleDefinition?, workflow: WorkflowDefinition?) {
        guard let workflow, canSend(workflow: workflow) else { return }
        if model.submitLeadRequest(text, lead: lead, workflow: workflow, in: project) != nil {
            text = ""
        }
    }

    private func leadMenu(leads: [RoleDefinition], selected: RoleDefinition?) -> some View {
        Menu {
            ForEach(leads) { role in
                Toggle(isOn: Binding(get: { role.id == selected?.id }, set: { if $0 { leadID = role.id } })) {
                    Text(role.name)
                    if !role.description.isEmpty { Text(role.description) }
                }
            }
            if !leads.isEmpty { Divider() }
            Button("Edit Lead Roles…") { model.setTab(.settings, for: project) }
        } label: {
            HStack(spacing: 6) {
                RoleBadge(role: selected, size: 22)
                Text(selected.map { "Lead: \($0.name)" } ?? "No lead role")
                    .font(.system(size: 12))
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the lead that plans this task")
    }

    private func workflowMenu(workflows: [WorkflowDefinition], selected: WorkflowDefinition?) -> some View {
        Menu {
            ForEach(workflows) { workflow in
                Toggle(isOn: Binding(get: { workflow.id == selected?.id }, set: { if $0 { workflowID = workflow.id } })) {
                    Text(workflow.displayName)
                    if !workflow.description.isEmpty { Text(workflow.description) }
                }
            }
        } label: {
            Label(selected?.displayName ?? "No workflows", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x9CC6FF))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.accent.opacity(0.2), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(workflows.isEmpty)
        .help("Choose the workflow this task runs through")
    }
}
