import AppKit
import EnsembleCore
import Foundation
import UserNotifications

extension AppModel {
    var inboxCount: Int { inbox.count }

    func startInbox() {
        inboxNotifier.onOpen = { [weak self] in self?.selection = .inbox }
        inbox.onNewItems = { [weak self] items in
            guard let self else { return }
            inboxNotifier.post(items, projectName: { [weak self] id in self?.project(withID: id)?.name })
        }
        inbox.start()
        inboxNotifier.requestAuthorization()
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

    static let needsYouKinds: Set<InboxKind> = [.question, .planApproval, .approval]

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
    var onOpen: (@MainActor () -> Void)?
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
            center.add(UNNotificationRequest(identifier: "inbox-\(id)", content: content, trigger: nil))
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
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate()
            onOpen?()
        }
    }
}
