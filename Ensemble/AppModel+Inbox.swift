import AppKit
import EnsembleCore
import Foundation
import UserNotifications

extension AppModel {
    var inboxCount: Int { inbox.count }

    func startInbox() {
        inboxNotifier.onOpen = { [weak self] target in self?.openNotification(target) }
        inbox.onNewItems = { [weak self] items in
            guard let self else { return }
            let visibleChat = visibleChat()
            let wanted = items.filter { item in
                NotificationPreferences.isEnabled(item.kind)
                    && !NotificationSuppression.shouldSuppress(
                        appActive: NSApp.isActive, visibleChat: visibleChat, target: (item.projectId, taskID(of: item))
                    )
            }
            inboxNotifier.post(wanted, projectName: { [weak self] id in self?.project(withID: id)?.name })
        }
        chatNotifications.onNew = { [weak self] notifications in
            guard let self else { return }
            let visibleChat = visibleChat()
            let wanted = notifications.filter { notification in
                NotificationPreferences.isEnabled(notification.event)
                    && !NotificationSuppression.shouldSuppress(
                        appActive: NSApp.isActive, visibleChat: visibleChat, target: (notification.projectId, notification.taskId)
                    )
            }
            inboxNotifier.post(wanted, projectName: { [weak self] id in self?.project(withID: id)?.name })
        }
        agents.observeTurnEnds { [weak self] session in
            guard let self, session.agent.kind == .lead, session.agent.status == .idle, let taskID = session.agent.taskId,
                  !session.isRunning, !session.isQueued else { return }
            chatNotifications.leadTurnEnded(taskId: taskID) { [weak self] run in
                run.id.flatMap { self?.engine.runs[$0] } ?? run
            }
        }
        inbox.start()
        chatNotifications.start()
        inboxNotifier.requestAuthorization()
    }

    func visibleChat() -> (projectId: Int64, taskId: Int64)? {
        guard case .project(let projectID) = selection, tabs[projectID] == .lead, runDetailIDs[projectID] == nil,
              !requestPageProjectIDs.contains(projectID), let project = project(withID: projectID),
              let taskID = selectedRequest(in: project)?.id else { return nil }
        return (projectID, taskID)
    }

    func taskID(of item: InboxItem) -> Int64? {
        if let runID = item.runId, let run = liveRun(id: runID) { return run.taskId }
        return item.agentId.flatMap { agent(id: $0) }?.taskId
    }

    func openNotification(_ target: NotificationTarget?) {
        switch target {
        case .chat(let projectID, let taskID):
            runDetailIDs[projectID] = nil
            selection = .project(projectID)
            tabs[projectID] = .lead
            showRequest(id: taskID, inProjectID: projectID)
        case .inboxItem(let id):
            guard let item = try? database.inboxItem(id: id) else {
                selection = .inbox
                return
            }
            openInboxItem(item)
        case nil:
            selection = .inbox
        }
    }

    func answerInboxQuestion(item: InboxItem, text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = item.id, !reply.isEmpty else { return }
        do {
            try database.resolveInboxItem(id: id, response: reply)
            if let agentID = item.agentId, let agent = try database.agent(id: agentID) {
                agents.session(for: agent)?.send(reply)
            }
        } catch {
            alert = AppAlert(title: "Couldn’t send the answer", message: error.localizedDescription)
        }
    }

    func answerPermission(_ item: InboxItem, allow: Bool) {
        guard let id = item.id else { return }
        do {
            try agents.answerPermission(inboxItemId: id, allow: allow)
        } catch {
            alert = AppAlert(title: "Couldn’t answer “\(item.title)”", message: error.localizedDescription)
        }
    }

    func answerPermission(_ card: LeadMessage, decision: PermissionDecision) {
        guard let requestID = card.permissionRequestId else { return }
        do {
            try agents.answerPermission(requestId: requestID, decision: decision)
            leadChatRevision += 1
        } catch {
            alert = AppAlert(title: "Couldn’t answer the permission request", message: error.localizedDescription)
        }
    }

    func dismissInboxItem(_ item: InboxItem) {
        guard let id = item.id else { return }
        do {
            try database.resolveInboxItem(id: id, status: .dismissed)
        } catch {
            alert = AppAlert(title: "Couldn’t dismiss “\(item.title)”", message: error.localizedDescription)
        }
    }

