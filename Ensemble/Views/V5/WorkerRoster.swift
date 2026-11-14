import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkerRoster: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let project: Project

    static let nudge = "You’ve had no output for a while. If you’re waiting on a prompt or a command that hangs, stop it, then say where you are and what’s left."

    var body: some View {
        let workers = model.chatWorkers(chat, in: project)
        if !workers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Workers").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                    Text(Self.counts(workers.map(\.state))).font(.system(size: 12.5)).foregroundStyle(Tokens.text2)
                    Spacer()
                    if workers.contains(where: { $0.state == .working || $0.state == .stuck || $0.state == .queued }) {
                        Button("Stop all") { for worker in workers { worker.session?.stop() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.danger)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 6, trailing: 2))
                ForEach(workers, id: \.agent.id) { worker in
                    WorkerRow(worker: worker, project: project)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.hair2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workers on this chat")
        }
    }

    static func counts(_ states: [WorkerState]) -> String {
        let order: [(WorkerState, String)] = [(.working, "working"), (.stuck, "stuck"), (.waitingOnYou, "waiting on you"), (.queued, "queued"), (.done, "done"), (.stopped, "stopped"), (.failed, "failed"), (.idle, "idle")]
        return order.compactMap { state, label in
            let count = states.count { $0 == state }
            return count > 0 ? "\(count) \(label)" : nil
        }.joined(separator: " · ")
    }
}

struct ChatWorker {
    let agent: Agent
    let session: AgentSession?
    let state: WorkerState
}

private struct WorkerRow: View {
    @Environment(AppModel.self) private var model
    let worker: ChatWorker
    let project: Project
    @State private var isHovered = false

    var body: some View {
        let name = model.displayName(of: worker.agent, in: project)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AgentAvatar(size: 20, appearance: RoleAppearance(role: model.role(for: worker.agent, in: project)), isFailing: worker.state == .failed || worker.state == .stuck)
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                Text(worker.agent.branch ?? (worker.agent.readOnly ? "no worktree · reads the others" : ""))
                    .font(Tokens.mono(11.5))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if isHovered {
                    actions
                } else {
                    Text(Self.label(worker.state)).font(.system(size: 12.5)).foregroundStyle(Self.color(worker.state))
                }
            }
            if worker.state == .stuck, let session = worker.session {
                HStack(spacing: 8) {
                    Text("No output for \(Self.silentMinutes(session)) min. It may be waiting on a prompt or a hung command.")
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
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(Self.label(worker.state))")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            Button("Open") { model.openAgentSession(worker.agent, in: project) }
            if worker.state == .failed || worker.state == .stopped, let session = worker.session {
                Button("Retry") { session.resume() }
            }
            if worker.state == .working || worker.state == .queued || worker.state == .stuck, let session = worker.session {
                Button("Stop") { session.stop() }.foregroundStyle(Tokens.danger)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(Tokens.link)
    }

    static func silentMinutes(_ session: AgentSession) -> Int {
        session.lastOutputAt.map { Int(Date.now.timeIntervalSince($0) / 60) } ?? 0
    }

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

extension AppModel {
    func chatWorkers(_ chat: Chat, in project: Project, now: Date = .now) -> [ChatWorker] {
        guard let chatID = chat.id else { return [] }
        let runs = (try? database.runs(taskId: chatID)) ?? []
        let runIDs = Set(runs.compactMap(\.id))
        let finished = Set(runs.filter { !(($0.id.flatMap { engine.runs[$0] }) ?? $0).isActive }.compactMap(\.id))
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
