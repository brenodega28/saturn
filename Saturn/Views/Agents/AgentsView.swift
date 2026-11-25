import SaturnCore
import SaturnUI
import SwiftUI

enum AgentActivity {
    case needsYou
    case working
    case idle

    init(status: AgentStatus, isRunning: Bool, isQueued: Bool) {
        if [.needsInput, .interrupted, .failed, .takenOver].contains(status) {
            self = .needsYou
        } else if isRunning || isQueued || [.working, .reviewing].contains(status) {
            self = .working
        } else {
            self = .idle
        }
    }
}

enum AgentFilter: CaseIterable, Identifiable {
    case all
    case working
    case needsYou
    case idle

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .idle: "Idle"
        }
    }

    func includes(_ activity: AgentActivity) -> Bool {
        switch self {
        case .all: true
        case .working: activity == .working
        case .needsYou: activity == .needsYou
        case .idle: activity == .idle
        }
    }
}

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let worktreeCount: Int
    let openWorktrees: () -> Void
    @State private var filter = AgentFilter.all

    var body: some View {
        let sessions = workspace.agentSessions(in: project)
        if sessions.isEmpty {
            EmptyState("No agents yet", message: "Workflows start agents when a run needs them. You can also spawn them yourself: pick a builder or a checker, its model and skills; each builder works in its own worktree.") {
                Button("New agent") { model.isNewAgentPresented = true }.buttonStyle(CompactPrimaryPillStyle())
            }
            .overlay(alignment: .bottom) {
                if worktreeCount > 0 {
                    Button("\(worktreeCount) worktrees in .crew/ — Debug › Worktrees…", action: openWorktrees)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        } else {
            let entries = sorted(sessions)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro(sessions)
                    filters(entries)
                    grid(entries.filter { filter.includes($0.activity) })
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func intro(_ sessions: [LiveAgentSession]) -> some View {
        SectionIntro(title: "Agents", subtitle: "Who can work in \(project.name). The Lead decides who to start for each chat; you decide who exists and what they may do.") {
            if sessions.contains(where: { $0.isRunning || $0.isQueued }) {
                Button("Pause all") { workspace.pauseAllAgents(in: project) }
                    .buttonStyle(CompactSecondaryPillStyle())
                    .help("Pause every working or queued agent in \(project.name) (⇧⌘P)")
            }
            Button {
                model.isNewAgentPresented = true
            } label: {
                Label("New agent", systemImage: "plus")
            }
            .buttonStyle(CompactPrimaryPillStyle())
        }
    }

    private func filters(_ entries: [AgentEntry]) -> some View {
        HStack(spacing: 6) {
            ForEach(AgentFilter.allCases) { option in
                FilterChip(title: option.title, count: entries.filter { option.includes($0.activity) }.count, isOn: filter == option) {
                    filter = option
                }
            }
            Spacer(minLength: 12)
            Text("Up to \(project.settings.maxConcurrentAgents) at once")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text3)
                .help("Change the limit in Settings › Agents & models")
        }
    }

    @ViewBuilder
    private func grid(_ entries: [AgentEntry]) -> some View {
        if entries.isEmpty {
            Text("No agents match this filter.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text2)
                .padding(.vertical, 24)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(entries) { entry in
                    AgentCard(session: entry.session, project: project, isLead: entry.isLead, activity: entry.activity)
                }
            }
        }
    }

    private func sorted(_ sessions: [LiveAgentSession]) -> [AgentEntry] {
        sessions.map { session in
            let kind = workspace.role(for: session.agent, in: project)?.kind ?? AgentKind.guessing(roleID: session.agent.role)
            let status = workspace.displayStatus(of: session.agent)
            return AgentEntry(session: session, isLead: kind == .lead, activity: AgentActivity(status: status, isRunning: session.isRunning, isQueued: session.isQueued))
        }
        .sorted { $0.rank < $1.rank }
    }
}

@MainActor
private struct AgentEntry: @MainActor Identifiable {
    let session: LiveAgentSession
    let isLead: Bool
    let activity: AgentActivity

    var id: Int64 { session.id }

    var rank: Int {
        if session.agent.archivedAt != nil { return 5 }
        if isLead { return 0 }
        switch activity {
        case .needsYou: return 1
        case .working: return 2
        case .idle: return session.agent.isPinned ? 3 : 4
        }
    }
}

private struct AgentCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let session: LiveAgentSession
    let project: Project
    let isLead: Bool
    let activity: AgentActivity
    @State private var isConfirmingDelete = false

    var body: some View {
        let agent = session.agent
        let role = workspace.role(for: agent, in: project)
        let name = workspace.displayName(of: agent, in: project)
        let status = workspace.displayStatus(of: agent)
        VStack(alignment: .leading, spacing: 14) {
            Button {
                workspace.select(session, in: project)
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        AgentAvatar(size: 52, appearance: RoleAppearance(role: role), isFailing: status == .failed)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                if isLead { leadBadge }
                            }
                            HStack(spacing: 0) {
                                Text("\(role?.name ?? "Builder") · ")
                                Text(session.transcript.session?.model ?? agent.model.modelTitle)
                                    .font(Tokens.mono(11.5))
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        AgentStatusPill(status: status, session: session)
                    }
                    Text(headline)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.text)
                        .lineSpacing(2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(session.isQueued ? "Queued" : status.label)")
            .accessibilityHint("Opens the agent session")

            footer(agent)
        }
        .padding(16)
        .raisedCard()
        .opacity(agent.archivedAt != nil ? 0.7 : 1)
        .contextMenu {
            Button("Open") { workspace.select(session, in: project) }
            if let chat = workspace.chat(of: agent) {
                Button("Open Chat") { workspace.openChat(chat) }
            }
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
                    Task { await workspace.deleteAgent(session, in: project, deleteBranch: false) }
                }
            } else {
                Button("Delete Agent and Branch", role: .destructive) {
                    Task { await workspace.deleteAgent(session, in: project, deleteBranch: true) }
                }
                Button("Delete Agent, Keep Branch") {
                    Task { await workspace.deleteAgent(session, in: project, deleteBranch: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(agent.readOnly
                 ? "Its transcript is removed. Read-only agents have no worktree or branch."
                 : "The worktree is removed, including uncommitted changes. Keep the branch to hold on to its commits.")
        }
    }

    private var leadBadge: some View {
        Text("You talk to this one")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Tokens.selection, in: Capsule())
            .fixedSize()
    }

    private func footer(_ agent: Agent) -> some View {
        HStack(spacing: 8) {
            chatLink(agent)
            if agent.isPinned {
                MemoryBadge(project: project, agent: agent)
            }
            Text(agent.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                .font(Tokens.mono(11.5))
                .help(agent.tokensAndCost)
            AgentControls(session: session, compact: true)
            PinButton(session: session)
        }
        .font(.system(size: 12))
        .foregroundStyle(Tokens.text2)
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }

    @ViewBuilder
    private func chatLink(_ agent: Agent) -> some View {
        let chat = workspace.chat(of: agent)
        Button {
            if let chat { workspace.openChat(chat) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left").font(.system(size: 11)).accessibilityHidden(true)
                Text(chat?.title ?? agent.branch ?? (agent.readOnly ? "Read-only" : "Own worktree"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(chat == nil)
        .help(chat == nil ? "Not part of a chat" : "Open the chat")
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

struct AgentStatusPill: View {
    let status: AgentStatus
    let session: LiveAgentSession

    var body: some View {
        let colors = palette
        StatusPill(text: text, color: colors.0, background: colors.1)
    }

    private var text: String {
        if let retryingAt = session.retryingAt { return "Retrying at \(retryingAt.formatted(date: .omitted, time: .shortened))" }
        if session.isRunning, let retry = session.apiRetry { return "Retrying \(retry.attempt) of \(retry.maxRetries)" }
        return session.isQueued ? "Queued" : status.label
    }

    private var palette: (Color, Color) {
        if session.retryingAt != nil || (session.isRunning && session.apiRetry != nil) { return (Tokens.need, Tokens.needBackground) }
        if session.isQueued { return (Tokens.idle, Tokens.fill) }
        switch status {
        case .working: return (Tokens.build, Tokens.buildBackground)
        case .reviewing: return (Tokens.review, Tokens.reviewBackground)
        case .needsInput, .interrupted: return (Tokens.need, Tokens.needBackground)
        case .failed: return (Tokens.stuck, Tokens.stuckBackground)
        case .takenOver: return (Tokens.accent, Tokens.selection)
        case .idle, .waiting, .paused, .stopped: return (Tokens.idle, Tokens.fill)
        }
    }
}

struct PinButton: View {
    let session: LiveAgentSession

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
    let session: LiveAgentSession
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
