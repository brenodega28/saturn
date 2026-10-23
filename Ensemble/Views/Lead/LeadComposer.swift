import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadComposer: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let request: ProjectTask?
    @State private var text = ""
    @State private var leadID: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let leads = model.leadRoles(in: project)
        let lead = leads.first { $0.id == leadID } ?? leads.first
        let leadName = request.flatMap { model.leadSession(for: $0)?.agent.name } ?? lead?.name ?? "the lead"
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "Message",
                text: $text,
                prompt: Text(request == nil ? "Ask or describe what you need. The lead replies and proposes a run when it’s time." : "Message \(leadName)"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(2...8)
            .focused($isFocused)
            .accessibilityLabel(request == nil ? "New request for the lead" : "Message to \(leadName)")
            HStack(spacing: 8) {
                if request.flatMap(model.leadSession(for:)) == nil {
                    leadMenu(leads: leads, selected: lead)
                }
                Spacer()
                Button(action: { send(lead: lead) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSend(lead: lead))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to \(leadName) (⌘↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 12))
        .background(Color(white: 0.19).opacity(0.7), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }

    private func canSend(lead: RoleDefinition?) -> Bool {
        (lead != nil || request.flatMap(model.leadSession(for:)) != nil) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(lead: RoleDefinition?) {
        guard canSend(lead: lead) else { return }
        let message = text
        text = ""
        Task {
            if await !model.sendLeadMessage(message, lead: lead, in: project), text.isEmpty {
                text = message
            }
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
        .help("Choose the lead for this request")
    }
}
