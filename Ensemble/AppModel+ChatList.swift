import EnsembleCore
import EnsembleUI
import Foundation
import SwiftUI

struct ChatSummary: Identifiable, Hashable {
    let chat: Chat
    let project: Project
    let stage: ChatStage
    let lastActivity: Date
    let workers: [Agent]
    let isUnread: Bool

    var id: Int64 { chat.id ?? -1 }
}

extension AppModel {
    func chatSummaries() -> (open: [ChatSummary], closed: [ChatSummary]) {
        var open: [ChatSummary] = []
        var closed: [ChatSummary] = []
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
                    closeReason: chat.closeReason, isClosed: chat.isClosed, latestRun: latest,
                    currentStep: latest.flatMap { run in run.currentStep.flatMap { runWorkflow(run)?.step($0) } },
                    hold: hold, openRequests: openRequests[chatID]?.map(\.kind) ?? [],
                    pendingPermissions: pendingPermissions.count(taskId: chatID), hasOpenProposal: proposals.contains(chatID),
                    leadIsWorking: lead.map { $0.isRunning || $0.isQueued } ?? false
                )
                let last = activity[chatID] ?? chat.updatedAt
                let summary = ChatSummary(
                    chat: chat, project: project, stage: ChatStage.of(facts), lastActivity: max(last, chat.createdAt),
                    workers: workersByChat[chatID] ?? [],
                    isUnread: ChatActivity.isUnread(viewedAt: chat.viewedAt, createdAt: chat.createdAt, lastActivity: activity[chatID])
                )
                if chat.isClosed { closed.append(summary) } else { open.append(summary) }
            }
        }
        open.sort { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
        closed.sort { ($0.chat.closedAt ?? .distantPast, $0.id) > ($1.chat.closedAt ?? .distantPast, $1.id) }
        return (open, closed)
    }

    func summary(of chat: Chat) -> ChatSummary? {
        let all = chatSummaries()
        return (all.open + all.closed).first { $0.id == chat.id }
    }

    var appearance: Appearance {
        get { AppDefaults.store.string(forKey: Appearance.storageKey).flatMap(Appearance.init(rawValue:)) ?? .fallback }
        set { AppDefaults.store.set(newValue.rawValue, forKey: Appearance.storageKey) }
    }

    func chat(of agent: Agent) -> Chat? {
        if let chatID = agent.taskId { return try? database.task(id: chatID) }
        guard let runID = agent.runId, let run = liveRun(id: runID) else { return nil }
        return try? database.task(id: run.taskId)
    }

    func requestNewChat() {
        switch openProjects.count {
        case 0: isOpenPanelPresented = true
        case 1: startNewChat(in: openProjects[0])
        default: isNewChatPickerShown = true
        }
    }

    func attentionCount(_ summaries: [ChatSummary]) -> Int {
        summaries.count { $0.stage.needsAttention }
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
            pages.retain { $0.kind.chatID != id }
            if leadSelections[chat.projectId] == .request(id) { leadSelections[chat.projectId] = nil }
            dropStalePages()
        } catch {
            alert = AppAlert(title: "Couldn’t delete the chat", message: error.localizedDescription)
        }
    }

    func copyChatLink(_ chat: Chat) {
        guard let id = chat.id else { return }
        copyToPasteboard(ChatLink(requestID: id).url.absoluteString)
    }
}

extension ChatStage {
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .stuck: "Stuck · needs you"
        case .building: "Building"
        case .inReview: "In review"
        case .done: "Done"
        case .dropped: "Dropped"
        case .idle: "Open"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: Tokens.need
        case .stuck: Tokens.stuck
        case .building: Tokens.build
        case .inReview: Tokens.review
        case .done: Tokens.done
        case .dropped, .idle: Tokens.text2
        }
    }

    var background: Color {
        switch self {
        case .needsYou: Tokens.needBackground
        case .stuck: Tokens.stuckBackground
        case .building: Tokens.buildBackground
        case .inReview: Tokens.reviewBackground
        case .done: Tokens.doneBackground
        case .dropped, .idle: Tokens.fill
        }
    }
}
