import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunLogsView: View {
    static let tailLength = 8

    let snapshot: RunDetailSnapshot
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHistory(items: snapshot.requests.sorted { $0.createdAt > $1.createdAt }, agents: snapshot.agents)
            if snapshot.agents.isEmpty {
                Text("Agent transcripts show up here once agents join the run.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(snapshot.agents) { agent in
                AgentTail(agent: agent, project: project, limit: Self.tailLength)
            }
        }
    }
}

private struct RequestHistory: View {
    let items: [ChatRequest]
    let agents: [Agent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What this run asked you")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text("Nothing has needed you on this run.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.bottom, 10)
            }
            ForEach(items) { item in
                RequestHistoryRow(item: item, agentName: item.agentId.flatMap { id in agents.first { $0.id == id }?.name })
                if item.id != items.last?.id {
                    Divider().overlay(Color.white.opacity(0.05))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .card(cornerRadius: 16)
    }
}

private struct RequestHistoryRow: View {
    let item: ChatRequest
    let agentName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(item.status == .open ? item.kind.tint : Theme.tertiaryText)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    StatusChip(text: item.status.label, color: item.status == .open ? item.kind.tint : Theme.neutral)
                }
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let response = item.response, !response.isEmpty {
                    Text("Answer: \(response)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        [
            agentName,
            item.createdAt.formatted(date: .abbreviated, time: .shortened),
            item.resolvedAt.map { "\(item.status.label.lowercased()) \($0.formatted(date: .omitted, time: .shortened))" },
        ].compactMap(\.self).joined(separator: " · ")
    }
}

private struct AgentTail: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let project: Project
    let limit: Int

    var body: some View {
        let session = model.agents.session(for: agent)
        let live = session?.agent ?? agent
        let transcript = session?.transcript
        let items = Array(TranscriptLayout.items(transcript?.entries ?? [], live: transcript?.liveEntry).suffix(limit))
        let root = transcript?.session?.cwd ?? live.worktreePath
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(size: 20, appearance: RoleAppearance(role: model.role(for: live, in: project)))
                Text(live.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                StatusLabel(status: model.displayStatus(of: live), isQueued: session?.isQueued == true, session: session)
                Spacer(minLength: 6)
                Button("Open Session") { model.openAgentSession(agent, in: project) }
                    .buttonStyle(PillButtonStyle(height: 24))
                    .font(.system(size: 11.5))
                    .fixedSize()
                    .help("Show the full transcript")
            }
            if items.isEmpty {
                Text("No transcript yet.").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
            ForEach(items) { item in
                TranscriptItemView(item: item, root: root)
                    .frame(maxHeight: Self.itemHeightLimit, alignment: .top)
                    .clipped()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
        .opensCodeFiles(in: project.id, root: root, model: model)
    }

    private static let itemHeightLimit: CGFloat = 320
}
