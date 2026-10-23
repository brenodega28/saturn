import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatTargetPicker: View {
    enum Style {
        case header
        case chip
    }

    @Environment(AppModel.self) private var model
    let project: Project
    var style: Style = .header

    var body: some View {
        let current = currentParticipant
        Menu {
            menuContent
        } label: {
            switch style {
            case .header: headerLabel(current)
            case .chip: chipLabel(current)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose who to talk with")
        .accessibilityLabel("Talking with \(current.name). Change agent")
    }

    @ViewBuilder
    private var menuContent: some View {
        let leads = model.leadRoles(in: project)
        if !leads.isEmpty {
            Section("Leads · plan and start runs") {
                ForEach(leads) { role in
                    Toggle(isOn: selection(.lead(role.id))) {
                        Text(role.name)
                        if !role.description.isEmpty { Text(role.description) }
                    }
                }
            }
        }
        ForEach(model.directChatGroups(in: project)) { group in
            Section(group.title) {
                ForEach(group.sessions) { session in
                    Toggle(isOn: selection(.agent(session.id))) {
                        Text(session.agent.name)
                        Text(detail(for: session))
                    }
                }
            }
        }
        Divider()
        Button("Manage Agents…") { model.setTab(.agents, for: project) }
        Button("Edit Lead Roles…") { model.setTab(.settings, for: project) }
    }

    private func selection(_ target: ChatTarget) -> Binding<Bool> {
        Binding(
            get: { model.chatTarget(in: project) == target },
            set: { if $0 { model.chooseChatTarget(target, in: project) } }
        )
    }

    private func detail(for session: AgentSession) -> String {
        let role = model.role(for: session.agent, in: project)?.name ?? session.agent.role
        return "\(role) · \(session.agent.status.label)"
    }

    private var currentParticipant: (name: String, appearance: RoleAppearance, status: AgentStatus?) {
        if let session = model.directChatSession(in: project) {
            return (session.agent.name, RoleAppearance(role: model.role(for: session.agent, in: project)), session.agent.status)
        }
        let lead = model.chatLeadRole(in: project)
        let leadSession = model.selectedRequest(in: project).flatMap(model.leadSession(for:))
        return (lead?.name ?? "No lead role", RoleAppearance(role: lead), leadSession?.agent.status)
    }

    private func headerLabel(_ current: (name: String, appearance: RoleAppearance, status: AgentStatus?)) -> some View {
        HStack(spacing: 9) {
            AgentAvatar(size: 28, appearance: current.appearance)
            VStack(alignment: .leading, spacing: 1) {
                Text("Talking with").font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
                Text(current.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            if let status = current.status {
                StatusDot(status.color, size: 7)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 40)
        .background(Theme.fillRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .contentShape(Capsule())
    }

    private func chipLabel(_ current: (name: String, appearance: RoleAppearance, status: AgentStatus?)) -> some View {
        HStack(spacing: 6) {
            AgentAvatar(size: 22, appearance: current.appearance)
            Text(current.name).font(.system(size: 12)).lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
    }
}
