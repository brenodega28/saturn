import EnsembleCore
import Foundation

extension AppModel {
    private func heldRequestID(_ run: Run) -> Int64? {
        run.id.flatMap { connection.hold(runID: $0)?.requestId }
    }

    func approvePlan(_ run: Run, plan: Plan) {
        guard let id = run.id else { return }
        dispatch("Couldn’t approve the plan", RunCommands.ApprovePlan(runID: id, plan: plan, requestID: heldRequestID(run)))
    }

    func rejectPlan(_ run: Run, note: String) {
        guard let id = run.id else { return }
        dispatch("Couldn’t send the plan back", RunCommands.RejectPlan(runID: id, note: note, requestID: heldRequestID(run)))
    }

    func resolveApproval(_ run: Run, approved: Bool, note: String?) {
        guard let id = run.id else { return }
        dispatch("Couldn’t answer the approval", RunCommands.ResolveApproval(runID: id, approved: approved, note: note, requestID: heldRequestID(run)))
    }

    func resolveGates(_ run: Run, proceed: Bool) {
        guard let id = run.id else { return }
        dispatch("Couldn’t answer the gate findings", RunCommands.ResolveGates(runID: id, proceed: proceed, requestID: heldRequestID(run)))
    }

    func resolveLoopLimit(_ run: Run, continueOnce: Bool) {
        guard let id = run.id else { return }
        dispatch("Couldn’t answer the loop limit", RunCommands.ResolveLoopLimit(runID: id, continueOnce: continueOnce, requestID: heldRequestID(run)))
    }

    func resolveBudget(_ run: Run, proceed: Bool, raiseRunBudgetTo budget: Double? = nil) {
        guard let id = run.id else { return }
        dispatch(proceed ? "Couldn’t raise the budget" : "Couldn’t stop the run", RunCommands.ResolveBudget(runID: id, proceed: proceed, raiseRunBudgetTo: budget, requestID: heldRequestID(run)))
    }

    func resolveFailure(_ run: Run, retry: Bool) {
        guard let id = run.id else { return }
        dispatch(retry ? "Couldn’t retry the step" : "Couldn’t end the run", RunCommands.ResolveFailure(runID: id, retry: retry, requestID: heldRequestID(run)))
    }

    func retryStep(_ run: Run) {
        guard let id = run.id else { return }
        dispatch("Couldn’t retry the step", RunCommands.RetryStep(runID: id))
    }

    func pauseRun(_ run: Run) {
        guard let id = run.id else { return }
        dispatch("Couldn’t pause the run", RunCommands.Pause(runID: id))
    }

    func resumeRun(_ run: Run) {
        guard let id = run.id else { return }
        dispatch("Couldn’t resume the run", RunCommands.Resume(runID: id))
    }

    func cancelRun(_ run: Run) {
        guard let id = run.id else { return }
        dispatch("Couldn’t stop the run", RunCommands.Cancel(runID: id))
    }

    func mergeRun(_ run: Run, method: MergeMethod) async {
        guard let id = run.id else { return }
        await command("Couldn’t merge", RunCommands.Merge(runID: id, method: method))
    }

    func pushRun(_ run: Run, baseName: String) async {
        guard let id = run.id else { return }
        await command("Couldn’t push \(baseName)", RunCommands.Push(runID: id))
    }

    func diffInfo(_ run: Run) async -> DiffInfo {
        guard let id = run.id else { return DiffInfo() }
        return (try? await send(RunCommands.DiffSummary(runID: id))) ?? DiffInfo()
    }
}
