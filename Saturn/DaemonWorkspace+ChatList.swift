import SaturnCore
import SaturnUI
import Foundation
import SwiftUI

struct ChatSummary: Identifiable, Hashable {
    let daemon: DaemonID
    let chat: Chat
    let project: Project
    let stage: ChatStage
    let lastActivity: Date
    let workers: [Agent]
    let isUnread: Bool
    let costUSD: Double

    var id: String { "\(daemon.uuidString)-\(chat.id ?? -1)" }
}

struct DraftSummary: Identifiable, Hashable {
    let daemon: DaemonID
    let draft: ChatDraft
    let project: Project

    var id: String { "\(daemon.uuidString)-draft-\(draft.id.uuidString)" }
}

extension AppModel {
    func chatSummaries() -> (open: [ChatSummary], closed: [ChatSummary]) {
        let all = workspaces.values.map { $0.chatSummaries() }
        let open = all.flatMap(\.open).sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
        let closed = all.flatMap(\.closed).sorted { ($0.chat.closedAt ?? .distantPast, $0.id) > ($1.chat.closedAt ?? .distantPast, $1.id) }
        return (open, closed)
    }

    func draftSummaries() -> [DraftSummary] {
        orderedWorkspaces.flatMap { $0.draftSummaries() }
    }

    var appearance: Appearance {
        get { AppDefaults.store.string(forKey: Appearance.storageKey).flatMap(Appearance.init(rawValue:)) ?? .fallback }
        set { AppDefaults.store.set(newValue.rawValue, forKey: Appearance.storageKey) }
    }

    var allOpenProjects: [(workspace: DaemonWorkspace, project: Project)] {
        orderedWorkspaces.flatMap { workspace in workspace.openProjects.map { (workspace, $0) } }
    }

    var recentOpenProjects: [(workspace: DaemonWorkspace, project: Project)] {
        ProjectRecency.sorted(allOpenProjects, name: \.project.name) { $0.workspace.lastUsed($0.project) }
    }

    func requestNewChat() {
        let projects = allOpenProjects
        switch projects.count {
        case 0: isOpenPanelPresented = true
        case 1: projects[0].workspace.startNewChat(in: projects[0].project)
        default: isNewChatPickerShown = true
        }
    }

    func attentionCount(_ summaries: [ChatSummary]) -> Int {
        summaries.count { $0.stage.needsAttention }
    }

    func openChat(_ summary: ChatSummary) {
        workspace(for: summary.daemon)?.openChat(summary.chat)
    }

    func deleteChat(_ target: DaemonChat) async {
        await workspace(for: target.daemon)?.deleteChat(target.chat)
    }
}

extension DaemonWorkspace {
    func chatSummaries() -> (open: [ChatSummary], closed: [ChatSummary]) {
        var open: [ChatSummary] = []
        var closed: [ChatSummary] = []
        _ = connection.usageRevision
        let spend = (try? database.chatSpend()) ?? [:]
        let openRequests = Dictionary(grouping: requests.items.filter { $0.taskId != nil }, by: { $0.taskId ?? -1 })
        for project in openProjects {
            guard let projectID = project.id else { continue }
            let chats = leadRequests(in: project)
            let activity = (try? database.lastActivity(projectId: projectID)) ?? [:]
            let proposals = (try? database.openProposalChatIDs(projectId: projectID)) ?? []
            let runs = ((try? database.runs(projectId: projectID)) ?? [])
            let runsByChat = Dictionary(grouping: runs, by: \.taskId)
            let chatOfRun = Dictionary(runs.compactMap { run in run.id.map { ($0, run.taskId) } }, uniquingKeysWith: { first, _ in first })
            var workersByChat: [Int64: [Agent]] = [:]
            for session in agentSessions(in: project) where session.agent.kind != .lead && session.agent.archivedAt == nil {
                guard let chatID = session.agent.taskId ?? session.agent.runId.flatMap({ chatOfRun[$0] }) else { continue }
                workersByChat[chatID, default: []].append(session.agent)
            }
            for chat in chats {
                guard let chatID = chat.id else { continue }
                let latest = runsByChat[chatID]?.max { ($0.startedAt, $0.id ?? 0) < ($1.startedAt, $1.id ?? 0) }
                let hold = latest?.id.flatMap { connection.holds[$0] }
                let lead = leadSession(for: chat)
                let facts = ChatStage.Facts(
                    closeReason: chat.closeReason, isClosed: chat.isClosed, isFinished: chat.isFinished, latestRun: latest,
                    currentStep: latest.flatMap { run in run.currentStep.flatMap { runWorkflow(run)?.step($0) } },
                    hold: hold, openRequests: openRequests[chatID]?.map(\.kind) ?? [],
                    pendingPermissions: pendingPermissions.count(taskId: chatID), hasOpenProposal: proposals.contains(chatID),
                    leadIsWorking: lead.map { $0.isRunning || $0.isQueued } ?? false
                )
                let last = activity[chatID] ?? chat.updatedAt
                let summary = ChatSummary(
                    daemon: id, chat: chat, project: project, stage: ChatStage.of(facts), lastActivity: max(last, chat.createdAt),
                    workers: workersByChat[chatID] ?? [],
                    isUnread: ChatActivity.isUnread(viewedAt: chat.viewedAt, createdAt: chat.createdAt, lastActivity: activity[chatID]),
                    costUSD: spend[chatID] ?? 0
                )
                if chat.isClosed { closed.append(summary) } else { open.append(summary) }
            }
        }
        return (open, closed)
    }

