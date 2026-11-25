import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkerRoster: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let chat: Chat
    let project: Project

    static let nudge = "You’ve had no output for a while. If you’re waiting on a prompt or a command that hangs, stop it, then say where you are and what’s left."

    var body: some View {
        let workers = workspace.chatWorkers(chat, in: project).filter(\.isActive)
        if !workers.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(workers, id: \.agent.id) { worker in
                    WorkerActivityRow(worker: worker, project: project)
                }
            }
        }
    }
}

struct ChatWorker {
    let agent: Agent
    let session: LiveAgentSession?
    let state: WorkerState

    var isActive: Bool { state == .working || state == .queued || state == .stuck }
}

struct WorkerActivityRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let worker: ChatWorker
    let project: Project

    var body: some View {
        let role = workspace.role(for: worker.agent, in: project) ?? (worker.agent.kind ?? .builder).builtInRole
        let session = worker.session
        let activity = session.map { TranscriptLayout.activity($0.transcript.entries, live: $0.transcript.liveEntry) } ?? .working
        let root = session.flatMap { $0.transcript.session?.cwd ?? $0.agent.worktreePath }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: activity.isReply ? .top : .center, spacing: 12) {
                RobotFace(kind: RobotFace.Kind(icon: role.icon), size: 20, lookingAside: true)
                SessionActivityView(activity: activity, name: role.name, root: root, verb: role.activeVerb)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.snappy(duration: 0.2), value: activity.phase)
            }
            .contentShape(.rect)
            .onTapGesture { workspace.openAgentSession(worker.agent, in: project) }
            .accessibilityElement(children: activity.isReply ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { workspace.openAgentSession(worker.agent, in: project) }
            if worker.state == .stuck, let session {
                StuckControls(session: session).padding(.leading, 32)
            }
        }
    }
}

struct StuckControls: View {
    let session: LiveAgentSession

    var body: some View {
        HStack(spacing: 8) {
            Text("No output for \(silentMinutes) min. It may be waiting on a prompt or a hung command.")
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Nudge") { session.send(WorkerRoster.nudge) }.buttonStyle(SecondaryPillStyle())
            Button("Restart") {
                session.stop()
                session.resume()
            }
            .buttonStyle(SecondaryPillStyle())
            Button("Stop") { session.stop() }.buttonStyle(.plain).foregroundStyle(Tokens.danger)
        }
    }

    private var silentMinutes: Int {
        session.lastOutputAt.map { Int(Date.now.timeIntervalSince($0) / 60) } ?? 0
    }
}

enum WorkerRow {
    static func label(_ state: WorkerState) -> String {
        switch state {
        case .working: "Working"
        case .waitingOnYou: "Waiting on you"
        case .queued: "Queued"
        case .idle: "Waiting"
        case .done: "Done"
        case .stopped: "Stopped"
        case .stuck: "Stuck"
        case .failed: "Failed"
        }
    }

    static func color(_ state: WorkerState) -> Color {
        switch state {
        case .working: Tokens.build
        case .waitingOnYou: Tokens.need
        case .stuck, .failed: Tokens.stuck
        case .done: Tokens.done
        case .queued, .idle, .stopped: Tokens.text2
        }
    }
}

extension DaemonWorkspace {
    func chatWorkers(_ chat: Chat, in project: Project, now: Date = .now) -> [ChatWorker] {
        guard let chatID = chat.id else { return [] }
        let runs = (try? database.runs(taskId: chatID)) ?? []
        let runIDs = Set(runs.compactMap(\.id))
        let finished = Set(runs.filter { !$0.isActive }.compactMap(\.id))
        let needsYou = Set(needsYouItems.compactMap(\.agentId))
        return agentSessions(in: project)
            .filter { session in
                session.agent.kind != .lead && session.agent.archivedAt == nil
                    && (session.agent.taskId == chatID || session.agent.runId.map(runIDs.contains) == true)
            }
            .map { session in
                let step = session.agent.runId.flatMap { liveRun(id: $0) }.flatMap { run in runWorkflow(run)?.step(run.currentStep ?? "") }
                let facts = WorkerState.Facts(
                    status: session.agent.status, isRunning: session.isRunning, isQueued: session.isQueued,
                    needsYou: session.agent.id.map(needsYou.contains) ?? false,
                    runFinished: session.agent.runId.map(finished.contains) ?? false,
                    lastOutputAt: session.lastOutputAt, stallMinutes: WorkerState.stallMinutes(for: step)
                )
                return ChatWorker(agent: session.agent, session: session, state: WorkerState.of(facts, now: now))
            }
    }
}
