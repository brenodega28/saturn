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
    func leadRoles(in project: Project) -> [RoleDefinition] {
        config(for: project).roles.filter(\.canSpawn)
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
        guard let projectID = project.id else { return }
        let next = LeadRequest.partition(leadRequests(in: project)).open.first { $0.id != task.id }
        leadSelections[projectID] = next?.id.map(LeadSelection.request) ?? .newRequest
    }

    func latestRun(of task: ProjectTask) -> Run? {
        guard let id = task.id, let run = (try? database.runs(taskId: id))?.last else { return nil }
        return run.id.flatMap { engine.runs[$0] } ?? run
    }

    func showRun(_ run: Run) {
        leadSelections[run.projectId] = .request(run.taskId)
        selection = .project(run.projectId)
        tabs[run.projectId] = .lead
    }

    func showRequest(_ task: ProjectTask) {
        guard let id = task.id else { return }
        leadSelections[task.projectId] = .request(id)
    }

    func startNewLeadRequest(in project: Project) {
        guard let id = project.id else { return }
        leadSelections[id] = .newRequest
    }

    func leadSession(for task: ProjectTask) -> AgentSession? {
        leadChat.leadSession(for: task)
    }

    @discardableResult
    func sendLeadMessage(_ text: String, lead: RoleDefinition?, in project: Project) async -> Bool {
        do {
            if let request = selectedRequest(in: project) {
                let role = lead ?? leadSession(for: request).flatMap { config(for: project).role($0.agent.role) } ?? leadRoles(in: project).first
                try await leadChat.send(text, to: request, lead: role, in: project)
            } else {
                let request = try await leadChat.createRequest(text, lead: lead ?? leadRoles(in: project).first, in: project)
                showRequest(request)
            }
            leadChatRevision += 1
            return true
        } catch {
            alert = AppAlert(title: "Couldn’t send the message", message: error.localizedDescription)
            return false
        }
    }

    func startProposal(_ proposal: LeadMessage, in project: Project) {
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
        let leadRole = lead.flatMap { config(for: project).role($0.role) } ?? runs.last.flatMap { leadRole(for: $0, in: project) }
        let thread = RequestThread(
            task: task,
            messages: (try? database.leadMessages(taskId: taskID)) ?? [],
            runs: runs,
            timelines: timelines,
            questions: (try? database.requestQuestions(taskId: taskID)) ?? [],
            heldRunIDs: Set(runs.compactMap(\.id).filter { engine.holds[$0] != nil })
        )
        return RequestThreadData(thread: thread, timelines: timelines, leadRole: leadRole, leadName: lead?.name ?? leadRole?.name ?? "Lead")
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
        guard let workflow = runWorkflow(run) else { return step }
        return RunTimeline.title(ofStep: step, in: workflow)
    }

    func leadRole(for run: Run, in project: Project) -> RoleDefinition? {
        let leads = leadRoles(in: project)
        guard let id = runWorkflow(run)?.leadRole(among: Set(leads.map(\.id))) else { return nil }
        return leads.first { $0.id == id }
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