    func draftSummaries() -> [DraftSummary] {
        let projects = Dictionary(openProjects.compactMap { project in project.id.map { ($0, project) } }, uniquingKeysWith: { first, _ in first })
        return draftStore.newDrafts().compactMap { draft in
            projects[draft.projectID].map { DraftSummary(daemon: id, draft: draft, project: $0) }
        }
    }

    func lastUsed(_ project: Project) -> Date {
        let activity = project.id.flatMap { try? database.lastActivity(projectId: $0) } ?? [:]
        return ProjectRecency.lastUsed(project, chats: leadRequests(in: project), activity: activity)
    }

    func summary(of chat: Chat) -> ChatSummary? {
        let all = chatSummaries()
        return (all.open + all.closed).first { $0.chat.id == chat.id }
    }

    func chat(of agent: Agent) -> Chat? {
        if let chatID = agent.taskId { return try? database.task(id: chatID) }
        guard let runID = agent.runId, let run = liveRun(id: runID) else { return nil }
        return try? database.task(id: run.taskId)
    }

    func openChat(_ chat: Chat) {
        guard let chatID = chat.id else { return }
        showChatPage(chatID, inProjectID: chat.projectId)
    }

    func renameChat(_ chat: Chat, to title: String) {
        guard let id = chat.id else { return }
        dispatch("Couldn’t rename the chat", ChatCommands.Rename(chatID: id, title: title))
        leadChatRevision += 1
    }

    func finishChat(_ chat: Chat) {
        guard let id = chat.id else { return }
        dispatch("Couldn’t mark the chat as finished", ChatCommands.Finish(chatID: id))
        leadChatRevision += 1
    }

    func reopenChat(_ chat: Chat) {
        guard let id = chat.id else { return }
        dispatch("Couldn’t reopen the chat", ChatCommands.Reopen(chatID: id))
        leadChatRevision += 1
    }

    func deleteChat(_ chat: Chat) async {
        guard project(withID: chat.projectId) != nil, let id = chat.id else { return }
        do {
            try await send(ChatCommands.Delete(chatID: id))
            leadChatRevision += 1
            pages.retain { !$0.kind.shows(chat: id, on: self.id) }
            draftStore.clearChatDraft(chatID: id)
            if leadSelections[chat.projectId] == .request(id) { leadSelections[chat.projectId] = nil }
            app.dropStalePages()
        } catch {
            alert = AppAlert(title: "Couldn’t delete the chat", message: error.localizedDescription)
        }
    }
}

extension ChatStage {
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .stuck: "Stuck · needs you"
        case .building: "Building"
        case .inReview: "In review"
        case .finished: "Finished"
        case .done: "Resolved"
        case .dropped: "Closed"
        case .idle: "Open"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: Tokens.need
        case .stuck: Tokens.stuck
        case .building: Tokens.build
        case .inReview: Tokens.review
        case .finished, .done: Tokens.done
        case .idle: Tokens.idle
        case .dropped: Tokens.text2
        }
    }

    var background: Color {
        switch self {
        case .needsYou: Tokens.needBackground
        case .stuck: Tokens.stuckBackground
        case .building: Tokens.buildBackground
        case .inReview: Tokens.reviewBackground
        case .finished: Tokens.doneBackground
        case .done, .dropped, .idle: Tokens.fill
        }
    }
}
