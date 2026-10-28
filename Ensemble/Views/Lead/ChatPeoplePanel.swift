import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatPeoplePanel: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var query = ""

    var body: some View {
        let current = model.chatTarget(in: project)
        let agents = agentRows
        VStack(alignment: .leading, spacing: 14) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        groupHeader("Leads", systemImage: "pin.fill", trailing: "plan & start runs")
                        ForEach(leadRows) { row in
                            PersonRow(row: row, isCurrent: current == row.target) {
                                model.chooseChatTarget(row.target, in: project)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Leads")
                    Divider().overlay(Theme.hairline)
                    VStack(alignment: .leading, spacing: 2) {
                        groupHeader("Agents", trailing: "\(agents.active) active", monospacedTrailing: true)
                        ForEach(agents.rows) { row in
                            PersonRow(row: row, isCurrent: current == row.target) {
                                model.chooseChatTarget(row.target, in: project)
                            }
                        }
                        showAllButton
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Agents")
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 248)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.035), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People to chat with")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Find an agent", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Find an agent")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func groupHeader(_ title: String, systemImage: String? = nil, trailing: String, monospacedTrailing: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
            }
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.system(size: 11, design: monospacedTrailing ? .monospaced : .default))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var showAllButton: some View {
        Button {
            model.setTab(.agents, for: project)
        } label: {
            HStack(spacing: 8) {
                Text("Show all \(model.agentSessions(in: project).count) agents")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.link)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func matches(_ name: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
    }

    private var leadRows: [PersonRow.Model] {
        let requests = LeadRequest.partition(model.leadRequests(in: project)).open
        let needsYouTaskIDs = model.needsYouTaskIDs()
        return [model.leadRole(in: project)].filter { matches($0.name) }.map { role in
            let led = requests.compactMap { request in
                model.leadSession(for: request).flatMap { $0.agent.role == role.id ? (request, $0) : nil }
            }
            let waiting = led.filter { request, _ in
                model.requestNeedsYou(request, latestRun: model.latestRun(of: request), needsYouTaskIDs: needsYouTaskIDs)
            }.count
            let status = waiting > 0 ? .needsInput : led.map { model.displayStatus(of: $0.1.agent) }.min { $0.busyness < $1.busyness } ?? .idle
            return PersonRow.Model(
                target: .lead(role.id),
                name: role.name,
                subtitle: role.description.isEmpty ? "Lead" : role.description,
                appearance: RoleAppearance(role: role),
                status: status,
                needsYou: waiting
            )
        }
    }

    private var agentRows: (rows: [PersonRow.Model], active: Int) {
        let sessions = model.directChatGroups(in: project).flatMap(\.sessions)
        let rows = sessions.enumerated().map { index, session in
            let status = model.displayStatus(of: session.agent)
            let role = model.role(for: session.agent, in: project)
            let needsYou = session.agent.id.map { id in model.needsYouItems.filter { $0.agentId == id }.count } ?? 0
            return (index, PersonRow.Model(
                target: .agent(session.id),
                name: model.displayName(of: session.agent, in: project),
                subtitle: "\(status.label) · \(role?.name ?? session.agent.role)",
                appearance: RoleAppearance(role: role),
                status: status,
                needsYou: needsYou
            ))
        }
        .sorted { ($0.1.status.busyness, $0.0) < ($1.1.status.busyness, $1.0) }
        .map(\.1)
        return (rows.filter { matches($0.name) }, rows.filter(\.status.isActive).count)
    }
}

private struct PersonRow: View {
    struct Model: Identifiable {
        let target: ChatTarget
        let name: String
        let subtitle: String
        let appearance: RoleAppearance
        let status: AgentStatus
        let needsYou: Int

        var id: ChatTarget { target }
    }

    let row: Model
    let isCurrent: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                AgentAvatar(size: 30, appearance: row.appearance)
                    .overlay(alignment: .bottomTrailing) {
                        StatusDot(row.status.color, size: 10)
                            .overlay(Circle().strokeBorder(Color(hex: 0x26272C), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    Text(row.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.needsYou > 0 {
                    Text("\(row.needsYou)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.warning, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 44)
            .background(background, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(row.subtitle)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var background: Color {
        if isCurrent { return Theme.fillSelected.opacity(0.6) }
        return isHovered ? Theme.fill : .clear
    }

    private var accessibilityLabel: String {
        let badge = row.needsYou > 0 ? ", \(row.needsYou) need\(row.needsYou == 1 ? "s" : "") you" : ""
        return "\(row.name), \(row.subtitle)\(badge)"
    }
}

struct ChatRecipientChip: View {
    let name: String
    let appearance: RoleAppearance

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatar(size: 22, appearance: appearance)
            Text("To \(name)").font(.system(size: 12)).lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