    func openInboxItem(_ item: InboxItem) {
        if item.kind == .pinReview {
            selection = .project(item.projectId)
            tabs[item.projectId] = .changes
        } else if item.runId == nil, let taskID = item.agentId.flatMap({ agent(id: $0) })?.taskId {
            selection = .project(item.projectId)
            showRequest(id: taskID, inProjectID: item.projectId)
            tabs[item.projectId] = .lead
        } else {
            openLead(forRun: item.runId, in: item.projectId)
        }
    }

    static let needsYouKinds: Set<InboxKind> = [.question, .planApproval, .approval, .permission]

    var needsYouItems: [InboxItem] {
        inbox.items.filter { Self.needsYouKinds.contains($0.kind) }
    }

    func runNeedsYou(_ run: Run) -> Bool {
        if run.status == .waitingOnYou { return true }
        guard let runID = run.id else { return false }
        return needsYouItems.contains { $0.runId == runID }
    }

    func agentNeedsYou(_ agent: Agent) -> Bool {
        guard let agentID = agent.id else { return false }
        return needsYouItems.contains { $0.agentId == agentID }
    }

    func stepNeedsYou(_ status: RunStepStatus, in run: Run, agentIDs: [Int64] = []) -> Bool {
        switch status {
        case .waitingOnYou:
            return true
        case .running:
            if runNeedsYou(run) { return true }
            let items = needsYouItems
            return agentIDs.contains { id in items.contains { $0.agentId == id } }
        case .succeeded, .failed, .cancelled, .interrupted:
            return false
        }
    }

    func displayStatus(of agent: Agent) -> AgentStatus {
        agentNeedsYou(agent) ? .needsInput : agent.status
    }

    func needsYouTaskIDs() -> Set<Int64> {
        var taskIDs: Set<Int64> = []
        for item in needsYouItems {
            if let runID = item.runId, let run = liveRun(id: runID) {
                taskIDs.insert(run.taskId)
            } else if let taskID = item.agentId.flatMap({ agent(id: $0) })?.taskId {
                taskIDs.insert(taskID)
            }
        }
        return taskIDs
    }

    func requestNeedsYou(_ task: ProjectTask, latestRun: Run?, needsYouTaskIDs: Set<Int64>) -> Bool {
        if let latestRun, runNeedsYou(latestRun) { return true }
        return task.id.map(needsYouTaskIDs.contains) == true
    }

    func runTitle(for item: InboxItem) -> String? {
        guard let runID = item.runId else { return nil }
        if let live = engine.runs[runID] { return live.title }
        return (try? database.run(id: runID))?.title
    }
}

@MainActor
final class InboxNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (@MainActor (NotificationTarget?) -> Void)?
    private var hasRequestedAuthorization = false
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ items: [InboxItem], projectName: (Int64) -> String?) {
        for item in items {
            guard let id = item.id else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.subtitle = [projectName(item.projectId), Self.kindTitle(item.kind)].compactMap(\.self).joined(separator: " · ")
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "project-\(item.projectId)"
            content.userInfo = NotificationTarget.inboxItem(id: id).userInfo
            center.add(UNNotificationRequest(identifier: "inbox-\(id)", content: content, trigger: nil))
        }
    }

    func post(_ notifications: [ChatNotification], projectName: (Int64) -> String?) {
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.subtitle = [projectName(notification.projectId), Self.eventTitle(notification.event)].compactMap(\.self).joined(separator: " · ")
            content.body = notification.body
            content.sound = .default
            content.threadIdentifier = "project-\(notification.projectId)"
            content.userInfo = NotificationTarget.chat(projectId: notification.projectId, taskId: notification.taskId).userInfo
            center.add(UNNotificationRequest(identifier: notification.dedupeKey, content: content, trigger: nil))
        }
    }

    static func eventTitle(_ event: ChatNotificationEvent) -> String {
        switch event {
        case .permissionCard: "Permission request"
        case .runProposal: "Run proposal"
        case .leadReply: "Lead reply"
        case .runFinished: "Run finished"
        }
    }

    static func kindTitle(_ kind: InboxKind) -> String {
        switch kind {
        case .question: "Question"
        case .planApproval: "Plan approval"
        case .pinReview: "Pin review"
        case .approval: "Approval"
        case .failure: "Failure"
        case .notice: "Notice"
        case .loopLimit: "Loop limit"
        case .budget: "Budget"
        case .gate: "Gate findings"
        case .permission: "Permission"
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            NSApp.activate()
            onOpen?(target)
        }
    }
}
