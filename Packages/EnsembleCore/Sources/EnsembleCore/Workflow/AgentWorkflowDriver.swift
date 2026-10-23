import Foundation
import GRDB
import Yams

public enum WorkflowDriverError: Error, LocalizedError, Equatable {
    case notReady(String)
    case missingRole(String)
    case agentFailed(agent: String, message: String)
    case missingHandoff(agent: String, tool: String)
    case mergeConflict(branch: String, files: [String])
    case unsafeMerge(String)
    case gitHub(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let reason):
            reason
        case .missingRole(let role):
            "The role “\(role)” doesn’t exist in this project."
        case .agentFailed(let agent, let message):
            "\(agent) failed: \(message)"
        case .missingHandoff(let agent, let tool):
            "\(agent) ended its turn twice without calling \(tool)."
        case .mergeConflict(let branch, let files):
            "Merging \(branch) conflicts in \(files.joined(separator: ", "))."
        case .unsafeMerge(let reason):
            reason
        case .gitHub(let reason):
            reason
        }
    }
}

enum ExpectedHandoff: Equatable {
    case plan
    case verdict
    case result

    var tool: HandoffTool {
        switch self {
        case .plan: .submitPlan
        case .verdict: .submitVerdict
        case .result: .submitResult
        }
    }
}

@MainActor
public final class AgentWorkflowDriver: WorkflowDriver, HandoffSink {
    public let runtime: AgentRuntime
    public var gitProvider: @MainActor () -> GitClient? = { nil }
    public var gitHubProvider: @MainActor () -> GitHubClient? = { nil }
    public var pollInterval: Duration = .milliseconds(250)
    public var memoryUpdater: PinnedMemoryUpdater?

