import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunLogsView: View {
    static let tailLength = 8

    let snapshot: RunDetailSnapshot
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InboxHistory(items: snapshot.inbox.sorted { $0.createdAt > $1.createdAt }, agents: snapshot.agents)
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

private struct InboxHistory: View {
    let items: [InboxItem]
    let agents: [Agent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Holds and inbox")
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
                InboxHistoryRow(item: item, agentName: item.agentId.flatMap { id in agents.first { $0.id == id }?.name })
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

private struct InboxHistoryRow: View {
    let item: InboxItem
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
        let entries = Array((session?.transcript.entries ?? []).suffix(limit))
        let root = session?.transcript.session?.cwd ?? live.worktreePath
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(size: 20, appearance: RoleAppearance(role: model.role(for: live, in: project)))
                Text(live.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                StatusLabel(status: model.displayStatus(of: live), isQueued: session?.isQueued == true)
                Spacer(minLength: 6)
                Button("Open Session") { model.openAgentSession(agent, in: project) }
                    .buttonStyle(PillButtonStyle(height: 24))
                    .font(.system(size: 11.5))
                    .fixedSize()
                    .help("Show the full transcript")
            }
            if entries.isEmpty {
                Text("No transcript yet.").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
            ForEach(entries) { entry in
                TailLine(entry: entry, root: root)
            }
            if let tool = session?.transcript.activeTool, session?.isRunning == true {
                Label("Running \(tool.name) \(tool.target(relativeTo: root))", systemImage: "ellipsis")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

private struct TailLine: View {
    let entry: TranscriptEntry
    let root: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 58, alignment: .leading)
            Text(text)
                .font(.system(size: 12, design: isTool ? .monospaced : .default))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(isTool ? 1 : 3)
                .truncationMode(isTool ? .middle : .tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var isTool: Bool {
        if case .tool = entry.content { return true }
        return false
    }

    private var kind: String {
        switch entry.content {
        case .user: "Prompt"
        case .assistant: "Agent"
        case .tool(let tool): tool.name
        case .notice: "Notice"
        case .interrupted: "Stopped"
        case .turnFinished: "Turn"
        }
    }

    private var color: Color {
        switch entry.content {
        case .user: Theme.accent
        case .assistant: Theme.primaryText
        case .tool(let tool): tool.isError ? Theme.danger : Theme.link
        case .notice(let notice, _): notice == .failed ? Theme.danger : Theme.tertiaryText
        case .interrupted: Theme.warning
        case .turnFinished(let result): result.isError ? Theme.danger : Theme.tertiaryText
        }
    }

    private var text: String {
        switch entry.content {
        case .user(let text), .assistant(let text): text
        case .tool(let tool): tool.target(relativeTo: root)
        case .notice(let notice, let detail): ["\(notice)".capitalized, detail].compactMap(\.self).joined(separator: " · ")
        case .interrupted: "Interrupted"
        case .turnFinished(let result):
            "\(result.isError ? "Failed" : "Finished") · \(RunDetailFormat.duration(Double(result.durationMS) / 1000)) · \(RunDetailFormat.dollars(result.totalCostUSD))"
        }
    }
}
