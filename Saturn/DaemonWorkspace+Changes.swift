import SaturnCore
import Foundation

extension DaemonWorkspace {
    func reviewableRuns(in project: Project) -> [Run] {
        guard let id = project.id else { return [] }
        _ = connection.revision
        return ((try? database.runs(projectId: id)) ?? []).reversed()
    }

    func openChanges(for run: Run) {
        guard let runID = run.id else { return }
        changesRunSelections[run.projectId] = runID
        showPage(.tool(.changes, project: ref(run.projectId)))
    }

    func holdsForApproval(_ run: Run) -> Bool {
        guard let id = run.id else { return false }
        return connection.waitingReason(runID: id)?.reason == .approval
    }

    func loadChanges(for run: Run, in project: Project) async -> RunChangeSet? {
        guard let runID = run.id, let git = git(for: project) else { return nil }
        let agents = (try? database.agents(inRun: runID)) ?? []
        return await RunChanges(git: git).load(runId: runID, agents: agents, repository: project.url)
    }

    func agents(inRun run: Run) -> [Agent] {
        guard let id = run.id else { return [] }
        return (try? database.agents(inRun: id)) ?? []
    }

    func reviews(for run: Run) -> RunReviews {
        guard let id = run.id else { return .empty }
        let steps = (try? database.runSteps(runId: id)) ?? []
        return RunReviews.derive(run: run, steps: steps, agents: agents(inRun: run))
    }

    func latestGateReport(in run: Run) -> GateReport? {
        guard let id = run.id else { return nil }
        let steps = (try? database.runSteps(runId: id)) ?? []
        return steps.reversed().lazy.compactMap { step in
            step.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.gates
        }.first
    }

    func reviewerTitle(_ review: FileReview, in project: Project) -> String {
        if review.reviewer == review.role, let role = review.role, let name = config(for: project).role(role)?.name {
            return name
        }
        return review.reviewer
    }

    func viewedPaths(in run: Run, current: [ChangedPath]) -> Set<String> {
        guard let id = run.id else { return [] }
        return (try? database.viewedPaths(runId: id, current: current)) ?? []
    }

    func setViewed(_ viewed: Bool, path: ChangedPath, in run: Run) {
        guard let id = run.id else { return }
        dispatch("Couldn’t save the viewed state", CodeCommands.SetViewed(runID: id, path: path.path, fingerprint: path.fingerprint, viewed: viewed))
    }

    func setPin(_ pin: Pin, status: PinStatus, response: String? = nil) {
        guard let id = pin.id else { return }
        dispatch("Couldn’t update the pin", CodeCommands.UpdatePin(pinID: id, status: status, response: response))
    }

    func addComment(in run: Run, branchAgentId: Int64?, file: String, side: PinSide, lines: ClosedRange<Int>, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = run.id, !text.isEmpty else { return }
        dispatch("Couldn’t save the comment", CodeCommands.CreateComment(
            runID: id, branchAgentID: branchAgentId, file: file, side: side,
            startLine: lines.lowerBound, endLine: lines.upperBound, text: text
        ))
    }

    func editComment(_ pin: Pin, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = pin.id, !text.isEmpty else { return }
        dispatch("Couldn’t update the comment", CodeCommands.UpdateComment(pinID: id, text: text))
    }

    func deleteComment(_ pin: Pin) {
        guard let id = pin.id else { return }
        dispatch("Couldn’t delete the comment", CodeCommands.DeletePin(pinID: id))
    }

    @discardableResult
    func askAgent(about pin: Pin, question: String) -> Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session = session(forAgentID: pin.agentId) else { return false }
        session.send("""
        About your pin “\(pin.title)” on \(pin.file):\(pin.lineLabel):
        \(text)
        """)
        return true
    }

    @discardableResult
    func askToCombine(_ path: ChangedPath, agentID: Int64?) -> Bool {
        guard let session = session(forAgentID: agentID) else { return false }
        let others = path.diffs.filter { $0.agentId != agentID }.map { "\(displayName(of: $0)) (\($0.branch))" }
        if others.isEmpty {
            session.send("""
            \(path.path) can’t merge cleanly: your branch and the base branch change the same lines. \
            Merge the base branch into your branch, resolve the conflict keeping both intents, run the tests and commit.
            """)
        } else {
            session.send("""
            \(path.path) can’t merge cleanly: your branch and \(others.joined(separator: ", ")) change the same lines. \
            Combine both changes in your branch so they merge cleanly, keep both behaviours, run the tests and commit.
            """)
        }
        return true
    }

    func approveAllPins(in run: Run) {
        guard let id = run.id else { return }
        let approving = holdsForApproval(run)
        let requestID = connection.hold(runID: id)?.requestId
        Task {
            guard await command("Couldn’t approve the pins", CodeCommands.ApproveOpenPins(runID: id)) != nil, approving else { return }
            await command("Couldn’t approve the run", RunCommands.ResolveApproval(runID: id, approved: true, requestID: requestID))
        }
    }

    func sendChangesBack(in run: Run, pins: [Pin]) {
        let names = Dictionary(agents(inRun: run).compactMap { agent in agent.id.map { ($0, displayName(of: agent)) } }, uniquingKeysWith: { first, _ in first })
        let summary = Pin.changeRequestSummary(pins, agentNames: names)
        guard !summary.isEmpty else { return }
        guard let id = run.id else { return }
        dispatch("Couldn’t send the changes back", RunCommands.ResolveApproval(runID: id, approved: false, note: summary, requestID: connection.hold(runID: id)?.requestId))
    }

    func displayName(of diff: BranchFileDiff) -> String {
        session(forAgentID: diff.agentId).map { displayName(of: $0.agent) } ?? diff.agentName
    }

    private func session(forAgentID id: Int64?) -> LiveAgentSession? {
        id.flatMap(connection.session(agentID:))
    }
}
