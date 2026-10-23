import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunAgentsPanel: View {
    let snapshot: RunDetailSnapshot
    let project: Project

    var body: some View {
        if snapshot.agents.isEmpty {
            Text("No agents have joined this run yet.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 16)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot.agents) { agent in
                    RunAgentRow(agent: agent, stepTitle: stepTitle(for: agent), project: project)
                    if agent.id != snapshot.agents.last?.id {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .card(cornerRadius: 16)
        }
    }

    private func stepTitle(for agent: Agent) -> String? {
        if let runStepId = agent.runStepId,
           let entry = snapshot.history?.entries.first(where: { $0.attempts.contains { $0.id == runStepId } }) {
            return entry.iteration > 1 ? "\(entry.title) · pass \(entry.iteration)" : entry.title
        }
        return agent.step
    }
}

private struct RunAgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let stepTitle: String?
    let project: Project

    var body: some View {
        let session = model.agents.session(for: agent)
        let live = session?.agent ?? agent
        let role = model.role(for: live, in: project)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                AgentAvatar(size: 30, appearance: RoleAppearance(role: role))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(live.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(role?.name ?? live.role)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text([stepTitle, live.tokensAndCost].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                StatusLabel(status: model.displayStatus(of: live), isQueued: session?.isQueued == true)
            }
            if let branch = live.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 40)
            }
            if let path = live.worktreePath {
                Label(path.abbreviatingHome, systemImage: "folder")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 40)
                    .help(path)
            }
            if live.status == .failed, let error = live.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
                    .padding(.leading, 40)
            }
            FlowLayout(spacing: 6) {
                Button("Open Session") { model.openAgentSession(agent, in: project) }
                    .help("Show \(live.name)’s transcript and controls")
                if let url = live.worktreeURL {
                    Button("Reveal Worktree") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .help("Show the worktree in Finder")
                }
            }
            .buttonStyle(PillButtonStyle(height: 24))
            .font(.system(size: 11.5))
            .padding(.leading, 40)
        }
        .padding(.vertical, 10)
    }
}
