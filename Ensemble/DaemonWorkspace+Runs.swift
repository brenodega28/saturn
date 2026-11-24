import EnsembleCore
import Foundation

struct RunDetailSnapshot {
    var run: Run
    var task: Chat?
    var workflow: WorkflowDefinition?
    var steps: [RunStep]
    var state: RunEngineState
    var agents: [Agent]
    var requests: [ChatRequest]
    var graph: RunGraph?
    var history: RunHistory?

    var hold: RunHold? { state.hold }
}

extension DaemonWorkspace {
    func openRunDetail(_ run: Run) {
        guard let runID = run.id else { return }
        openRunDetail(runID: runID, in: run.projectId)
    }

    func openRunDetail(runID: Int64, in projectID: Int64) {
        showPage(.run(runID, daemon: id))
    }

    func runDetailID(in project: Project) -> Int64? {
        project.id.flatMap { runDetailIDs[$0] }
    }

    func closeRunDetail(in project: Project) {
        guard let page = app.activePage, case .run = page.kind else { return }
        pages.close(page.id)
    }

    func openRunInLead(_ run: Run) {
        showRun(run)
    }

    func openAgentSession(_ agent: Agent, in project: Project) {
        guard let projectID = project.id, let agentID = agent.id else { return }
        selectedAgents[projectID] = agentID
        showPage(.agent(agentID, daemon: id))
    }

    func liveRun(id: Int64) -> Run? {
        (try? database.run(id: id)) ?? nil
    }

    func runDetailSnapshot(runID: Int64) -> RunDetailSnapshot? {
        guard let run = liveRun(id: runID) else { return nil }
        let workflow = runWorkflow(run)
        let steps = (try? database.runSteps(runId: runID)) ?? []
        let state = (try? database.engineState(runId: runID)) ?? RunEngineState()
        let agents = (try? database.agents(inRun: runID)) ?? []
        return RunDetailSnapshot(
            run: run, task: requestTask(for: run), workflow: workflow, steps: steps, state: state, agents: agents,
            requests: (try? database.chatRequests(runId: runID)) ?? [],
            graph: workflow.map { RunGraph(workflow: $0, run: run, steps: steps, hold: state.hold) },
            history: workflow.map { RunHistory(workflow: $0, steps: steps, agents: agents) }
        )
    }
}
