import AppKit
import EnsembleCore
import Foundation
import UserNotifications

extension DaemonWorkspace {
    var needsYouCount: Int { requests.count }

    func startRequests() {
        let notifier = app.requestNotifier
        requests.onNewItems = { [weak self] items in
            guard let self else { return }
            let visibleChat = visibleChat()
            let wanted = items.filter { item in
                NotificationPreferences.isEnabled(item.kind)
                    && !NotificationSuppression.shouldSuppress(
                        appActive: NSApp.isActive, visibleChat: visibleChat, target: (item.projectId, taskID(of: item))
                    )
            }
            notifier.post(wanted, daemon: id, projectName: { [weak self] id in self?.projectLabel(id) })
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
            notifier.post(wanted, daemon: id, projectName: { [weak self] id in self?.projectLabel(id) })
        }
        requests.start()
        chatNotifications.start()
        pendingPermissions.start()
    }

    private func projectLabel(_ projectID: Int64) -> String? {
        guard let name = project(withID: projectID)?.name else { return nil }
        return isRemote ? "\(name) · \(displayName)" : name
    }

    func visibleChat() -> (projectId: Int64, taskId: Int64)? {
        guard case .chat(let taskID?, let project) = app.activePage?.kind, project.daemon == id,
              !requestPageProjectIDs.contains(project.id) else { return nil }
        return (project.id, taskID)
    }

    func taskID(of item: ChatRequest) -> Int64? {
        item.taskId
    }

    func openNotification(_ target: NotificationTarget?) {
        switch target {
        case .chat(let projectID, let taskID):
            showRequest(id: taskID, inProjectID: projectID)
        case .chatRequest(let id):
            guard let item = try? database.chatRequest(id: id) else { return }
            openRequest(item)
        case nil:
            return
        }
    }

    func answerPermission(_ item: ChatRequest, allow: Bool) {
        guard let id = item.id else { return }
        dispatch("Couldn’t answer “\(item.title)”", ApprovalCommands.AnswerPermission(chatRequestID: id, decision: allow ? .allow : .deny))
    }

    func answerPermission(_ card: LeadMessage, decision: PermissionDecision) {
        guard let requestID = card.permissionRequestId else { return }
        dispatch("Couldn’t answer the permission request", ApprovalCommands.AnswerPermission(permissionRequestID: requestID, decision: decision))
        leadChatRevision += 1
    }

    func dismissRequest(_ item: ChatRequest) {
        guard let id = item.id else { return }
        dispatch("Couldn’t dismiss “\(item.title)”", ApprovalCommands.Dismiss(requestID: id))
    }

    func openRequest(_ item: ChatRequest) {
        if item.kind == .pinReview {
            showPage(.tool(.changes, project: ref(item.projectId)))
        } else if let taskID = item.taskId {
            showRequest(id: taskID, inProjectID: item.projectId)
        }
    }

    static let needsYouKinds: Set<ChatRequestKind> = [.question, .planApproval, .approval, .permission]

    var needsYouItems: [ChatRequest] {
        requests.items.filter { Self.needsYouKinds.contains($0.kind) }
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
        Set(needsYouItems.compactMap(\.taskId))
    }

    func pendingApprovalCount(of task: Chat) -> Int {
        task.id.map(pendingPermissions.count(taskId:)) ?? 0
    }

    func projectHasPendingApprovals(_ project: Project) -> Bool {
        project.id.map(pendingPermissions.count(projectId:)).map { $0 > 0 } ?? false
    }

    func requestNeedsYou(_ task: Chat, latestRun: Run?, needsYouTaskIDs: Set<Int64>) -> Bool {
        if let latestRun, runNeedsYou(latestRun) { return true }
        return task.id.map(needsYouTaskIDs.contains) == true
    }

    func runTitle(for item: ChatRequest) -> String? {
        guard let runID = item.runId else { return nil }
        return (try? database.run(id: runID))?.title
    }
}

@MainActor
final class RequestNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case allow
        case deny
        case approve
    }

    static let permissionCategory = "permission"
    static let proposalCategory = "proposal"
    nonisolated static let messageKey = "messageId"
    nonisolated static let daemonKey = "daemonId"

    var onOpen: (@MainActor (NotificationTarget?, DaemonID?) -> Void)?
    var onAction: (@MainActor (Action, Int64, DaemonID?) -> Void)?
    private var hasRequestedAuthorization = false
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [
                UNNotificationAction(identifier: Action.allow.rawValue, title: "Allow in this chat"),
                UNNotificationAction(identifier: Action.deny.rawValue, title: "Deny", options: .destructive),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.proposalCategory, actions: [
                UNNotificationAction(identifier: Action.approve.rawValue, title: "Approve & start"),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ items: [ChatRequest], daemon: DaemonID, projectName: (Int64) -> String?) {
        for item in items {
            guard let id = item.id else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.subtitle = [projectName(item.projectId), Self.kindTitle(item.kind)].compactMap(\.self).joined(separator: " · ")
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = item.taskId.map { "chat-\($0)" } ?? "project-\(item.projectId)"
            var info = NotificationTarget.chatRequest(id: id).userInfo
            info[Self.daemonKey] = daemon.uuidString
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: "inbox-\(daemon.uuidString)-\(id)", content: content, trigger: nil))
        }
    }

    func post(_ notifications: [ChatNotification], daemon: DaemonID, projectName: (Int64) -> String?) {
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.subtitle = [projectName(notification.projectId), Self.eventTitle(notification.event)].compactMap(\.self).joined(separator: " · ")
            content.body = notification.body
            content.sound = .default
            content.threadIdentifier = "chat-\(notification.taskId)"
            var info = NotificationTarget.chat(projectId: notification.projectId, taskId: notification.taskId).userInfo
            info[Self.daemonKey] = daemon.uuidString
            if let messageID = notification.messageId {
                info[Self.messageKey] = messageID
                switch notification.event {
                case .permissionCard: content.categoryIdentifier = Self.permissionCategory
                case .runProposal: content.categoryIdentifier = Self.proposalCategory
                case .leadReply, .runFinished: break
                }
            }
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: "\(daemon.uuidString)-\(notification.dedupeKey)", content: content, trigger: nil))
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

    static func kindTitle(_ kind: ChatRequestKind) -> String {
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
        let info = response.notification.request.content.userInfo
        let daemon = (info[Self.daemonKey] as? String).flatMap(UUID.init(uuidString:))
        if let action = Action(rawValue: response.actionIdentifier), let messageID = (info[Self.messageKey] as? NSNumber)?.int64Value ?? info[Self.messageKey] as? Int64 {
            await MainActor.run { onAction?(action, messageID, daemon) }
            return
        }
        let target = NotificationTarget(userInfo: info)
        await MainActor.run {
            NSApp.activate()
            onOpen?(target, daemon)
        }
    }
}

extension AppModel {
    func openNotification(_ target: NotificationTarget?, on daemon: DaemonID?) {
        workspace(for: daemon ?? localID)?.openNotification(target)
    }
}

extension DaemonWorkspace {
    func performNotificationAction(_ action: RequestNotifier.Action, messageID: Int64) {
        guard let message = try? database.leadMessage(id: messageID) else { return }
        switch action {
        case .allow: answerPermission(message, decision: .allow)
        case .deny: answerPermission(message, decision: .deny)
        case .approve:
            guard let project = project(withID: message.projectId) else { return }
            startProposal(message, in: project)
        }
    }
}