    private var plans: [Int64: Plan] = [:]
    private var verdicts: [Int64: Verdict] = [:]
    private var results: [Int64: String] = [:]
    private var serverStart: Task<EnsembleMCPServer, Error>?

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
        runtime.handoffTools = { [weak self] agent in self?.tools(for: agent) ?? [] }
    }

    public func ensureServer() async throws {
        if runtime.mcpServer != nil { return }
        let start = serverStart ?? Task { try await EnsembleMCPServer.start(sink: self) }
        serverStart = start
        runtime.mcpServer = try await start.value
    }

    func tools(for agent: Agent) -> Set<HandoffTool> {
        let config = (try? runtime.database.project(id: agent.projectId)).flatMap { $0 }.map { ProjectConfigLoader.load(repository: $0.url) }
        let isLead = config?.role(agent.role)?.canSpawn == true
        var leadTools: Set<HandoffTool> = isLead ? HandoffTool.leadTools : []
        if isLead, agent.readOnly, agent.worktreePath == nil { leadTools.insert(.openWorktree) }
        let chatTools: Set<HandoffTool> = agent.taskId == nil ? [] : [.proposeRun, .messageAgent, .askHuman]
        let requestTools = chatTools.union(leadTools)
        guard agent.runId != nil else { return requestTools }
        var tools: Set<HandoffTool> = requestTools.union([.askHuman, .createPin])
        if isLead { tools.formUnion([.submitPlan, .submitVerdict]) }
        if agent.readOnly { tools.insert(.submitVerdict) }
        if !agent.readOnly { tools.insert(.submitResult) }
        return tools
    }

    public func receive(_ message: HandoffMessage, from agentID: Int64) async throws -> String {
        guard let agent = try runtime.database.agent(id: agentID) else {
            throw HandoffError.notAllowed("This agent no longer exists.")
        }
        switch message {
        case .plan(let plan):
            let config = try projectConfig(for: agent)
            let unknown = plan.tasks.map(\.role).filter { config.role($0) == nil }
            guard unknown.isEmpty else {
                let roles = config.roles.filter(\.editsCode).map(\.id).joined(separator: ", ")
                throw HandoffError.notAllowed("Unknown role ids: \(unknown.joined(separator: ", ")). Use one of: \(roles).")
            }
            plans[agentID] = plan
            return "Plan received with \(plan.tasks.count) tasks. End your turn now; the user reviews it before anyone builds."
        case .verdict(let verdict):
            verdicts[agentID] = verdict
            return "Verdict “\(verdict.outcome)” recorded. End your turn now."
        case .result(let summary):
            results[agentID] = summary
            return "Result recorded. End your turn now."
        case .pin(let draft):
            guard let runId = agent.runId else { throw HandoffError.notAllowed("Pins belong to workflow runs.") }
            let file = relativePath(draft.file, agent: agent)
            let now = Date()
            try await runtime.database.writer.write { db in
                var pin = Pin(
                    runId: runId, agentId: agentID, file: file, startLine: draft.startLine, endLine: draft.endLine,
                    title: draft.title, tags: draft.tags, explanation: draft.explanation, createdAt: now, updatedAt: now
                )
                try pin.insert(db)
            }
            return "Pinned \(file):\(draft.startLine)-\(draft.endLine) for the user."
        case .question(let question, let questions):
            _ = try runtime.database.createInboxItem(InboxItem(
                projectId: agent.projectId, runId: agent.runId, agentId: agentID, kind: .question,
                title: "\(agent.name) asks", body: question, questions: questions.isEmpty ? nil : questions, createdAt: .now
            ))
            return "Your question was sent to the user. End your turn now; the answer arrives as your next message."
        case .proposal(let proposal):
            guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can propose runs.") }
            let config = try projectConfig(for: agent)
            guard config.workflow(proposal.workflow) != nil else {
                throw HandoffError.notAllowed("Unknown workflow “\(proposal.workflow)”. Use one of: \(config.workflows.map(\.id).joined(separator: ", ")).")
            }
            if try runtime.database.runs(taskId: taskId).contains(where: \.isActive) {
                throw HandoffError.notAllowed("A run for this request is still going. Use message_agent to change it, or wait until it ends.")
            }
            try runtime.database.insert(LeadMessage(
                projectId: agent.projectId, taskId: taskId, kind: .proposal, text: proposal.brief,
                workflow: proposal.workflow, title: proposal.title, status: .open, createdAt: .now
            ))
            return "The user sees your proposal with a Start button. End your turn now. If they start it, you’ll be asked to plan it."
        case .agentMessage(let name, let text) where (try? isLead(agent)) == true:
            let target = try otherAgent(named: name, from: agent)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(target.name) can’t receive messages.") }
            let sender = agent.taskId == nil ? "Message from \(agent.name):" : "Message from \(agent.name), passing on the user’s instruction:"
            session.send("\(sender)\n\n\(text)")
            return "Sent to \(target.name)."
        case .agentMessage(let name, let text):
            guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can message run agents.") }
            let activeRuns = Set(try runtime.database.runs(taskId: taskId).filter(\.isActive).compactMap(\.id))
            guard !activeRuns.isEmpty else { throw HandoffError.notAllowed("No run is going for this request, so there’s no one to message.") }
            let candidates = try runtime.database.agents(inProject: agent.projectId)
                .filter { $0.id != agentID && $0.archivedAt == nil && $0.runId.map(activeRuns.contains) == true }
            guard let target = candidates.first(where: { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }),
                  let session = runtime.session(for: target) else {
                throw HandoffError.notAllowed("No agent named “\(name)” in this request’s run. Agents: \(candidates.map(\.name).joined(separator: ", ")).")
            }
            session.send("Message from \(agent.name), passing on the user’s instruction:\n\n\(text)")
            return "Sent to \(target.name)."
        case .listAgents:
            try requireLead(agent)
            let agents = try runtime.database.agents(inProject: agent.projectId).filter { $0.archivedAt == nil }
            return agents.map { listing(of: $0, isCaller: $0.id == agentID) }.joined(separator: "\n")
        case .spawnAgent(let request):
            try requireLead(agent)
            let (project, config) = try projectAndConfig(for: agent)
            guard let role = config.role(request.role) else {
                throw HandoffError.notAllowed("Unknown role “\(request.role)”. Use one of: \(config.roles.map(\.id).joined(separator: ", ")).")
            }
            let spawned = try await runtime.spawn(
                in: project, role: role, count: request.count, config: config, git: try requireGit(),
                name: request.name, model: request.model, task: request.task
            )
            return "Started \(spawned.map(\.agent.name).joined(separator: ", ")). Check on them with list_agents."
        case .stopAgent(let name):
            try requireLead(agent)
            let target = try otherAgent(named: name, from: agent)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(target.name) can’t be stopped.") }
            session.stop()
            return "Stopping \(target.name)."
        case .deleteAgent(let name, let deleteBranch):
            try requireLead(agent)
            let target = try otherAgent(named: name, from: agent)
            if let runId = target.runId, try runtime.database.run(id: runId)?.isActive == true {
                throw HandoffError.notAllowed("\(target.name) is part of a running workflow. Stop it with stop_agent instead.")
            }
            let (project, _) = try projectAndConfig(for: agent)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(target.name) can’t be deleted.") }
            try await runtime.delete(session, in: project, git: try requireGit(), deleteBranch: deleteBranch)
            return "Deleted \(target.name)\(deleteBranch && target.branch != nil ? " and its branch" : "")."
        case .openWorktree:
            try requireLead(agent)
            guard agent.worktreePath == nil else { throw HandoffError.notAllowed("You already work in \(agent.worktreePath ?? "a worktree").") }
            let (project, _) = try projectAndConfig(for: agent)
            guard let session = runtime.session(for: agent) else { throw HandoffError.notAllowed("This agent no longer exists.") }
            try await runtime.openWorktree(for: session, in: project, git: try requireGit())
            let path = session.agent.worktreePath ?? ""
            let branch = session.agent.branch.map { " on branch \($0)" } ?? ""
            session.send("Your worktree at \(path)\(branch) is ready and you can now edit files there. Continue with the change you were about to make.")
            return "Worktree ready at \(path)\(branch). End your turn now; your next turn runs there with write access."
        }
    }

    private func isLead(_ agent: Agent) throws -> Bool {
        try projectConfig(for: agent).role(agent.role)?.canSpawn == true
    }

    private func requireLead(_ agent: Agent) throws {
        guard try isLead(agent) else { throw HandoffError.notAllowed("Only lead roles can manage agents.") }
    }

    private func otherAgent(named name: String, from agent: Agent) throws -> Agent {
        let candidates = try runtime.database.agents(inProject: agent.projectId).filter { $0.id != agent.id && $0.archivedAt == nil }
        guard let target = candidates.first(where: { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else {
            throw HandoffError.notAllowed("No other agent named “\(name)” in this project. Agents: \(candidates.map(\.name).joined(separator: ", ")).")
        }
        return target
    }

    private func listing(of agent: Agent, isCaller: Bool) -> String {
        var fields = ["role \(agent.role)", "status \(agent.status.rawValue)"]
        if let branch = agent.branch { fields.append("branch \(branch)") }
        fields.append(agent.worktreePath.map { "worktree \($0)" } ?? "read-only")
        if agent.runId != nil { fields.append("in a workflow run") }
        if !agent.task.isEmpty { fields.append("task: \(agent.task)") }
        return "- \(agent.name)\(isCaller ? " (you)" : ""): " + fields.joined(separator: "; ")
    }

    public func runAgentStep(_ context: StepContext) async throws -> StepResult {
        try await ensureServer()
        let git = try requireGit()
        guard let roleID = context.roleID else { throw WorkflowDriverError.missingRole("(none)") }
        let config = ProjectConfigLoader.load(repository: context.project.url)
        guard let role = config.role(roleID) else { throw WorkflowDriverError.missingRole(roleID) }
        let expected = expectedHandoff(for: context, role: role, workflow: workflowSnapshot(context.run))
        let runId = try requireRunID(context.run)

        var qaWorktree: (path: URL, branch: String?)?
        if !role.editsCode, expected == .verdict, isTestingStep(context.step) {
            switch try await prepareIntegrationWorktree(for: context.run, project: context.project, git: git, purpose: "qa") {
            case .ready(let path, let branch):
                qaWorktree = (path, branch)
            case .conflict(let branch, let files):
                let verdict = Verdict(
                    outcome: StepOutcome.failed,
                    summary: "The branches don’t merge cleanly, so nothing was tested.",
                    issues: [ReviewIssue(description: "Merging \(branch) conflicts in \(files.joined(separator: ", ")). Rebase onto the other branches and resolve.", agent: agentName(forBranch: branch, runId: runId, projectId: context.project.id))]
                )
                return .verdict(verdict)
            }
        }

        let session = try await stepAgent(for: role, context: context, runId: runId, git: git, worktree: qaWorktree, expected: expected)
        let startCost = session.agent.costUSD
        clearHandoffs(session.id)
        let resuming = context.isResuming && session.transcript.session != nil
        if expected == .verdict, !resuming {
            session.startNewSession()
        }
        let message = resuming
            ? resumeMessage(expected: expected)
            : stepMessage(context: context, role: role, expected: expected, config: config)

        let sessionID = session.id
        try await withTaskCancellationHandler {
            try await drive(session, message: message, expected: expected)
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopAgents([sessionID]) }
        }
        let cost = session.agent.costUSD - startCost

        switch expected {
        case .plan:
            guard let plan = plans[session.id] else { throw WorkflowDriverError.missingHandoff(agent: session.agent.name, tool: expected.tool.qualifiedName) }
            return .plan(plan, costUSD: cost)
        case .verdict:
            guard let verdict = verdicts[session.id] else { throw WorkflowDriverError.missingHandoff(agent: session.agent.name, tool: expected.tool.qualifiedName) }
            return .verdict(verdict, costUSD: cost)
        case .result:
            let heads = await branchHeads(of: [session], in: context.project, git: git)
            return .done(results[session.id] ?? lastAssistantText(session), branchHeads: heads, costUSD: cost)
        }
    }

    public func runSpawnStep(_ context: SpawnContext) async throws -> StepResult {
        try await ensureServer()
        let git = try requireGit()
        let runId = try requireRunID(context.step.run)
        let project = context.step.project
        let config = ProjectConfigLoader.load(repository: project.url)
        let fallbackRole = context.step.roleID.flatMap(config.role)

        var assignments: [(PlanTask, Int)] = []
        for task in context.plan.tasks {
            for copy in 0..<max(1, task.count) { assignments.append((task, copy)) }
        }
        if let cap = context.maxAgents, cap > 0, assignments.count > cap {
            assignments = Array(assignments.prefix(cap))
        }

        let existing = try runtime.runSessions(runId: runId, projectId: project.id ?? -1).filter { !$0.agent.readOnly && $0.agent.planTaskId != nil }
        var builders: [(session: AgentSession, task: PlanTask)] = []
        for (task, copy) in assignments {
            let key = copy == 0 ? task.id : "\(task.id)#\(copy + 1)"
            if let session = existing.first(where: { $0.agent.planTaskId == key }) {
                builders.append((session, task))
                continue
            }
            guard let role = config.role(task.role).flatMap({ $0.editsCode ? $0 : nil }) ?? fallbackRole else {
                throw WorkflowDriverError.missingRole(task.role)
            }
            let session = try await runtime.createRunAgent(
                in: project, role: role, runId: runId, runStepId: context.step.runStepID,
                planTaskId: key, task: task.title, git: git
            )
            builders.append((session, task))
        }

        let feedback = context.feedback
        var conflictMessages: [Int64: String] = [:]
        if context.step.isLoopBack, let conflict = try await firstConflict(for: context.step.run, project: project, git: git),
           let session = builders.first(where: { $0.session.agent.branch == conflict.branch })?.session,
           let worktree = session.agent.worktreeURL {
            conflictMessages[session.id] = try await stageConflict(conflict, in: worktree, git: git)
        }
        let startCosts = Dictionary(uniqueKeysWithValues: builders.map { ($0.session.id, $0.session.agent.costUSD) })
        var active: [(AgentSession, String)] = []
        for (session, task) in builders {
            if let conflictMessage = conflictMessages[session.id] {
                clearHandoffs(session.id)
                active.append((session, conflictMessage))
            } else if context.step.isLoopBack, let feedback {
                let issues = relevantIssues(feedback.issues, for: session, task: task)
                guard !issues.isEmpty || feedback.issues.allSatisfy({ $0.agent == nil && $0.file == nil }) else { continue }
                clearHandoffs(session.id)
                active.append((session, feedbackMessage(feedback, issues: issues, task: task)))
            } else if context.step.isResuming, results[session.id] != nil {
                continue
            } else {
                clearHandoffs(session.id)
                active.append((session, buildMessage(task: task, context: context)))
            }
        }

        let activeIDs = active.map(\.0.id)
        try await withTaskCancellationHandler {
            for (session, message) in active {
                session.send(message)
            }
            for (session, _) in active {
                try await follow(session, expected: .result)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopAgents(activeIDs) }
        }

        let taskResults = builders.map { session, task in
            TaskResult(planTaskId: session.agent.planTaskId ?? task.id, agentName: session.agent.name, summary: results[session.id] ?? lastAssistantText(session))
        }
        let cost = builders.reduce(0) { $0 + $1.session.agent.costUSD - (startCosts[$1.session.id] ?? 0) }
        let summary = taskResults.map { "\($0.agentName ?? "Agent"): \($0.summary)" }.joined(separator: "\n")
        let heads = await branchHeads(of: builders.map(\.session), in: project, git: git)
        return .done(summary, taskResults: taskResults, branchHeads: heads, costUSD: cost)
    }

    private func branchHeads(of sessions: [AgentSession], in project: Project, git: GitClient) async -> [String: String] {
        var heads: [String: String] = [:]
        for branch in sessions.compactMap(\.agent.branch) {
            guard let head = try? await git.run(["rev-parse", branch], in: project.url) else { continue }
            heads[branch] = head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return heads
    }

    public func diffInfo(_ run: Run) async -> DiffInfo {
        guard let git = gitProvider(), let runId = run.id,
              let builders = try? runtime.runSessions(runId: runId, projectId: run.projectId).filter({ !$0.agent.readOnly })
        else { return DiffInfo() }
        var paths: Set<String> = []
        var lines = 0
        for session in builders {
            guard let worktree = session.agent.worktreeURL, let base = session.agent.baseBranch else { continue }
            guard let output = try? await git.run(["diff", "--numstat", base], in: worktree) else { continue }
            for row in output.split(separator: "\n") {
                let columns = row.split(separator: "\t", maxSplits: 2).map(String.init)
                guard columns.count == 3 else { continue }
                lines += (Int(columns[0]) ?? 0) + (Int(columns[1]) ?? 0)
                paths.insert(columns[2])
            }
        }
        return DiffInfo(paths: paths.sorted(), lines: lines)
    }

    public func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult {
        let git = try requireGit()
        let runId = try requireRunID(run)
        guard let project = try runtime.database.project(id: run.projectId) else { throw WorkflowDriverError.notReady("The project is gone.") }
        let branches = try builderBranches(runId: runId, projectId: run.projectId)
        let base = try await baseBranch(runId: runId, project: project, git: git)
        var result = FinishResult(summary: "No branches to deliver.")

        if !branches.isEmpty {
            let integration: (path: URL, branch: String?)
            switch try await prepareIntegrationWorktree(for: run, project: project, git: git, purpose: "delivery") {
            case .ready(let path, let branch): integration = (path, branch)
            case .conflict(let branch, let files): throw WorkflowDriverError.mergeConflict(branch: branch, files: files)
            }
            guard let deliveryBranch = integration.branch else { throw WorkflowDriverError.notReady("The integration worktree has no branch.") }

            switch end.action {
            case .leave:
                result = FinishResult(summary: "Branches left in place; combined work is on \(deliveryBranch).")
            case .merge:
                try await mergeIntoBase(deliveryBranch, base: base, project: project, git: git)
                result = FinishResult(summary: "Merged \(deliveryBranch) into \(base).")
            case .push:
                try await git.run(["push", "-u", "origin", deliveryBranch], in: project.url)
                result = FinishResult(summary: "Pushed \(deliveryBranch) to origin.")
            case .pullRequest:
                try await git.run(["push", "-u", "origin", deliveryBranch], in: project.url)
                let url = try await openPullRequest(run: run, project: project, branch: deliveryBranch, base: base, git: git)
                result = FinishResult(pullRequestURL: url, summary: "Opened \(url).")
            }
        }

        await memoryUpdater?.updateMemories(after: run)
        if end.cleanUpWorktrees {
            await cleanUp(runId: runId, project: project, git: git)
        }
        return result
    }

    public func cancel(_ run: Run) async {
        guard let runId = run.id, let sessions = try? runtime.runSessions(runId: runId, projectId: run.projectId) else { return }
        for session in sessions where session.isRunning || session.isQueued {
            session.stop()
        }
    }

    func drive(_ session: AgentSession, message: String, expected: ExpectedHandoff) async throws {
        session.send(message)
        try await follow(session, expected: expected)
    }

    private func stopAgents(_ ids: [Int64]) {
        for id in ids {
            guard let agent = try? runtime.database.agent(id: id), let session = runtime.session(for: agent) else { continue }
            session.stop()
        }
    }

    func follow(_ session: AgentSession, expected: ExpectedHandoff) async throws {
        var nudged = false
        while true {
            try await waitForTurnEnd(session)
            if session.agent.status == .failed {
                throw WorkflowDriverError.agentFailed(agent: session.agent.name, message: session.agent.lastError ?? "unknown error")
            }
            if hasHandoff(session.id, expected: expected) { return }
            if try hasOpenQuestion(session) {
                try await waitForAnswer(session)
                continue
            }
            if expected == .result, nudged || results[session.id] != nil { return }
            guard !nudged else {
                throw WorkflowDriverError.missingHandoff(agent: session.agent.name, tool: expected.tool.qualifiedName)
            }
            nudged = true
            session.send("You ended your turn without calling `\(expected.tool.qualifiedName)`. Call it now with your \(expected == .plan ? "plan" : expected == .verdict ? "verdict" : "summary"), then end your turn.")
        }
    }

    private func waitForTurnEnd(_ session: AgentSession) async throws {
        try await Task.sleep(for: pollInterval)
        while session.isRunning || session.isQueued || session.agent.status == .working || session.agent.status == .waiting {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
        }
    }

    private func waitForAnswer(_ session: AgentSession) async throws {
        while try hasOpenQuestion(session), !session.isRunning, !session.isQueued {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
        }
    }

    private func hasOpenQuestion(_ session: AgentSession) throws -> Bool {
        try runtime.database.openInboxItems(projectId: session.agent.projectId)
            .contains { $0.agentId == session.id && $0.kind == .question }
    }

    private func hasHandoff(_ agentID: Int64, expected: ExpectedHandoff) -> Bool {
        switch expected {
        case .plan: plans[agentID] != nil
        case .verdict: verdicts[agentID] != nil
        case .result: results[agentID] != nil
        }
    }

    private func clearHandoffs(_ agentID: Int64) {
        plans[agentID] = nil
        verdicts[agentID] = nil
        results[agentID] = nil
    }

    private func stepAgent(
        for role: RoleDefinition, context: StepContext, runId: Int64, git: GitClient, worktree: (path: URL, branch: String?)?, expected: ExpectedHandoff
    ) async throws -> AgentSession {
        let sessions = try runtime.runSessions(runId: runId, projectId: context.project.id ?? -1)
        if let worktree {
            if let qa = sessions.first(where: { $0.agent.role == role.id && $0.agent.planTaskId == nil && $0.agent.worktreeURL.map(realPath(of:)) == realPath(of: worktree.path) }) {
                return qa
            }
            return try await runtime.createRunAgent(in: context.project, role: role, runId: runId, runStepId: context.runStepID, task: context.step.displayTitle, readOnlyWorktree: worktree, git: git)
        }
        let reusable = sessions.first { session in
            let agent = session.agent
            guard agent.role == role.id, agent.planTaskId == nil, expected != .verdict || agent.taskId == nil else { return false }
            if role.canSpawn { return !agent.readOnly || agent.worktreePath == nil }
            return role.editsCode ? !agent.readOnly : agent.readOnly && agent.worktreePath == nil
        }
        if let reusable { return reusable }
        return try await runtime.createRunAgent(in: context.project, role: role, runId: runId, runStepId: context.runStepID, task: context.inputs.taskTitle, git: git)
    }

    func expectedHandoff(for context: StepContext, role: RoleDefinition, workflow: WorkflowDefinition?) -> ExpectedHandoff {
        let outcomes = Set(context.step.routes.keys)
        if !outcomes.isDisjoint(with: [StepOutcome.approved, StepOutcome.changesRequested, StepOutcome.passed, StepOutcome.failed]) {
            return .verdict
        }
        if role.canSpawn, let next = context.step.next, workflow?.step(next)?.type == .spawn {
            return .plan
        }
        if role.canSpawn, outcomes.isEmpty, let workflow, let index = workflow.steps.firstIndex(where: { $0.id == context.step.id }),
           workflow.steps.indices.contains(index + 1), workflow.steps[index + 1].type == .spawn {
            return .plan
        }
        return role.editsCode ? .result : .verdict
    }

    private func isTestingStep(_ step: WorkflowStep) -> Bool {
        !Set(step.routes.keys).isDisjoint(with: [StepOutcome.passed, StepOutcome.failed])
    }

    private func workflowSnapshot(_ run: Run) -> WorkflowDefinition? {
        try? YAMLWorkflow.decode(run.workflowSnapshot)
    }

    private func stepMessage(context: StepContext, role: RoleDefinition, expected: ExpectedHandoff, config: ProjectConfig) -> String {
        var parts = ["# \(context.step.displayTitle)"]
        if !context.step.instructions.isEmpty { parts.append(context.step.instructions) }
        parts.append("## Request\n\(context.inputs.taskTitle)" + (context.inputs.taskBody.isEmpty ? "" : "\n\n\(context.inputs.taskBody)"))
        if !context.inputs.labels.isEmpty { parts.append("Labels: \(context.inputs.labels.joined(separator: ", "))") }

        switch expected {
        case .plan:
            let builders = config.roles.filter(\.editsCode).map { "- `\($0.id)`: \($0.name)\($0.description.isEmpty ? "" : " — \($0.description)")" }
            parts.append("## Roles that can build\n" + builders.joined(separator: "\n"))
            if let feedback = context.inputs.feedback {
                parts.append("## The user asked for a new plan\n\(feedback.summary)")
            }
            parts.append("Read the codebase, then call `\(HandoffTool.submitPlan.qualifiedName)` with tasks that don’t touch the same files. Use only the role ids above. Then end your turn.")
        case .verdict:
            if let plan = context.inputs.plan {
                parts.append("## Plan\n\(plan.summary)\n" + plan.tasks.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.role))" }.joined(separator: "\n"))
            }
            let builds = context.inputs.previousOutputs.last { !$0.output.taskResults.isEmpty }
            if let builds {
                parts.append("## What the builders report\n" + builds.output.taskResults.map { "- \($0.agentName ?? "Agent"): \($0.summary)" }.joined(separator: "\n"))
            }
            parts.append(branchGuide(for: context))
            if let lastCheck = previousCheck(in: context) {
                parts.append(lastCheck)
            }
            let outcomes = isTestingStep(context.step) ? "`passed` or `failed`" : "`approved` or `changes_requested`"
            parts.append("When you’re done, call `\(HandoffTool.submitVerdict.qualifiedName)` with outcome \(outcomes), a summary, and concrete issues naming the agent and file. Pin anything a human must read with `\(HandoffTool.createPin.qualifiedName)`. Then end your turn.")
        case .result:
            if let feedback = context.inputs.feedback {
                parts.append("## Feedback to address\n\(feedback.summary)\n" + feedback.issues.map { "- \($0.description)" }.joined(separator: "\n"))
            }
            parts.append("When you’re done and tests pass, commit, then call `\(HandoffTool.submitResult.qualifiedName)` with what you changed and how you verified it. Then end your turn.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func branchGuide(for context: StepContext) -> String {
        guard let runId = context.run.id,
              let sessions = try? runtime.runSessions(runId: runId, projectId: context.project.id ?? -1).filter({ !$0.agent.readOnly && $0.agent.branch != nil })
        else { return "" }
        let rows = sessions.map { "- \($0.agent.name): branch `\($0.agent.branch ?? "")`, worktree `\($0.agent.worktreePath ?? "")`" }
        guard !rows.isEmpty else { return "" }
        let base = sessions.first?.agent.baseBranch ?? "main"
        return "## Branches in this run\n" + rows.joined(separator: "\n") + "\n\nRead each with `git diff \(base)...<branch>` and `git log \(base)..<branch>` from the repository root, or open files in the worktrees."
    }

    func previousCheck(in context: StepContext) -> String? {
        let outputs = context.inputs.previousOutputs
        guard let index = outputs.lastIndex(where: { $0.stepId == context.step.id && $0.output.verdict != nil }),
              let verdict = outputs[index].output.verdict else { return nil }
        var parts = ["## Your last check (round \(outputs[index].iteration))", verdict.summary]
        if !verdict.issues.isEmpty {
            parts.append("Issues you raised:\n" + verdict.issues.map { issue in
                "- \(issue.description)" + ([issue.agent, issue.file].compactMap(\.self).isEmpty ? "" : " (\([issue.agent, issue.file].compactMap(\.self).joined(separator: ", ")))")
            }.joined(separator: "\n"))
        }
        let reviewedHeads = outputs[..<index].last { !$0.output.branchHeads.isEmpty }?.output.branchHeads ?? [:]
        if reviewedHeads.isEmpty {
            parts.append("This is a new session. Check whether those issues are fixed, and read only what changed since your last check.")
        } else {
            let rows = reviewedHeads.sorted { $0.key < $1.key }.map { "- `\($0.key)` was at `\($0.value)`" }
            parts.append("Last time you checked these commits:\n" + rows.joined(separator: "\n"))
            parts.append("This is a new session. See what changed with `git diff <commit>..<branch>` for each branch, check whether those issues are fixed, and don't re-read files that didn't change.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func resumeMessage(expected: ExpectedHandoff) -> String {
        "Ensemble restarted while you were working. Continue where you left off, then call `\(expected.tool.qualifiedName)` and end your turn."
    }

    private func buildMessage(task: PlanTask, context: SpawnContext) -> String {
        var parts = ["# Your task: \(task.title)"]
        if !task.details.isEmpty { parts.append(task.details) }
        if !task.files.isEmpty { parts.append("You own: \(task.files.joined(separator: ", ")). Don’t change files other tasks own.") }
        parts.append("## Overall request\n\(context.step.inputs.taskTitle)" + (context.step.inputs.taskBody.isEmpty ? "" : "\n\n\(context.step.inputs.taskBody)"))
        parts.append("## Plan\n\(context.plan.summary)\n" + context.plan.tasks.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.role))" }.joined(separator: "\n"))
        if !context.step.step.instructions.isEmpty { parts.append(context.step.step.instructions) }
        parts.append("Build it in your worktree, run the tests, commit, then call `\(HandoffTool.submitResult.qualifiedName)` with what you changed and how you verified it. Then end your turn.")
        return parts.joined(separator: "\n\n")
    }

    private func feedbackMessage(_ feedback: Feedback, issues: [ReviewIssue], task: PlanTask) -> String {
        var parts = ["# Changes requested (\(feedback.fromStep))", feedback.summary]
        let list = issues.isEmpty ? feedback.issues : issues
        if !list.isEmpty {
            parts.append(list.map { "- \($0.description)\($0.file.map { " (\($0))" } ?? "")" }.joined(separator: "\n"))
        }
        parts.append("Fix this in your worktree for “\(task.title)”, run the tests, commit, then call `\(HandoffTool.submitResult.qualifiedName)` and end your turn.")
        return parts.joined(separator: "\n\n")
    }

    private func relevantIssues(_ issues: [ReviewIssue], for session: AgentSession, task: PlanTask) -> [ReviewIssue] {
        issues.filter { issue in
            if let agent = issue.agent, agent.caseInsensitiveCompare(session.agent.name) == .orderedSame { return true }
            if let file = issue.file, task.files.contains(where: { file.hasPrefix($0) || $0.hasPrefix(file) }) { return true }
            return false
        }
    }

    private func lastAssistantText(_ session: AgentSession) -> String {
        for entry in session.transcript.entries.reversed() {
            if case .assistant(let text) = entry.content { return text }
        }
        return ""
    }

    private func relativePath(_ path: String, agent: Agent) -> String {
        let relative = rootRelativePath(path, agent: agent)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 2, parts[0] == Substring(WorktreeManager.directoryName) {
            return parts.dropFirst(2).joined(separator: "/")
        }
        return relative
    }

    private func rootRelativePath(_ path: String, agent: Agent) -> String {
        guard path.hasPrefix("/") else { return path }
        let roots = [agent.worktreePath, (try? runtime.database.project(id: agent.projectId))??.path].compactMap(\.self)
        for root in roots {
            let resolved = realPath(of: URL(fileURLWithPath: root))
            for prefix in [root + "/", resolved + "/"] where path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
            if path.hasPrefix("/private" + root + "/") { return String(path.dropFirst(("/private" + root + "/").count)) }
        }
        return path
    }

    private func projectConfig(for agent: Agent) throws -> ProjectConfig {
        try projectAndConfig(for: agent).1
    }

    private func projectAndConfig(for agent: Agent) throws -> (Project, ProjectConfig) {
        guard let project = try runtime.database.project(id: agent.projectId) else { throw HandoffError.notAllowed("The project is gone.") }
        return (project, ProjectConfigLoader.load(repository: project.url))
    }

    private func requireGit() throws -> GitClient {
        guard let git = gitProvider() else { throw WorkflowDriverError.notReady("git isn’t available.") }
        return git
    }

    private func requireRunID(_ run: Run) throws -> Int64 {
        guard let id = run.id else { throw WorkflowDriverError.notReady("The run hasn’t been saved.") }
        return id
    }

    private func builderBranches(runId: Int64, projectId: Int64) throws -> [String] {
        try runtime.runSessions(runId: runId, projectId: projectId)
            .filter { !$0.agent.readOnly && $0.agent.planTaskId != nil || (!$0.agent.readOnly && $0.agent.branch != nil) }
            .sorted { $0.id < $1.id }
            .compactMap(\.agent.branch)
            .filter { !$0.hasPrefix("ensemble/") }
    }

    private func agentName(forBranch branch: String, runId: Int64, projectId: Int64?) -> String? {
        (try? runtime.runSessions(runId: runId, projectId: projectId ?? -1))?.first { $0.agent.branch == branch }?.agent.name
    }

    private func baseBranch(runId: Int64, project: Project, git: GitClient) async throws -> String {
        if let base = try runtime.runSessions(runId: runId, projectId: project.id ?? -1).compactMap(\.agent.baseBranch).first {
            return base
        }
        return try await git.currentBranch(in: project.url) ?? "main"
    }

    enum IntegrationResult {
        case ready(URL, String?)
        case conflict(branch: String, files: [String])
    }

    struct BranchConflict: Equatable {
        let branch: String
        let base: String
        let mergedBefore: [String]
        let files: [String]
    }

    func firstConflict(for run: Run, project: Project, git: GitClient) async throws -> BranchConflict? {
        let runId = try requireRunID(run)
        let branches = try builderBranches(runId: runId, projectId: run.projectId)
        guard branches.count > 1 else { return nil }
        let base = try await baseBranch(runId: runId, project: project, git: git)
        var tree = try await git.run(["rev-parse", "\(base)^{tree}"], in: project.url).trimmingCharacters(in: .whitespacesAndNewlines)
        var mergedBefore: [String] = []
        var head = base
        for branch in branches {
            let result = try await git.runner.run(git.executable, ["merge-tree", "--write-tree", "--name-only", "--no-messages", head, branch], in: project.url)
            let lines = result.standardOutput.split(separator: "\n").map(String.init)
            if result.exitCode == 1 {
                return BranchConflict(branch: branch, base: base, mergedBefore: mergedBefore, files: Array(lines.dropFirst()))
            }
            guard result.succeeded, let newTree = lines.first else { return nil }
            tree = newTree
            let identity = ["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost"]
            head = try await git.run(identity + ["commit-tree", tree, "-p", head, "-p", branch, "-m", "Ensemble trial merge"], in: project.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mergedBefore.append(branch)
        }
        return nil
    }

    func stageConflict(_ conflict: BranchConflict, in worktree: URL, git: GitClient) async throws -> String {
        let identity = ["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost"]
        let status = try await git.run(["status", "--porcelain", "--untracked-files=no"], in: worktree)
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await git.run(identity + ["commit", "-am", "Work in progress before merging the other branches"], in: worktree)
        }
        var conflicted: [String] = []
        let merged = [conflict.base] + conflict.mergedBefore
        for branch in merged {
            let result = try await git.runner.run(git.executable, identity + ["merge", "--no-ff", "--no-edit", branch], in: worktree)
            if !result.succeeded {
                conflicted = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree))?
                    .split(separator: "\n").map(String.init) ?? conflict.files
                break
            }
        }
        let files = conflicted.isEmpty ? conflict.files : conflicted
        return """
            # Resolve a merge conflict
            Your branch conflicts with `\(conflict.base)` or with work the other builders already finished. Ensemble merged \(merged.map { "`\($0)`" }.joined(separator: ", ")) into your worktree\(conflicted.isEmpty ? "" : ", and git stopped with conflicts in \(files.joined(separator: ", "))").

            \(conflicted.isEmpty ? "The merge went through, but check that both changes still work together." : "Open each file, keep both sides' changes so all functions and tests remain, and remove every conflict marker (<<<<<<<, =======, >>>>>>>) with the Edit tool.") Run the tests, then `git add` the files and `git commit --no-edit`. Finally call `\(HandoffTool.submitResult.qualifiedName)` describing the resolution, and end your turn.
            """
    }

    func prepareIntegrationWorktree(for run: Run, project: Project, git: GitClient, purpose: String) async throws -> IntegrationResult {
        let runId = try requireRunID(run)
        let manager = WorktreeManager(repository: project.url, git: git)
        let agent = "\(purpose)-run-\(runId)"
        if let stale = try await manager.list().first(where: { $0.agent == Slug.make(agent) }) {
            try await manager.remove(stale, force: true, deleteBranch: true)
        }
        let branches = try builderBranches(runId: runId, projectId: run.projectId)
        let base = try await baseBranch(runId: runId, project: project, git: git)
        let titleSlug = Slug.make(run.title.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " "))
        let worktree = try await manager.create(agent: agent, slug: titleSlug.isEmpty ? "combined" : titleSlug, from: base)
        let identity = ["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost"]
        for branch in branches {
            do {
                try await git.run(identity + ["merge", "--no-ff", "--no-edit", "-m", "Merge \(branch)", branch], in: worktree.path)
            } catch {
                let conflicted = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree.path))?
                    .split(separator: "\n").map(String.init) ?? []
                _ = try? await git.run(["merge", "--abort"], in: worktree.path)
                return .conflict(branch: branch, files: conflicted)
            }
        }
        if purpose == "qa" {
            try await runtime.prepareIntegrationWorktree(at: worktree.path, name: agent, projectId: run.projectId)
        }
        return .ready(worktree.path, worktree.branch)
    }

    private func mergeIntoBase(_ branch: String, base: String, project: Project, git: GitClient) async throws {
        let current = try await git.currentBranch(in: project.url)
        guard current == base else {
            throw WorkflowDriverError.unsafeMerge("\(project.name) has \(current ?? "a detached HEAD") checked out, not \(base). Check out \(base) and retry.")
        }
        let status = try await git.run(["status", "--porcelain", "--untracked-files=no"], in: project.url)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowDriverError.unsafeMerge("\(project.name) has uncommitted changes on \(base). Commit or stash them and retry.")
        }
        try await git.run(["merge", "--no-ff", "--no-edit", branch], in: project.url)
    }

    private func openPullRequest(run: Run, project: Project, branch: String, base: String, git: GitClient) async throws -> String {
        guard let client = gitHubProvider() else { throw WorkflowDriverError.gitHub("Sign in to GitHub in Settings to open pull requests.") }
        let repository: String
        if let configured = project.settings.githubRepository {
            repository = configured
        } else if let origin = try await GitHubRemote.originRepository(in: project.url, git: git) {
            repository = origin
        } else {
            throw WorkflowDriverError.gitHub("\(project.name) has no GitHub origin remote.")
        }
        if let existing = try await client.pullRequest(forHead: branch, in: repository) {
            return existing.htmlURL.absoluteString
        }
        let body = try pullRequestBody(run: run)
        let pull = try await client.createPullRequest(NewPullRequest(title: run.title, head: branch, base: base, body: body, draft: false), in: repository)
        return pull.htmlURL.absoluteString
    }

    private func pullRequestBody(run: Run) throws -> String {
        guard let runId = run.id else { return "" }
        let steps = try runtime.database.runSteps(runId: runId)
        let decoder = JSONDecoder()
        let outputs = steps.compactMap { step in step.output.flatMap { try? decoder.decode(StepOutput.self, from: Data($0.utf8)) } }
        var parts = ["Delivered by Ensemble (\(run.workflow)\(run.workflowVersion.map { " v\($0)" } ?? ""))."]
        if let plan = outputs.compactMap(\.plan).last {
            parts.append("## Plan\n\(plan.summary)\n" + plan.tasks.map { "- \($0.title)" }.joined(separator: "\n"))
        }
        if let results = outputs.last(where: { !$0.taskResults.isEmpty })?.taskResults {
            parts.append("## What was built\n" + results.map { "- **\($0.agentName ?? "Agent")**: \($0.summary)" }.joined(separator: "\n"))
        }
        let pins = try runtime.database.writer.read { db in try Pin.filter(Pin.Columns.runId == runId).fetchAll(db) }
        if !pins.isEmpty {
            parts.append("## Pins\n" + pins.map { "- `\($0.file):\($0.startLine)` \($0.title) (\($0.status.rawValue))" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func cleanUp(runId: Int64, project: Project, git: GitClient) async {
        guard let sessions = try? runtime.runSessions(runId: runId, projectId: project.id ?? -1) else { return }
        let manager = WorktreeManager(repository: project.url, git: git)
        let worktrees = (try? await manager.list()) ?? []
        for session in sessions {
            session.stop()
            if let path = session.agent.worktreeURL, let worktree = worktrees.first(where: { realPath(of: $0.path) == realPath(of: path) }) {
                try? await manager.remove(worktree, force: true, deleteBranch: session.agent.readOnly)
            }
        }
        for worktree in worktrees where worktree.agent.hasSuffix("-run-\(runId)") {
            try? await manager.remove(worktree, force: true, deleteBranch: worktree.agent.hasPrefix("qa-"))
        }
    }
}

enum YAMLWorkflow {
    static func decode(_ text: String) throws -> WorkflowDefinition {
        try YAMLDecoder().decode(WorkflowDefinition.self, from: text)
    }
}
