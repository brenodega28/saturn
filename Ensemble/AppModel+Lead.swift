import EnsembleCore
import Foundation

enum LeadSelection: Hashable {
    case newRequest
    case run(Int64)
}

extension AppModel {
    func leadRoles(in project: Project) -> [RoleDefinition] {
        config(for: project).roles.filter(\.canSpawn)
    }

    func leadRuns(in project: Project) -> [Run] {
        guard let id = project.id else { return [] }
        _ = engine.runs
        _ = engine.holds
        return Run.leadOrdering((try? database.runs(projectId: id)) ?? [])
    }

    func activeLeadRuns(in project: Project) -> [Run] {
        guard let id = project.id else { return [] }
        return Run.leadOrdering(engine.activeRuns(projectID: id))
    }

    func selectedLeadRun(in project: Project) -> Run? {
        guard let projectID = project.id else { return nil }
        switch leadSelections[projectID] {
        case .newRequest:
            return nil
        case .run(let runID):
            return engine.runs[runID] ?? (try? database.run(id: runID)) ?? nil
        case nil:
            return activeLeadRuns(in: project).first
        }
    }

    func showRun(_ run: Run) {
        guard let runID = run.id else { return }
        leadSelections[run.projectId] = .run(runID)
        selection = .project(run.projectId)
        tabs[run.projectId] = .lead
    }

    func startNewLeadRequest(in project: Project) {
        guard let id = project.id else { return }
        leadSelections[id] = .newRequest
    }

    @discardableResult
    func submitLeadRequest(_ text: String, lead: RoleDefinition?, workflow: WorkflowDefinition, in project: Project) -> Run? {
        guard let projectID = project.id, let draft = LeadRequest.task(text: text, projectID: projectID, workflowID: workflow.id) else { return nil }
        let leadIDs = Set(leadRoles(in: project).map(\.id))
        let assigned = lead.map { workflow.assigningLead($0.id, replacing: leadIDs) } ?? workflow
        do {
            try ensureWithinBudget(project)
            let task = try database.insert(draft)
            let run = try engine.start(task: task, workflow: assigned, project: project)
            showRun(run)
            return run
        } catch {
            alert = AppAlert(title: "Couldn’t start the run", message: error.localizedDescription)
            return nil
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
