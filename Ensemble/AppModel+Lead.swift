import EnsembleCore
import Foundation

enum LeadSelection: Hashable {
    case newRequest
    case request(Int64)
}

struct RequestThreadData {
    var thread: RequestThread
    var timelines: [Int64: RunTimeline]
    var leadRole: RoleDefinition?
    var leadName: String
}

extension AppModel {
    func leadRole(in project: Project) -> RoleDefinition {
        config(for: project).lead
    }

    func activeLeadRuns(in project: Project) -> [Run] {
        guard let id = project.id else { return [] }
        return Run.leadOrdering(engine.activeRuns(projectID: id))
    }

    func leadRequests(in project: Project) -> [ProjectTask] {
        guard let id = project.id else { return [] }
        _ = engine.runs
        _ = engine.holds
        _ = leadChatRevision
        return (try? database.leadRequests(projectId: id)) ?? []
    }

    func selectedRequest(in project: Project) -> ProjectTask? {
        guard let projectID = project.id else { return nil }
        switch leadSelections[projectID] {
        case .newRequest:
            return nil
        case .request(let taskID):
            return try? database.task(id: taskID)
        case nil:
            let activeTaskIDs = Set(activeLeadRuns(in: project).map(\.taskId))
            return LeadRequest.partition(leadRequests(in: project)).open.first { $0.id.map(activeTaskIDs.contains) == true }
        }
    }

    func requestHasActiveRun(_ task: ProjectTask) -> Bool {
        guard let id = task.id else { return false }
        _ = engine.runs
        return ((try? database.runs(taskId: id)) ?? []).contains { run in (run.id.flatMap { engine.runs[$0] } ?? run).isActive }
    }

    func closeRequest(_ task: ProjectTask, as reason: RequestCloseReason, in project: Project) async {
        guard let git else {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
            return
        }
        do {
            _ = try await leadChat.close(task, as: reason, in: project, git: git)
        } catch {
            alert = AppAlert(title: "Couldn’t close the request", message: error.localizedDescription)
            return
        }
        leadChatRevision += 1
        if selectedAgent(in: project) == nil { select(nil, in: project) }
        guard let projectID = project.id else { return }
        let next = LeadRequest.partition(leadRequests(in: project)).open.first { $0.id != task.id }
        leadSelections[projectID] = next?.id.map(LeadSelection.request) ?? .newRequest
    }

    func deleteAgentsOfClosedRequests() async {
        guard let git else { return }
        for project in openProjects {
            await leadChat.deleteAgentsOfClosedRequests(in: project, git: git)
        }
    }

    func latestRun(of task: ProjectTask) -> Run? {
        guard let id = task.id, let run = (try? database.runs(taskId: id))?.last else { return nil }
        return run.id.flatMap { engine.runs[$0] } ?? run
    }

    func showRun(_ run: Run) {
        showRequest(id: run.taskId, inProjectID: run.projectId)
        selection = .project(run.projectId)
        tabs[run.projectId] = .lead
    }

    func showRequest(_ task: ProjectTask) {
        guard let id = task.id else { return }
        showRequest(id: id, inProjectID: task.projectId)
    }

    func showRequest(id requestID: Int64, inProjectID id: Int64) {
        leadSelections[id] = .request(requestID)
        showLeadChat(inProjectID: id)
    }

    func startNewLeadRequest(in project: Project) {
        guard let id = project.id else { return }
        leadSelections[id] = .newRequest
        showLeadChat(inProjectID: id)
    }

    private func showLeadChat(inProjectID id: Int64) {
        requestPageProjectIDs.remove(id)
        if case .agent = chatTargets[id] {
            chatTargets[id] = nil
        }
    }

    func showRequestPage(inProjectID id: Int64) {
        runDetailIDs[id] = nil
        tabs[id] = .lead
        selection = .project(id)
        requestPageProjectIDs.insert(id)
    }

    func isShowingRequestPage(in project: Project) -> Bool {
        project.id.map(requestPageProjectIDs.contains) == true
    }

