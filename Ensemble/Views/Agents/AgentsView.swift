import EnsembleCore
import EnsembleUI
import SwiftUI

struct AgentGroup: Identifiable {
    enum Kind: Hashable {
        case run(Int64)
        case pinned
        case idle
        case other
        case archived
    }

    let kind: Kind
    let title: String
    let meta: String
    let sessions: [AgentSession]

    var id: Kind { kind }

    @MainActor
    static func make(_ sessions: [AgentSession], runs: [Run], idleCleanupMinutes: Int = 0, describe: (Run) -> (workflow: String?, step: String?) = { ($0.workflow, $0.currentStep) }) -> [AgentGroup] {
        var groups: [AgentGroup] = []
        let runsByID = Dictionary(uniqueKeysWithValues: runs.compactMap { run in run.id.map { ($0, run) } })
        let runIDs = sessions.compactMap(\.agent.runId).reduce(into: [Int64]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
        for runID in runIDs {
            let members = sessions.filter { $0.agent.runId == runID }
            let run = runsByID[runID]
            let title = run.map { $0.title.isEmpty ? "Run #\(runID)" : $0.title } ?? "Run #\(runID)"
            let cost = members.reduce(0) { $0 + $1.agent.costUSD }.formatted(.currency(code: "USD"))
            let described = run.map(describe)
            let meta = [described?.workflow, described?.step.map { "Step: \($0)" }, cost].compactMap(\.self).joined(separator: " · ")
            groups.append(AgentGroup(kind: .run(runID), title: title, meta: meta, sessions: members))
        }
        let outsideRuns = sessions.filter { $0.agent.runId == nil }
        let archived = outsideRuns.filter { $0.agent.archivedAt != nil && !$0.agent.isPinned }
        let archivedIDs = Set(archived.map(\.id))
        let pinned = outsideRuns.filter(\.agent.isPinned)
        let idle = outsideRuns.filter { !$0.agent.isPinned && $0.agent.status == .idle && !$0.isRunning && !$0.isQueued && !archivedIDs.contains($0.id) }
        let idleIDs = Set(idle.map(\.id))
        let others = outsideRuns.filter { !$0.agent.isPinned && !idleIDs.contains($0.id) && !archivedIDs.contains($0.id) }
        if !pinned.isEmpty {
            groups.append(AgentGroup(kind: .pinned, title: "Pinned", meta: "Kept between runs, with memory", sessions: pinned))
        }
        if !idle.isEmpty {
            groups.append(AgentGroup(kind: .idle, title: "Idle", meta: IdleCleanupPolicy.summary(minutes: idleCleanupMinutes), sessions: idle))
        }
        if !others.isEmpty {
            groups.append(AgentGroup(kind: .other, title: "Agents", meta: "Working, paused or needing you", sessions: others))
        }
        if !archived.isEmpty {
            groups.append(AgentGroup(kind: .archived, title: "Cleaned up", meta: "Worktrees removed after sitting idle; branches kept", sessions: archived))
        }
        return groups
    }
}

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let worktreeCount: Int
    let openWorktrees: () -> Void

    var body: some View {
        let sessions = model.agentSessions(in: project)
        if sessions.isEmpty {
            EmptyState("No agents yet", message: "Workflows start agents when a run needs them. You can also spawn them yourself: pick a builder or a checker, its model and skills; each builder works in its own worktree.") {
                Button("New Agent") { model.isNewAgentPresented = true }.buttonStyle(.primaryPill)
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
                VStack(alignment: .leading, spacing: 22) {
                    summary(sessions)
                    ForEach(AgentGroup.make(sessions, runs: model.runs(for: sessions), idleCleanupMinutes: project.settings.idleCleanupMinutes, describe: model.runGroupDescription)) { group in
                        section(group)
                    }
                }
            }
        }
    }

