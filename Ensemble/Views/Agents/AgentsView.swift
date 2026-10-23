import EnsembleCore
import EnsembleUI
import SwiftUI

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let worktreeCount: Int
    let openWorktrees: () -> Void

    var body: some View {
        let sessions = model.agentSessions(in: project)
        if sessions.isEmpty {
            EmptyState("No agents yet", message: "Agents are created by runs. Until workflows arrive, start one yourself: give it a task and it works in its own worktree.") {
                Button("New Agent") { model.isNewAgentPresented = true }.buttonStyle(.primaryPill)
                Button("Open Tasks") { model.setTab(.tasks, for: project) }.buttonStyle(.pill)
            }
            .overlay(alignment: .bottom) {
                if worktreeCount > 0 {
                    Button("\(worktreeCount) worktrees in .crew/ — Debug › Worktrees…", action: openWorktrees)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary(sessions)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(sessions) { session in
                            AgentCard(session: session, project: project)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ sessions: [AgentSession]) -> some View {
        let working = sessions.filter { $0.agent.status == .working }.count
        let attention = sessions.filter { [.failed, .interrupted, .takenOver].contains($0.agent.status) }.count
        let cost = sessions.reduce(0) { $0 + $1.agent.costUSD }
        return HStack(spacing: 8) {
            Text("\(working) working")
            if attention > 0 {
                Text("·").accessibilityHidden(true)
                Text("\(attention) need\(attention == 1 ? "s" : "") you").foregroundStyle(Theme.warning)
            }
            Text("·").accessibilityHidden(true)
            Text("\(sessions.count) agent\(sessions.count == 1 ? "" : "s")")
            Text("·").accessibilityHidden(true)
            Text(cost.formatted(.currency(code: "USD")))
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    @State private var isConfirmingDelete = false

    var body: some View {
        let agent = session.agent
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.select(session, in: project)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AgentAvatar()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(.system(size: 15, weight: .semibold))
                            Text("Claude Code · \(session.transcript.session?.model ?? agent.model)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                        StatusLabel(status: agent.status)
                    }
                    Text(headline)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Chip(text: agent.branch ?? "no branch", foreground: Theme.successText, background: Theme.success.opacity(0.14))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agent.name), \(agent.status.label)")
            .accessibilityHint("Opens the agent session")

            HStack(spacing: 4) {
                Text(agent.tokensAndCost)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                AgentControls(session: session, compact: true)
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.06)) }
        }
        .padding(16)
        .card()
        .contextMenu {
            Button("Open") { model.select(session, in: project) }
            if let worktree = agent.worktreeURL {
                Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree]) }
            }
            Divider()
            Button("Delete Agent…", role: .destructive) { isConfirmingDelete = true }
        }
        .confirmationDialog("Delete \(agent.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete Agent and Branch", role: .destructive) {
                Task { await model.deleteAgent(session, in: project, deleteBranch: true) }
            }
            Button("Delete Agent, Keep Branch") {
                Task { await model.deleteAgent(session, in: project, deleteBranch: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The worktree is removed, including uncommitted changes. Keep the branch to hold on to its commits.")
        }
    }

    private var headline: String {
        if let tool = session.transcript.activeTool {
            return "\(tool.name) \(tool.target(relativeTo: session.transcript.session?.cwd))"
        }
        if session.agent.status == .failed, let error = session.agent.lastError {
            return error
        }
        return session.agent.task
    }
}

struct Chip: View {
    let text: String
    var foreground: Color = Theme.secondaryText
    var background: Color = Theme.fillRaised

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: .rect(cornerRadius: 6, style: .continuous))
    }
}

struct AgentControls: View {
    let session: AgentSession
    var compact = false

    var body: some View {
        let status = session.agent.status
        HStack(spacing: compact ? 4 : 8) {
            if session.isRunning {
                control("Pause", systemImage: "pause.fill", action: session.pause)
                    .disabled(session.isStopping)
            } else if status == .takenOver {
                control("Hand Back", systemImage: "arrow.uturn.left", action: session.handBack)
            } else if session.canResume {
                control("Resume", systemImage: "play.fill", action: session.resume)
            }
            control("Stop", systemImage: "stop.fill", action: session.stop)
                .disabled(!session.isRunning || session.isStopping)
            control("Restart", systemImage: "arrow.clockwise", action: session.restart)
                .disabled(session.isStopping)
        }
    }

    @ViewBuilder
    private func control(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        if compact {
            Button(action: action) {
                Image(systemName: systemImage).frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.8))
            .help(title)
            .accessibilityLabel(title)
        } else {
            Button(action: action) { Label(title, systemImage: systemImage) }
                .buttonStyle(.pill)
        }
    }
}