    func selectedOpenRequestID(inProjectID id: Int64) -> Int64? {
        guard case .request(let requestID) = leadSelections[id], let project = project(withID: id),
              directChatSession(in: project) == nil,
              LeadRequest.partition(leadRequests(in: project)).open.contains(where: { $0.id == requestID }) else { return nil }
        return requestID
    }

    func requestStatusLabel(of request: ProjectTask, latestRun: Run?, needsYouTaskIDs: Set<Int64>) -> String {
        if pendingApprovalCount(of: request) > 0 { return "Needs approval" }
        if requestNeedsYou(request, latestRun: latestRun, needsYouTaskIDs: needsYouTaskIDs) { return "Needs you" }
        guard let latestRun else { return "Chat" }
        let label = statusLabel(of: latestRun)
        return latestRun.isActive ? (currentStepTitle(of: latestRun) ?? label) : label
    }

    func leadSession(for task: ProjectTask) -> AgentSession? {
        leadChat.leadSession(for: task)
    }

    func workingSessions(for task: ProjectTask) -> [AgentSession] {
        _ = agents.usageRevision
        return leadChat.workingSessions(for: task)
    }

    func leadSendTarget(for request: ProjectTask?, in project: Project) -> PendingSendTarget? {
        project.id.map { .lead(project: $0, request: request?.id) }
    }