    private func section(_ group: AgentGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if case .run(let runID) = group.kind {
                    let needsYou = model.liveRun(id: runID).map(model.runNeedsYou) == true
                    HStack(spacing: 8) {
                        StatusDot(AppModel.statusColor(needsYou: needsYou, otherwise: Theme.success), size: 8)
                        Text(group.title).font(.system(size: 15, weight: .semibold))
                    }
                } else {
                    Text(group.title).font(.system(size: 15, weight: .semibold))
                }
                Text(group.meta).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(group.sessions) { session in
                    AgentCard(session: session, project: project, isDimmed: group.kind == .idle || group.kind == .archived)
                }
            }
        }
    }

    private func summary(_ sessions: [AgentSession]) -> some View {
        let working = sessions.filter { $0.agent.status == .working }.count
        let attention = sessions.filter { [.failed, .interrupted, .takenOver, .needsInput].contains($0.agent.status) }.count
        let queued = sessions.filter(\.isQueued).count
        let pinned = sessions.filter(\.agent.isPinned).count
        let idle = sessions.filter { $0.agent.status == .idle && !$0.isQueued }.count
        let cost = sessions.reduce(0) { $0 + $1.agent.costUSD }
        var parts: [Text] = [Text("\(working) working")]
        if attention > 0 { parts.append(Text("\(attention) need\(attention == 1 ? "s" : "") you").foregroundStyle(Theme.warning)) }
        if queued > 0 { parts.append(Text("\(queued) queued")) }
        parts.append(Text("\(pinned) pinned"))
        parts.append(Text("\(idle) idle"))
        parts.append(Text(cost.formatted(.currency(code: "USD"))))
        return HStack(spacing: 8) {
            ForEach(parts.indices, id: \.self) { index in
                if index > 0 { Text("·").accessibilityHidden(true) }
                parts[index]
            }
            Spacer()
            if working + queued > 0 {
                Button("Pause All") { model.pauseAllAgents(in: project) }
                    .buttonStyle(PillButtonStyle(height: 26))
                    .help("Pause every working or queued agent in \(project.name) (⇧⌘P)")
            }
            Text("Up to \(project.settings.maxConcurrentAgents) at once")
                .help("Change the limit in Settings › Agents & models")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    let isDimmed: Bool
    @State private var isConfirmingDelete = false

    var body: some View {
        let agent = session.agent
        let role = model.role(for: agent, in: project)
        let name = model.displayName(of: agent, in: project)
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.select(session, in: project)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AgentAvatar(appearance: RoleAppearance(role: role))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(role?.name ?? "Builder") ·\(session.transcript.session?.model ?? agent.model.modelTitle)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        StatusLabel(status: model.displayStatus(of: agent), isQueued: session.isQueued, session: session)
                    }
                    Text(headline)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if agent.isPinned {
                            MemoryBadge(project: project, agent: agent)
                        }
                        if let step = agent.step {
                            Chip(text: "Step \(step)")
                        }
                        if agent.readOnly {
                            Chip(text: "read-only")
                        } else {
                            Chip(text: agent.branch ?? "own worktree", foreground: Theme.successText, background: Theme.success.opacity(0.14))
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(session.isQueued ? "Queued" : model.displayStatus(of: agent).label)")
            .accessibilityHint("Opens the agent session")

            HStack(spacing: 4) {
                Text(agent.tokensAndCost)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                AgentControls(session: session, compact: true)
                PinButton(session: session)
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.06)) }
        }
        .padding(16)
        .card()
        .opacity(isDimmed ? 0.75 : 1)
        .contextMenu {
            Button("Open") { model.select(session, in: project) }
            Button(agent.isPinned ? "Unpin" : "Pin") { session.togglePin() }
            if let worktree = agent.worktreeURL, !project.isRemote {
                Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree]) }
            }
            Divider()
            Button("Delete Agent…", role: .destructive) { isConfirmingDelete = true }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $isConfirmingDelete) {
            if agent.readOnly {
                Button("Delete Agent", role: .destructive) {
                    Task { await model.deleteAgent(session, in: project, deleteBranch: false) }
                }
            } else {
                Button("Delete Agent and Branch", role: .destructive) {
                    Task { await model.deleteAgent(session, in: project, deleteBranch: true) }
                }
                Button("Delete Agent, Keep Branch") {
                    Task { await model.deleteAgent(session, in: project, deleteBranch: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(agent.readOnly
                 ? "Its transcript is removed. Read-only agents have no worktree or branch."
                 : "The worktree is removed, including uncommitted changes. Keep the branch to hold on to its commits.")
        }
    }

    private var headline: String {
        if let tool = session.transcript.activeTool {
            return "\(tool.name) \(tool.target(relativeTo: session.transcript.session?.cwd))"
        }
        if session.isQueued {
            return "Queued — starts when another agent in this project finishes its turn."
        }
        if session.agent.status == .failed, let error = session.agent.lastError {
            return error
        }
        if session.agent.task.isEmpty {
            return session.transcript.session == nil ? "Ready. Open the agent and send it a message." : "Waiting for your next message."
        }
        return session.agent.task
    }
}

struct PinButton: View {
    let session: AgentSession

    var body: some View {
        let pinned = session.agent.isPinned
        Button(action: session.togglePin) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .frame(width: 30, height: 30)
                .background(pinned ? Theme.memory.opacity(0.2) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned ? Theme.memory : Color.white.opacity(0.8))
        .help(pinned ? "Unpin" : "Pin — keep between runs")
        .accessibilityLabel(pinned ? "Unpin" : "Pin")
        .accessibilityAddTraits(pinned ? .isSelected : [])
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
            if session.isRunning || session.isQueued {
                control("Pause", systemImage: "pause.fill", action: session.pause)
                    .disabled(session.isStopping)
            } else if status == .takenOver {
                control("Hand Back", systemImage: "arrow.uturn.left", action: session.handBack)
            } else if session.canResume {
                control("Resume", systemImage: "play.fill", action: session.resume)
            }
            control("Stop", systemImage: "stop.fill", action: session.stop)
                .disabled(!(session.isRunning || session.isQueued) || session.isStopping)
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