    func holdLeadMessage(_ message: PendingMessage, lead: RoleDefinition?, to request: ProjectTask?, in project: Project) {
        guard let target = leadSendTarget(for: request, in: project) else { return }
        holdSend(message, to: target) { [weak self] held in
            guard let self else { return }
            let delivery = HeldSend(id: UUID(), target: target, message: held, date: .now, isCancellable: false)
            deliveringSends.append(delivery)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = request?.id.flatMap { try? self.database.task(id: $0) } ?? request
                let sent = await sendLeadMessage(held.text, attachments: held.attachments, lead: lead, to: current, in: project)
                deliveringSends.removeAll { $0.id == delivery.id }
                if !sent {
                    pendingSends.returnToComposer(held, for: target)
                }
            }
        }
    }

    @discardableResult
    func sendLeadMessage(_ text: String, attachments: [ChatAttachment] = [], lead: RoleDefinition?, to request: ProjectTask?, in project: Project) async -> Bool {
        do {
            if let request {
                try await leadChat.send(text, attachments: attachments, to: request, in: project)
            } else {
                let request = try await leadChat.createRequest(text, attachments: attachments, in: project)
                if selectedRequest(in: project) == nil, directChatSession(in: project) == nil {
                    showRequest(request)
                }
            }
            leadChatRevision += 1
            return true
        } catch {
            alert = AppAlert(title: "Couldn’t send the message", message: error.localizedDescription)
            return false
        }
    }

    func startProposal(_ proposal: LeadMessage, in project: Project) {
        if (try? database.task(id: proposal.taskId))?.isClosed == true {
            alert = AppAlert(title: "Couldn’t start the run", message: "This request is closed. Send a message to reopen it first.")
            return
        }
        do {
            try ensureWithinBudget(project)
            try leadChat.start(proposal, in: project)
            leadChatRevision += 1
        } catch {
            alert = AppAlert(title: "Couldn’t start the run", message: error.localizedDescription)
        }
    }

    func dismissProposal(_ proposal: LeadMessage) {
        do {
            try leadChat.dismiss(proposal)
            leadChatRevision += 1
        } catch {
            alert = AppAlert(title: "Couldn’t dismiss the proposal", message: error.localizedDescription)
        }
    }

    func requestThread(for task: ProjectTask, in project: Project) -> RequestThreadData? {
        guard let taskID = task.id else { return nil }
        let runs = ((try? database.runs(taskId: taskID)) ?? []).map { run in run.id.flatMap { engine.runs[$0] } ?? run }
        var timelines: [Int64: RunTimeline] = [:]
        for run in runs {
            if let id = run.id, let timeline = timeline(for: run) { timelines[id] = timeline }
        }
        let lead = try? database.leadAgent(taskId: taskID)
        let leadRole = lead.flatMap { config(for: project).role($0.role) } ?? runs.last.flatMap { leadRole(for: $0, in: project) } ?? leadRole(in: project)
        let messages = (try? database.leadMessages(taskId: taskID)) ?? []
        var thread = RequestThread(
            task: task,
            messages: messages,
            runs: runs,
            timelines: timelines,
            questions: (try? database.requestQuestions(taskId: taskID)) ?? [],
            heldRunIDs: Set(runs.compactMap(\.id).filter { engine.holds[$0] != nil })
        )
        thread.items = Self.placingPermissions(messages.filter { $0.kind == .permission }, in: thread.items)
        return RequestThreadData(thread: thread, timelines: timelines, leadRole: leadRole, leadName: lead.map { AgentNaming.displayName(of: $0) } ?? leadRole.name)
    }

    static func placingPermissions(_ cards: [LeadMessage], in items: [RequestThread.Item]) -> [RequestThread.Item] {
        guard !cards.isEmpty else { return items }
        let liveStart = items.firstIndex(where: \.isLive) ?? items.endIndex
        var settled = Array(items[..<liveStart])
        let sorted = cards.sorted { $0.createdAt < $1.createdAt }
        for card in sorted where card.permissionStatus.map({ $0 != .pending }) == true {
            let index = settled.firstIndex { item in date(of: item).map { $0 > card.createdAt } ?? false } ?? settled.endIndex
            settled.insert(.message(card), at: index)
        }
        let pending = sorted.filter { $0.permissionStatus.map { $0 == .pending } ?? true }.map(RequestThread.Item.message)
        return settled + pending + items[liveStart...]
    }

    private static func date(of item: RequestThread.Item) -> Date? {
        switch item {
        case .request(let task): task.createdAt
        case .message(let message): message.createdAt
        case .runStarted(let run): run.startedAt
        case .step(_, let entry): entry.endedAt ?? entry.startedAt
        case .answeredQuestion(let question): question.resolvedAt ?? question.createdAt
        case .runEnded(let run): run.endedAt
        case .openQuestion, .hold: nil
        }
    }

    func runWorkflow(_ run: Run) -> WorkflowDefinition? {
        try? engine.workflow(for: run)
    }

    func timeline(for run: Run) -> RunTimeline? {
        guard let workflow = runWorkflow(run) else { return nil }
        return try? database.timeline(for: run, workflow: workflow)
    }

    func currentStepTitle(of run: Run) -> String? {
        guard let step = run.currentStep else { return nil }
        let title = runWorkflow(run).map { RunTimeline.title(ofStep: step, in: $0) } ?? step
        guard let id = run.id, engine.waitingForCapacity.contains(id) else { return title }
        return title + " · waiting for your reviews to clear"
    }

    func leadRole(for run: Run, in project: Project) -> RoleDefinition? {
        runWorkflow(run)?.hasLead == true ? leadRole(in: project) : nil
    }

    func requestTask(for run: Run) -> ProjectTask? {
        try? database.task(id: run.taskId)
    }

    func agent(id: Int64) -> Agent? {
        try? database.agent(id: id)
    }

    func answerQuestion(item: InboxItem, text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let itemID = item.id, !answer.isEmpty else { return }
        do {
            try database.resolveInboxItem(id: itemID, response: answer)
        } catch {
            alert = AppAlert(title: "Couldn’t send the answer", message: error.localizedDescription)
            return
        }
        if let agentID = item.agentId, let agent = agent(id: agentID) {
            agents.session(for: agent)?.send(answer)
        }
    }

    func performRunAction(_ failureTitle: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = AppAlert(title: failureTitle, message: error.localizedDescription)
        }
    }

    func performRunAction(_ failureTitle: String, _ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            alert = AppAlert(title: failureTitle, message: error.localizedDescription)
        }
    }
}

extension AppModel {
    func runGroupDescription(_ run: Run) -> (workflow: String?, step: String?) {
        let live = run.id.flatMap { engine.runs[$0] } ?? run
        return (runWorkflow(live)?.displayName ?? live.workflow, live.isActive ? currentStepTitle(of: live) : live.status.label)
    }
}
