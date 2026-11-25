import Foundation
import GRDB
import Yams

public enum WorkflowDriverError: Error, LocalizedError, Equatable {
    case notReady(String)
    case missingAgent(String)
    case agentFailed(agent: String, message: String)
    case setupFailed(agent: String, message: String)
    case checksFailed(rounds: Int, details: String)
    case missingHandoff(agent: String, tool: String)
    case mergeConflict(branch: String, files: [String])
    case unsafeMerge(String)
    case noRemote(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let reason):
            reason
        case .missingAgent(let step):
            "The step “\(step)” doesn’t say which agent runs it: lead, builder or checker."
        case .agentFailed(let agent, let message):
            "\(agent) failed: \(message)"
        case .checksFailed(let rounds, let details):
            "Checks still fail after \(rounds) round\(rounds == 1 ? "" : "s").\n\n\(details)"
        case .setupFailed(let agent, let message):
            "The setup script failed in \(agent)’s worktree. \(message)\nFix the script in Settings › Workspaces before retrying."
        case .missingHandoff(let agent, let tool):
            "\(agent) ended its turn twice without calling \(tool)."
        case .mergeConflict(let branch, let files):
            "Merging \(branch) conflicts in \(files.joined(separator: ", "))."
        case .unsafeMerge(let reason):
            reason
        case .noRemote(let reason):
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
    public var willRemoveWorktree: @MainActor (URL) async -> Void = { _ in }
    public var pollInterval: Duration = .milliseconds(250)
    public var memoryUpdater: PinnedMemoryUpdater?
    public var autoStartProposal: (@MainActor (LeadMessage, Project) async throws -> Void)?

    private var plans: [Int64: Plan] = [:]
    private var verdicts: [Int64: Verdict] = [:]
    var results: [Int64: String] = [:]
    private var awaitingLead: Set<Int64> = []
    var failedCorrections: [Int64: Int] = [:]
    public var packageRegistry: any PackageRegistry = PublicPackageRegistry()
    private var serverStart: Task<SaturnMCPServer, Error>?
    var specCommits: [Int64: Task<Void, Error>] = [:]
    var closingTasks: Set<Int64> = []
    public weak var specReviews: (any SpecReviewHost)?
    public weak var chatRouting: (any ChatRouting)?
    public var daemonID: DaemonID?
    private(set) lazy var questionRelay = QuestionRelay { [weak self] runId, batch in self?.deliverQuestions(batch, runId: runId) }

    private func autoStarting(
        _ message: LeadMessage, in project: Project, with start: @MainActor (LeadMessage, Project) async throws -> Void
    ) async throws -> String {
        let previous = try runtime.database.previousRunAgents(taskId: message.taskId)
        do {
            try await start(message, project)
        } catch {
            if var current = try runtime.database.leadMessage(id: message.id ?? -1), current.status == .starting {
                current.status = .open
                try runtime.database.save(current)
            }
            throw HandoffError.notAllowed("Saturn couldn’t start the run: \(error.localizedDescription) The user now sees your proposal with a Start button. Tell them what went wrong, then end your turn.")
        }
        let cleared = previous.isEmpty ? "" : " It cleared \(runtime.database.previousRunSummary(of: previous)) (\(previous.map { displayName(of: $0) }.joined(separator: ", "))). Tell the user in your reply."
        return "The run started automatically because “\(message.workflow ?? "")” has no planning step.\(cleared) End your turn now."
    }

    public var questionWindow: Duration {
        get { questionRelay.window }
        set { questionRelay.window = newValue }
    }

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
        runtime.handoffTools = { [weak self] agent in self?.tools(for: agent) ?? [] }
        runtime.observeTurnEnds { [weak self] session in self?.reportToSpawner(session) }
    }

    public func ensureServer() async throws {
        if runtime.mcpServer != nil { return }
        let start = serverStart ?? Task { try await SaturnMCPServer.start(sink: self, hooks: self) }
        serverStart = start
        runtime.mcpServer = try await start.value
    }

    func tools(for agent: Agent) -> Set<HandoffTool> {
        let isLead = agent.kind == .lead
        var leadTools: Set<HandoffTool> = isLead ? HandoffTool.leadTools : []
        if isLead, agent.readOnly, agent.worktreePath == nil { leadTools.insert(.openWorktree) }
        var chatTools: Set<HandoffTool> = agent.taskId == nil ? [] : [.proposeRun, .draftSpec, .messageAgent, .askHuman]
        if isLead, agent.taskId != nil { chatTools.formUnion([.setChatStatus, .replySpec]) }
        let spawnedTools: Set<HandoffTool> = agent.spawnedById == nil ? [] : [.messageAgent, .askHuman, .submitResult]
        let requestTools = chatTools.union(leadTools).union(spawnedTools).union([.readChat])
        guard agent.runId != nil else { return requestTools }
        var tools: Set<HandoffTool> = requestTools.union([.askHuman, .createPin, .attachEvidence])
        if isLead { tools.formUnion([.submitPlan, .submitVerdict]) }
        if agent.readOnly { tools.insert(.submitVerdict) }
        if !agent.readOnly { tools.insert(.submitResult) }
        return tools
    }

    public func receive(_ message: HandoffMessage, from agentID: Int64) async throws -> String {
        guard let agent = try runtime.database.agent(id: agentID) else {
            throw HandoffError.notAllowed("This agent no longer exists.")
        }
        #if DEBUG
        runtime.debugTrace?.handoff(message, from: agent)
        #endif
        switch message {
        case .plan(let plan):
            let others = plan.tasks.filter { $0.agent != .builder }
            guard others.isEmpty else {
                throw HandoffError.notAllowed("Every plan task is built by a builder, and plan tasks run at the same time, so a checker couldn’t check them. Set agent to builder for: \(others.map(\.title).joined(separator: ", ")). The workflow’s checker steps review and test the work after the build.")
            }
            let (project, _) = try projectAndConfig(for: agent)
            try runtime.checkSkills(plan.tasks.flatMap(\.skills), in: project)
            plans[agentID] = mergedPlan(plan, runId: agent.runId)
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
                    title: draft.title, tags: draft.tags, explanation: draft.explanation, confidence: draft.confidence, category: draft.category,
                    createdAt: now, updatedAt: now
                )
                try pin.insert(db)
            }
            return "Pinned \(file):\(draft.startLine)-\(draft.endLine) for the user."
        case .evidence(let draft):
            guard let runId = agent.runId else { throw HandoffError.notAllowed("Evidence belongs to workflow runs.") }
            return try await attachEvidence(draft, runId: runId, agent: agent)
        case .question(let question, let questions):
            if let runId = agent.runId, try relayLead(for: agent, runId: runId) != nil {
                awaitingLead.insert(agentID)
                #if DEBUG
                runtime.debugTrace?.questionAsked(by: agent, routedTo: "lead", body: question, questions: questions)
                #endif
                questionRelay.enqueue(RelayedQuestion(
                    projectId: agent.projectId, runId: runId, agentId: agentID, agentName: displayName(of: agent), body: question, questions: questions
                ))
                return "Your question was sent to your lead, who will answer it or ask the user. End your turn now; the answer arrives as your next message."
            }
            if agent.runId == nil, let spawner = try spawner(of: agent), let session = runtime.session(for: spawner) {
                awaitingLead.insert(agentID)
                #if DEBUG
                runtime.debugTrace?.questionAsked(by: agent, routedTo: "spawner", body: question, questions: questions)
                #endif
                session.send(QuestionRelay.spawnedAgentMessage(agentName: displayName(of: agent), body: question, questions: questions))
                return "Your question was sent to \(displayName(of: spawner)), who started you and will answer it or ask the user. End your turn now; the answer arrives as your next message."
            }
            _ = try runtime.database.createChatRequest(ChatRequest(
                projectId: agent.projectId, runId: agent.runId, agentId: agentID, kind: .question,
                title: "\(displayName(of: agent)) asks", body: question, questions: questions.isEmpty ? nil : questions, createdAt: .now
            ))
            #if DEBUG
            runtime.debugTrace?.questionAsked(by: agent, routedTo: "user", body: question, questions: questions)
            #endif
            return "Your question was sent to the user. End your turn now; the answer arrives as your next message."
        case .proposal(let proposal):
            guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can propose runs.") }
            let (project, config) = try projectAndConfig(for: agent)
            guard let workflow = config.workflow(proposal.workflow) else {
                throw HandoffError.notAllowed("Unknown workflow “\(proposal.workflow)”. Use one of: \(config.workflows.map(\.id).joined(separator: ", ")).")
            }
            if try runtime.database.runs(taskId: taskId).contains(where: \.isActive) {
                throw HandoffError.notAllowed("A run for this request is still going. Use message_agent to change it, or wait until it ends.")
            }
            let autoStart = workflow.needsPlan ? nil : autoStartProposal
            let message = try runtime.database.insert(LeadMessage(
                projectId: agent.projectId, taskId: taskId, kind: .proposal, text: proposal.brief,
                workflow: proposal.workflow, title: proposal.title, status: autoStart == nil ? .open : .starting, createdAt: .now
            ))
            if let autoStart {
                return try await autoStarting(message, in: project, with: autoStart)
            }
            let attached = (try? specStore.draft(projectId: agent.projectId, taskId: taskId)).flatMap { $0 }.flatMap { $0.status == .done ? nil : $0 }
            let note = attached.map { " The spec draft “\($0.title)” is attached; starting the run commits it and makes its acceptance criteria the run’s." } ?? ""
            let previous = try runtime.database.previousRunAgents(taskId: taskId)
            let clearing = previous.isEmpty ? "" : " Starting it clears \(runtime.database.previousRunSummary(of: previous)) (\(previous.map { displayName(of: $0) }.joined(separator: ", "))). Tell the user in your reply."
            return "The user sees your proposal with a Start button.\(note)\(clearing) End your turn now. If they start it, you’ll be asked to plan it."
        case .agentMessage(let name, let text) where (try? isLead(agent)) == true:
            let target = try otherAgent(named: name, from: agent)
            let targetName = displayName(of: target)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(targetName) can’t receive messages.") }
            let sender = agent.taskId == nil || target.spawnedById == agent.id
                ? "Message from \(displayName(of: agent)):"
                : "Message from \(displayName(of: agent)), passing on the user’s instruction:"
            #if DEBUG
            if awaitingLead.contains(session.id) { runtime.debugTrace?.questionAnswered(for: target, answer: text, via: "lead") }
            #endif
            awaitingLead.remove(session.id)
            session.send("\(sender)\n\n\(text)")
            return "Sent to \(targetName)."
        case .agentMessage(let name, let text) where agent.taskId == nil && agent.spawnedById != nil:
            guard let spawner = try spawner(of: agent), let session = runtime.session(for: spawner) else {
                throw HandoffError.notAllowed("The agent that started you no longer exists, so there’s no one to message.")
            }
            let spawnerName = displayName(of: spawner)
            let requested = name.trimmingCharacters(in: .whitespaces)
            guard [spawner.name, spawnerName].contains(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) else {
                throw HandoffError.notAllowed("You can only message \(spawnerName), the agent that started you.")
            }
            session.send("Message from \(displayName(of: agent)), an agent you started:\n\n\(text)")
            return "Sent to \(spawnerName)."
        case .agentMessage(let name, let text):
            guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can message run agents.") }
            let activeRuns = Set(try runtime.database.runs(taskId: taskId).filter(\.isActive).compactMap(\.id))
            guard !activeRuns.isEmpty else { throw HandoffError.notAllowed("No run is going for this request, so there’s no one to message.") }
            let candidates = try runtime.database.agents(inProject: agent.projectId)
                .filter { $0.id != agentID && $0.archivedAt == nil && $0.runId.map(activeRuns.contains) == true }
            let target = try resolveAgent(named: name, among: candidates, config: try projectConfig(for: agent), missing: "No agent named “\(name)” in this request’s run.")
            guard let session = runtime.session(for: target) else {
                throw HandoffError.notAllowed("\(displayName(of: target)) can’t receive messages.")
            }
            #if DEBUG
            if awaitingLead.contains(session.id) { runtime.debugTrace?.questionAnswered(for: target, answer: text, via: "lead") }
            #endif
            awaitingLead.remove(session.id)
            session.send("Message from \(displayName(of: agent)), passing on the user’s instruction:\n\n\(text)")
            return "Sent to \(displayName(of: target))."
        case .listAgents:
            try requireLead(agent)
            let agents = try runtime.database.agents(inProject: agent.projectId).filter { $0.archivedAt == nil }
            let labels = distinctNames(of: agents, config: try projectConfig(for: agent))
            return zip(agents, labels).map { listing(of: $0, label: $1, isCaller: $0.id == agentID) }.joined(separator: "\n")
        case .spawnAgent(let request):
            try requireLead(agent)
            let (project, _) = try projectAndConfig(for: agent)
            let spawned = try await runtime.spawn(
                in: project, kind: request.agent, count: request.count, git: try requireGit(for: project),
                name: request.name, model: request.model, task: request.task, skills: request.skills, spawnedBy: agent
            )
            let skills = request.skills.isEmpty ? "" : " with \(request.skills.joined(separator: ", "))"
            return "Started \(spawned.map { AgentNaming.displayName(of: $0.agent) }.joined(separator: ", "))\(skills). Each agent’s report arrives as your next message when it finishes its turn. End your turn now."
        case .stopAgent(let name):
            try requireLead(agent)
            let target = try otherAgent(named: name, from: agent)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(displayName(of: target)) can’t be stopped.") }
            session.stop()
            return "Stopping \(displayName(of: target))."
        case .deleteAgent(let name, let deleteBranch):
            try requireLead(agent)
            let target = try otherAgent(named: name, from: agent)
            let targetName = displayName(of: target)
            if let runId = target.runId, try runtime.database.run(id: runId)?.isActive == true {
                throw HandoffError.notAllowed("\(targetName) is part of a running workflow. Stop it with stop_agent instead.")
            }
            let (project, _) = try projectAndConfig(for: agent)
            guard let session = runtime.session(for: target) else { throw HandoffError.notAllowed("\(targetName) can’t be deleted.") }
            try await runtime.delete(session, in: project, git: try requireGit(for: project), deleteBranch: deleteBranch)
            return "Deleted \(targetName)\(deleteBranch && target.branch != nil ? " and its branch" : "")."
        case .openWorktree:
            try requireLead(agent)
            guard agent.worktreePath == nil else { throw HandoffError.notAllowed("You already work in \(agent.worktreePath ?? "a worktree").") }
            let (project, _) = try projectAndConfig(for: agent)
            guard let session = runtime.session(for: agent) else { throw HandoffError.notAllowed("This agent no longer exists.") }
            try await runtime.openWorktree(for: session, in: project, git: try requireGit(for: project))
            let path = session.agent.worktreePath ?? ""
            let branch = session.agent.branch.map { " on branch \($0)" } ?? ""
            session.send("Your worktree at \(path)\(branch) is ready and you can now edit files there. Continue with the change you were about to make.")
            return "Worktree ready at \(path)\(branch). End your turn now; your next turn runs there with write access."
        case .readChat(let request):
            return try await readChat(request)
        case .draftSpec(let request):
            return try await postSpecDraft(try draftSpec(request, from: agent), from: agent)
        case .replySpec(let text):
            return try await replySpec(text, from: agent)
        case .setChatStatus(let status, let reason):
            let reply = try setChatStatus(status, reason: reason, from: agent)
            if status.closeReason != nil, let taskId = agent.taskId { await specReviews?.endSpecReview(taskId: taskId) }
            return reply
        }
    }

    private func relayLead(for agent: Agent, runId: Int64) throws -> Agent? {
        guard let run = try runtime.database.run(id: runId),
              let lead = try runtime.database.leadAgent(taskId: run.taskId), lead.id != agent.id, lead.taskId != nil,
              runtime.session(for: lead) != nil,
              let workflow = try? YAMLWorkflow.decode(run.workflowSnapshot) else { return nil }
        return workflow.steps.contains { $0.type == .agent && $0.agent == .lead } ? lead : nil
    }

    private func deliverQuestions(_ batch: [RelayedQuestion], runId: Int64) {
        if let run = try? runtime.database.run(id: runId),
           let lead = try? runtime.database.leadAgent(taskId: run.taskId),
           !batch.contains(where: { $0.agentId == lead.id }),
           let session = runtime.session(for: lead) {
            #if DEBUG
            traceDelivery(batch, runId: runId, to: "lead")
            #endif
            session.send(QuestionRelay.message(for: batch))
            return
        }
        #if DEBUG
        traceDelivery(batch, runId: runId, to: "user_chat")
        #endif
        for question in batch {
            _ = try? runtime.database.createChatRequest(ChatRequest(
                projectId: question.projectId, runId: question.runId, agentId: question.agentId, kind: .question,
                title: "\(question.agentName) asks", body: question.body, questions: question.questions.isEmpty ? nil : question.questions, createdAt: .now
            ))
        }
    }

    private func spawner(of agent: Agent) throws -> Agent? {
        guard let spawnerID = agent.spawnedById else { return nil }
        return try runtime.database.agent(id: spawnerID)
    }

    func reportToSpawner(_ session: AgentSession) {
        let agent = session.agent
        guard agent.spawnedById != nil, agent.runId == nil, let agentID = agent.id else { return }
        let failed = agent.status == .failed
        guard failed || (try? hasOpenQuestion(session)) == false else { return }
        let submitted = results.removeValue(forKey: agentID)
        let name = displayName(of: agent)
        let report = failed
            ? "\(name) failed: \(agent.lastError ?? "unknown error")"
            : submitted ?? currentTurnReply(session).nilIfEmpty ?? "\(name) ended its turn without a reply."
        if let spawner = try? spawner(of: agent), let spawnerSession = runtime.session(for: spawner) {
            spawnerSession.send("Report from \(name):\n\n\(report)")
            return
        }
        _ = try? runtime.database.createChatRequest(ChatRequest(
            projectId: agent.projectId, agentId: agentID, kind: .notice,
            title: "Report from \(name)", body: report, createdAt: .now
        ))
    }

    private func currentTurnReply(_ session: AgentSession) -> String {
        for entry in session.transcript.entries.reversed() {
            switch entry.content {
            case .assistant(let text): return text
            case .user: return ""
            default: continue
            }
        }
        return ""
    }

    private func endRelay(for run: Run) {
        guard let runId = run.id else { return }
        questionRelay.flush(runId: runId)
        let agents = (try? runtime.database.agents(inProject: run.projectId).filter { $0.runId == runId }.compactMap(\.id)) ?? []
        awaitingLead.subtract(agents)
    }

    private func isLead(_ agent: Agent) throws -> Bool {
        agent.kind == .lead
    }

    private func requireLead(_ agent: Agent) throws {
        guard try isLead(agent) else { throw HandoffError.notAllowed("Only the Lead can manage agents.") }
    }

    func displayName(of agent: Agent) -> String {
        runtime.database.displayName(of: agent)
    }

    private func otherAgent(named name: String, from agent: Agent) throws -> Agent {
        let candidates = try runtime.database.agents(inProject: agent.projectId).filter { $0.id != agent.id && $0.archivedAt == nil }
        return try resolveAgent(named: name, among: candidates, config: try projectConfig(for: agent), missing: "No other agent named “\(name)” in this project.")
    }

    private func resolveAgent(named name: String, among candidates: [Agent], config: ProjectConfig, missing: String) throws -> Agent {
        let requested = name.trimmingCharacters(in: .whitespaces)
        if let exact = candidates.first(where: { $0.name.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let matches = candidates.filter { AgentNaming.displayName(of: $0, config: config).caseInsensitiveCompare(requested) == .orderedSame }
        if matches.count == 1, let match = matches.first { return match }
        if let first = matches.first {
            throw HandoffError.notAllowed("Several agents are called “\(AgentNaming.displayName(of: first, config: config))”: \(matches.map(\.name).joined(separator: ", ")). Use one of those exact names.")
        }
        throw HandoffError.notAllowed("\(missing) Agents: \(distinctNames(of: candidates, config: config).joined(separator: ", ")).")
    }

    private func distinctNames(of agents: [Agent], config: ProjectConfig) -> [String] {
        let names = agents.map { AgentNaming.displayName(of: $0, config: config) }
        let counts = Dictionary(names.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return zip(agents, names).map { agent, name in
            counts[name.lowercased(), default: 0] > 1 && name != agent.name ? "\(name) (\(agent.name))" : name
        }
    }

    private func listing(of agent: Agent, label: String, isCaller: Bool) -> String {
        var fields = ["\(agent.kind?.rawValue ?? agent.role)", "status \(agent.status.rawValue)"]
        if !agent.skills.isEmpty { fields.append("skills \(agent.skills.joined(separator: ", "))") }
        if let branch = agent.branch { fields.append("branch \(branch)") }
        fields.append(agent.worktreePath.map { "worktree \($0)" } ?? "read-only")
        if agent.runId != nil { fields.append("in a workflow run") }
        if !agent.task.isEmpty { fields.append("task: \(agent.task)") }
        return "- \(label)\(isCaller ? " (you)" : ""): " + fields.joined(separator: "; ")
    }

    public func runAgentStep(_ context: StepContext) async throws -> StepResult {
        try await ensureServer()
        let git = try requireGit(for: context.project)
        guard let kind = context.kind else { throw WorkflowDriverError.missingAgent(context.step.id) }
        let config = ProjectConfigLoader.load(repository: context.project.filesRoot)
        let expected = expectedHandoff(for: context, kind: kind, workflow: workflowSnapshot(context.run))
        let runId = try requireRunID(context.run)
        try await ensureSpecBranch(for: context.run, project: context.project, git: git)

        var qaWorktree: (path: URL, branch: String?)?
        if !kind.editsCode, expected == .verdict, isTestingStep(context.step) {
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

        let session = try await reportingSetupFailure(runId: runId, projectId: context.project.id) {
            try await stepAgent(for: kind, context: context, runId: runId, git: git, worktree: qaWorktree, expected: expected)
        }
        let startCost = session.agent.costUSD
        clearHandoffs(session.id)
        let resuming = context.isResuming && session.transcript.session != nil
        if expected == .verdict, !resuming {
            session.startNewSession()
        }
        let message = resuming
            ? resumeMessage(expected: expected)
            : stepMessage(context: context, expected: expected, config: config)
        #if DEBUG
        runtime.debugTrace?.assign(session.agent, toStep: context.step.id, runStepId: context.runStepID, runTitle: context.run.title, message: message)
        #endif

        let sessionID = session.id
        try await withTaskCancellationHandler {
            try await drive(session, message: message, expected: expected)
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopAgents([sessionID]) }
        }
        let cost = session.agent.costUSD - startCost

        switch expected {
        case .plan:
            guard let plan = plans[session.id] else { throw WorkflowDriverError.missingHandoff(agent: displayName(of: session.agent), tool: expected.tool.qualifiedName) }
            return .plan(plan, costUSD: cost)
        case .verdict:
            guard let verdict = verdicts[session.id] else { throw WorkflowDriverError.missingHandoff(agent: displayName(of: session.agent), tool: expected.tool.qualifiedName) }
            return .verdict(verdict, costUSD: cost)
        case .result:
            let heads = await branchHeads(of: [session], in: context.project, git: git)
            return .done(results[session.id] ?? lastAssistantText(session), branchHeads: heads, costUSD: cost)
        }
    }

    public func runSpawnStep(_ context: SpawnContext) async throws -> StepResult {
        try await ensureServer()
        let git = try requireGit(for: context.step.project)
        let runId = try requireRunID(context.step.run)
        let project = context.step.project
        try await ensureSpecBranch(for: context.step.run, project: project, git: git)

        var assignments = context.plan.tasks
        if let cap = context.maxAgents, cap > 0, assignments.count > cap {
            assignments = Array(assignments.prefix(cap))
        }

        let existing = try runtime.runSessions(runId: runId, projectId: project.id ?? -1).filter { !$0.agent.readOnly && $0.agent.planTaskId != nil }
        var builders: [(session: AgentSession, task: PlanTask)] = []
        for task in assignments {
            let key = task.id
            if let session = existing.first(where: { $0.agent.planTaskId == key }) {
                try await reportingSetupFailure(runId: runId, projectId: project.id) { try await runtime.repairSetup(of: session) }
                builders.append((session, task))
                continue
            }
            if context.step.step.reusePinned, let projectID = project.id,
               let pinned = try runtime.pinnedAgentToReuse(kind: .builder, inProject: projectID, excluding: Set(builders.map(\.session.id)), activeRunIDs: activeRunIDs(projectID: projectID, except: runId)) {
                try await reportingSetupFailure(runId: runId, projectId: project.id) {
                    try await runtime.reassign(pinned, toRun: runId, runStepId: context.step.runStepID, planTaskId: key, task: task.title, skills: task.skills, in: project, git: git)
                }
                builders.append((pinned, task))
                continue
            }
            let session = try await reportingSetupFailure(runId: runId, projectId: project.id) {
                try await runtime.createRunAgent(
                    in: project, kind: .builder, model: context.step.step.model, skills: task.skills, runId: runId, runStepId: context.step.runStepID,
                    planTaskId: key, task: task.title, git: git
                )
            }
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
                #if DEBUG
                runtime.debugTrace?.assign(session.agent, toStep: context.step.step.id, runStepId: context.step.runStepID, runTitle: context.step.run.title, message: message)
                #endif
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

    private func activeRunIDs(projectID: Int64, except runId: Int64) throws -> Set<Int64> {
        Set(try runtime.database.runs(status: [.pending, .running, .waitingOnYou, .paused, .interrupted]).filter { $0.projectId == projectID && $0.id != runId }.compactMap(\.id))
    }

    func branchHeads(of sessions: [AgentSession], in project: Project, git: GitClient) async -> [String: String] {
        var heads: [String: String] = [:]
        for branch in sessions.compactMap(\.agent.branch) {
            guard let head = try? await git.run(["rev-parse", branch], in: project.url) else { continue }
            heads[branch] = head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return heads
    }

    public func diffInfo(_ run: Run) async -> DiffInfo {
        guard let git = try? requireGit(forRun: run), let runId = run.id,
              let builders = try? runtime.runSessions(runId: runId, projectId: run.projectId).filter({ !$0.agent.readOnly })
        else { return DiffInfo() }
        var paths: Set<String> = []
        var added = 0
        var deleted = 0
        for session in builders {
            guard let worktree = session.agent.worktreeURL, let base = session.agent.baseBranch else { continue }
            guard let output = try? await git.run(["diff", "--numstat", base], in: worktree) else { continue }
            for row in output.split(separator: "\n") {
                let columns = row.split(separator: "\t", maxSplits: 2).map(String.init)
                guard columns.count == 3 else { continue }
                added += Int(columns[0]) ?? 0
                deleted += Int(columns[1]) ?? 0
                paths.insert(columns[2])
            }
        }
        return DiffInfo(paths: paths.sorted(), added: added, deleted: deleted)
    }

    public func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult {
        endRelay(for: run)
        let git = try requireGit(forRun: run)
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
            try await completeSpec(for: run, in: integration.path, git: git)

            switch end.action {
            case .leave:
                result = FinishResult(summary: "Branches left in place; combined work is on \(deliveryBranch).", deliveryBranch: deliveryBranch, baseBranch: base)
            case .merge:
                try await mergeIntoBase(deliveryBranch, base: base, project: project, git: git)
                result = FinishResult(summary: "Merged \(deliveryBranch) into \(base).", baseBranch: base, mergedIntoBase: true)
            case .push:
                try await git.run(["push", "-u", "origin", deliveryBranch], in: project.url)
                result = FinishResult(summary: "Pushed \(deliveryBranch) to origin.", deliveryBranch: deliveryBranch, baseBranch: base)
            }
        }

        await memoryUpdater?.updateMemories(after: run)
        if end.cleanUpWorktrees {
            await cleanUp(runId: runId, project: project, git: git)
        }
        return result
    }

    public func cancel(_ run: Run) async {
        endRelay(for: run)
        guard let runId = run.id, let sessions = try? runtime.runSessions(runId: runId, projectId: run.projectId) else { return }
        for session in sessions where session.isRunning || session.isQueued {
            session.stop()
        }
    }

    func drive(_ session: AgentSession, message: String, expected: ExpectedHandoff) async throws {
        session.send(message)
        try await follow(session, expected: expected)
    }

    func stopAgents(_ ids: [Int64]) {
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
                throw WorkflowDriverError.agentFailed(agent: displayName(of: session.agent), message: session.agent.lastError ?? "unknown error")
            }
            if hasHandoff(session.id, expected: expected) { return }
            if try hasOpenQuestion(session) {
                #if DEBUG
                let waitStart = Date()
                defer { traceRequestAnswer(for: session, since: waitStart) }
                #endif
                try await waitForAnswer(session)
                awaitingLead.remove(session.id)
                continue
            }
            if expected == .result, nudged || results[session.id] != nil { return }
            guard !nudged else {
                throw WorkflowDriverError.missingHandoff(agent: displayName(of: session.agent), tool: expected.tool.qualifiedName)
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
        if awaitingLead.contains(session.id) { return true }
        return try runtime.database.openChatRequests(projectId: session.agent.projectId)
            .contains { $0.agentId == session.id && $0.kind == .question }
    }

    private func hasHandoff(_ agentID: Int64, expected: ExpectedHandoff) -> Bool {
        switch expected {
        case .plan: plans[agentID] != nil
        case .verdict: verdicts[agentID] != nil
        case .result: results[agentID] != nil
        }
    }

    func clearHandoffs(_ agentID: Int64) {
        plans[agentID] = nil
        verdicts[agentID] = nil
        results[agentID] = nil
    }

    private func stepAgent(
        for kind: AgentKind, context: StepContext, runId: Int64, git: GitClient, worktree: (path: URL, branch: String?)?, expected: ExpectedHandoff
    ) async throws -> AgentSession {
        let sessions = try runtime.runSessions(runId: runId, projectId: context.project.id ?? -1)
        let model = context.step.model
        if let worktree {
            if let qa = sessions.first(where: { $0.agent.kind == kind && $0.agent.planTaskId == nil && $0.agent.worktreeURL.map(realPath(of:)) == realPath(of: worktree.path) }) {
                return qa
            }
            return try await runtime.createRunAgent(in: context.project, kind: kind, model: model, runId: runId, runStepId: context.runStepID, task: context.step.displayTitle, readOnlyWorktree: worktree, git: git)
        }
        let reusable = sessions.first { session in
            let agent = session.agent
            guard agent.kind == kind, agent.planTaskId == nil, expected != .verdict || agent.taskId == nil else { return false }
            switch kind {
            case .lead: return !agent.readOnly || agent.worktreePath == nil
            case .builder: return !agent.readOnly
            case .checker: return agent.readOnly && agent.worktreePath == nil
            }
        }
        if let reusable {
            try await runtime.repairSetup(of: reusable)
            return reusable
        }
        return try await runtime.createRunAgent(in: context.project, kind: kind, model: model, runId: runId, runStepId: context.runStepID, task: context.inputs.taskTitle, git: git)
    }

    private func reportingSetupFailure<Value>(runId: Int64, projectId: Int64?, _ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as SetupScriptError {
            let failed = (try? runtime.runSessions(runId: runId, projectId: projectId ?? -1))?.last { runtime.setupFailed($0) }
            throw WorkflowDriverError.setupFailed(agent: failed.map { displayName(of: $0.agent) } ?? "a new agent", message: error.localizedDescription)
        }
    }

    func expectedHandoff(for context: StepContext, kind: AgentKind, workflow: WorkflowDefinition?) -> ExpectedHandoff {
        let outcomes = Set(context.step.routes.keys)
        if !outcomes.isDisjoint(with: [StepOutcome.approved, StepOutcome.changesRequested, StepOutcome.passed, StepOutcome.failed]) {
            return .verdict
        }
        if kind == .lead, let next = context.step.next, workflow?.step(next)?.type == .spawn {
            return .plan
        }
        if kind == .lead, outcomes.isEmpty, let workflow, let index = workflow.steps.firstIndex(where: { $0.id == context.step.id }),
           workflow.steps.indices.contains(index + 1), workflow.steps[index + 1].type == .spawn {
            return .plan
        }
        return kind.editsCode ? .result : .verdict
    }

    private func isTestingStep(_ step: WorkflowStep) -> Bool {
        !Set(step.routes.keys).isDisjoint(with: [StepOutcome.passed, StepOutcome.failed])
    }

    func workflowSnapshot(_ run: Run) -> WorkflowDefinition? {
        try? YAMLWorkflow.decode(run.workflowSnapshot)
    }

    private func stepMessage(context: StepContext, expected: ExpectedHandoff, config: ProjectConfig) -> String {
        var parts = ["# \(context.step.displayTitle)"]
        if !context.step.instructions.isEmpty { parts.append(context.step.instructions) }
        parts.append("## Request\n\(context.inputs.taskTitle)" + (context.inputs.taskBody.isEmpty ? "" : "\n\n\(context.inputs.taskBody)"))
        if !context.inputs.labels.isEmpty { parts.append("Labels: \(context.inputs.labels.joined(separator: ", "))") }

        switch expected {
        case .plan:
            if let feedback = context.inputs.feedback {
                parts.append("## The user asked for a new plan\n\(feedback.summary)")
            }
            if let guide = specGuide(for: context.run) { parts.append(guide) }
            parts.append(Self.planGuide)
            parts.append("Read the codebase, then call `\(HandoffTool.submitPlan.qualifiedName)` with tasks that don’t touch the same files. Each task gets its own builder; give it the installed skills it should load, if any. Then end your turn.")
        case .verdict:
            if let plan = context.inputs.plan {
                parts.append("## Plan\n\(plan.summary)\n" + plan.tasks.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.label))" }.joined(separator: "\n"))
            }
            if let spec = effectiveSpec(context.inputs.plan, run: context.run) { parts.append("## Spec to check against\n" + spec.markdown) }
            if let guide = criteriaGuide(for: context.run) { parts.append(guide) }
            let builds = context.inputs.previousOutputs.last { !$0.output.taskResults.isEmpty }
            if let builds {
                parts.append("## What the builders report\n" + builds.output.taskResults.map { "- \($0.agentName ?? "Agent"): \($0.summary)" }.joined(separator: "\n"))
            }
            parts.append(branchGuide(for: context))
            if let lastCheck = previousCheck(in: context) {
                parts.append(lastCheck)
            }
            if isTestingStep(context.step) {
                parts.append("When you’re done, call `\(HandoffTool.submitVerdict.qualifiedName)` with outcome `passed` or `failed`, a summary, and concrete issues naming the agent and file. Pin anything a human must read with `\(HandoffTool.createPin.qualifiedName)`. Then end your turn.")
            } else {
                parts.append(Self.reviewerGuide)
            }
        case .result:
            if let feedback = context.inputs.feedback {
                parts.append("## Feedback to address\n\(feedback.summary)\n" + feedback.issues.map { "- \($0.description)" }.joined(separator: "\n"))
            } else if let guide = testFirstGuide(for: context.run) {
                parts.append(guide)
            }
            parts.append("When you’re done and tests pass, commit, then call `\(HandoffTool.submitResult.qualifiedName)` with what you changed and how you verified it. Then end your turn. \(Self.stopBackgroundTasksGuide)")
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

    static let reviewerGuide = """
        ## How to review
        You comment; you don’t approve or block. The project’s checks and gates already ran, so don’t repeat them: look for real defects against the plan and its acceptance criteria, missing tests, security and data problems, and code that will be hard to change.
        Pin each finding worth a person’s time with `\(HandoffTool.createPin.qualifiedName)`, with your confidence that it’s a real problem (0 to 1) and a category. Skip style and nits; findings below the project’s confidence bar are hidden. No pins is a good result when the work is right.
        Then call `\(HandoffTool.submitVerdict.qualifiedName)`: `approved`, or `changes_requested` only for real defects, with concrete issues naming the agent and file. The authors get one round to fix them; after that the work goes to the user with your remaining comments. Then end your turn.
        """

    static let planGuide = """
        ## How to plan
        Keep each task one reviewable unit: small enough that a person can read its diff in one sitting. Name the files each task owns.
        Unless the request fits in one sentence, add a short spec: the interfaces it adds or changes, acceptance criteria someone can check, what is out of scope, and how to verify the whole change end to end. Keep it short; this is not a design document.
        """

    func testFirstGuide(for run: Run) -> String? {
        guard workflowSnapshot(run)?.steps.contains(where: { $0.type == .check && $0.testFirst }) == true else { return nil }
        return "## Test first\nBefore changing any code, add a test that reproduces the problem and fails, and commit it on its own with a message starting with “\(Self.reproductionPrefix)”. Then fix the code so the test passes. Saturn checks that the test fails without your fix."
    }

    private func resumeMessage(expected: ExpectedHandoff) -> String {
        "Saturn restarted while you were working. Continue where you left off, then call `\(expected.tool.qualifiedName)` and end your turn."
    }

    private func buildMessage(task: PlanTask, context: SpawnContext) -> String {
        var parts = ["# Your task: \(task.title)"]
        if !task.details.isEmpty { parts.append(task.details) }
        if !task.files.isEmpty { parts.append("You own: \(task.files.joined(separator: ", ")). Don’t change files other tasks own.") }
        parts.append("## Overall request\n\(context.step.inputs.taskTitle)" + (context.step.inputs.taskBody.isEmpty ? "" : "\n\n\(context.step.inputs.taskBody)"))
        parts.append("## Plan\n\(context.plan.summary)\n" + context.plan.tasks.enumerated().map { "\($0.offset + 1). \($0.element.title) (\($0.element.label))" }.joined(separator: "\n"))
        if let spec = effectiveSpec(context.plan, run: context.step.run) { parts.append("## Spec\n" + spec.markdown) }
        if !context.step.step.instructions.isEmpty { parts.append(context.step.step.instructions) }
        if let guide = testFirstGuide(for: context.step.run) { parts.append(guide) }
        parts.append("Build it in your worktree, run the tests, commit, then call `\(HandoffTool.submitResult.qualifiedName)` with what you changed and how you verified it. Then end your turn. \(Self.stopBackgroundTasksGuide)")
        return parts.joined(separator: "\n\n")
    }

    nonisolated static let stopBackgroundTasksGuide = "Before you call `\(HandoffTool.submitResult.qualifiedName)`, stop any servers or background commands you started."

    private func feedbackMessage(_ feedback: Feedback, issues: [ReviewIssue], task: PlanTask) -> String {
        var parts = ["# Changes requested (\(feedback.fromStep))", feedback.summary]
        let list = issues.isEmpty ? feedback.issues : issues
        if !list.isEmpty {
            parts.append(list.map { "- \($0.description)\($0.file.map { " (\($0))" } ?? "")" }.joined(separator: "\n"))
        }
        parts.append("Fix this in your worktree for “\(task.title)”, run the tests, commit, then call `\(HandoffTool.submitResult.qualifiedName)` and end your turn. \(Self.stopBackgroundTasksGuide)")
        return parts.joined(separator: "\n\n")
    }

    private func relevantIssues(_ issues: [ReviewIssue], for session: AgentSession, task: PlanTask) -> [ReviewIssue] {
        issues.filter { issue in
            if let agent = issue.agent, agent.caseInsensitiveCompare(session.agent.name) == .orderedSame { return true }
            if let file = issue.file, task.files.contains(where: { file.hasPrefix($0) || $0.hasPrefix(file) }) { return true }
            return false
        }
    }

    func lastAssistantText(_ session: AgentSession) -> String {
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
        return (project, ProjectConfigLoader.load(repository: project.filesRoot))
    }

    func requireGit(for project: Project) throws -> GitClient {
        guard !project.isRemote, let git = gitProvider() else { throw WorkflowDriverError.notReady("git isn’t available.") }
        return git
    }

    func requireGit(forRun run: Run) throws -> GitClient {
        guard let project = try runtime.database.project(id: run.projectId) else { throw WorkflowDriverError.notReady("The project is gone.") }
        return try requireGit(for: project)
    }

    func requireRunID(_ run: Run) throws -> Int64 {
        guard let id = run.id else { throw WorkflowDriverError.notReady("The run hasn’t been saved.") }
        return id
    }

    private func builderBranches(runId: Int64, projectId: Int64) throws -> [String] {
        try runtime.runSessions(runId: runId, projectId: projectId)
            .filter { !$0.agent.readOnly && $0.agent.planTaskId != nil || (!$0.agent.readOnly && $0.agent.branch != nil) }
            .sorted { $0.id < $1.id }
            .compactMap(\.agent.branch)
            .filter { !$0.hasPrefix("saturn/") }
    }

    private func agentName(forBranch branch: String, runId: Int64, projectId: Int64?) -> String? {
        (try? runtime.runSessions(runId: runId, projectId: projectId ?? -1))?.first { $0.agent.branch == branch }?.agent.name
    }

    private func baseBranch(runId: Int64, project: Project, git: GitClient) async throws -> String {
        if let base = try runtime.runSessions(runId: runId, projectId: project.id ?? -1).compactMap(\.agent.baseBranch).first {
            return base
        }
        return try await git.baseBranch(of: project.url) ?? "main"
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
            let result = try await git.execute(["merge-tree", "--write-tree", "--name-only", "--no-messages", head, branch], in: project.url)
            let lines = result.standardOutput.split(separator: "\n").map(String.init)
            if result.exitCode == 1 {
                return BranchConflict(branch: branch, base: base, mergedBefore: mergedBefore, files: Array(lines.dropFirst()))
            }
            guard result.succeeded, let newTree = lines.first else { return nil }
            tree = newTree
            let identity = ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]
            head = try await git.run(identity + ["commit-tree", tree, "-p", head, "-p", branch, "-m", "Saturn trial merge"], in: project.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mergedBefore.append(branch)
        }
        return nil
    }

    func stageConflict(_ conflict: BranchConflict, in worktree: URL, git: GitClient) async throws -> String {
        let identity = ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]
        let status = try await git.run(["status", "--porcelain", "--untracked-files=no"], in: worktree)
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await git.run(identity + ["commit", "-am", "Work in progress before merging the other branches"], in: worktree)
        }
        var conflicted: [String] = []
        let merged = [conflict.base] + conflict.mergedBefore
        for branch in merged {
            let result = try await git.execute(identity + ["merge", "--no-ff", "--no-edit", branch], in: worktree)
            if !result.succeeded {
                conflicted = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree))?
                    .split(separator: "\n").map(String.init) ?? conflict.files
                break
            }
        }
        let files = conflicted.isEmpty ? conflict.files : conflicted
        return """
            # Resolve a merge conflict
            Your branch conflicts with `\(conflict.base)` or with work the other builders already finished. Saturn merged \(merged.map { "`\($0)`" }.joined(separator: ", ")) into your worktree\(conflicted.isEmpty ? "" : ", and git stopped with conflicts in \(files.joined(separator: ", "))").

            \(conflicted.isEmpty ? "The merge went through, but check that both changes still work together." : "Open each file, keep both sides' changes so all functions and tests remain, and remove every conflict marker (<<<<<<<, =======, >>>>>>>) with the Edit tool.") Run the tests, then `git add` the files and `git commit --no-edit`. Finally call `\(HandoffTool.submitResult.qualifiedName)` describing the resolution, and end your turn. \(Self.stopBackgroundTasksGuide)
            """
    }

    func prepareIntegrationWorktree(for run: Run, project: Project, git: GitClient, purpose: String) async throws -> IntegrationResult {
        let runId = try requireRunID(run)
        let manager = WorktreeManager(project: project, git: git)
        let agent = "\(purpose)-run-\(runId)"
        if let stale = try await manager.list().first(where: { $0.agent == Slug.make(agent) }) {
            try await manager.remove(stale, force: true, deleteBranch: true)
        }
        let branches = try builderBranches(runId: runId, projectId: run.projectId)
        let base = try await baseBranch(runId: runId, project: project, git: git)
        let specBranch = try await ensureSpecBranch(for: run, project: project, git: git)
        let titleSlug = Slug.make(run.title.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " "))
        let worktree = try await manager.create(agent: agent, slug: titleSlug.isEmpty ? "combined" : titleSlug, from: specBranch ?? base)
        let identity = ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]
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
        try await requireSafeMerge(into: base, project: project, git: git)
        try await git.run(["merge", "--no-ff", "--no-edit", branch], in: project.url)
    }

    private func requireSafeMerge(into base: String, project: Project, git: GitClient) async throws {
        let current = try await git.currentBranch(in: project.url)
        guard current == base else {
            throw WorkflowDriverError.unsafeMerge("\(project.name) has \(current ?? "a detached HEAD") checked out, not \(base). Check out \(base) and retry.")
        }
        let status = try await git.run(["status", "--porcelain", "--untracked-files=no"], in: project.url)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowDriverError.unsafeMerge("\(project.name) has uncommitted changes on \(base). Commit or stash them and retry.")
        }
    }

    public func mergeDelivery(_ run: Run, method: MergeMethod) async throws -> String {
        let git = try requireGit(forRun: run)
        guard let project = try runtime.database.project(id: run.projectId) else { throw WorkflowDriverError.notReady("The project is gone.") }
        guard let branch = run.deliveryBranch, let base = run.baseBranch else {
            throw WorkflowDriverError.notReady("This run has no delivery branch to merge.")
        }
        try await requireSafeMerge(into: base, project: project, git: git)
        let repository = project.url
        let original = try await git.run(["rev-parse", "HEAD"], in: repository).trimmed
        try await git.run(["fetch", "origin"], in: repository)
        if try await git.hasCommit("refs/remotes/origin/\(base)", in: repository) {
            try await git.run(["merge", "--ff-only", "origin/\(base)"], in: repository)
        }
        let localBranch = try await git.hasCommit("refs/heads/\(branch)", in: repository)
        let ref = localBranch ? branch : "origin/\(branch)"
        let remoteBranch = try await git.hasCommit("refs/remotes/origin/\(branch)", in: repository)
        guard localBranch || remoteBranch else {
            try await restore(repository, to: original, git: git)
            throw WorkflowDriverError.notReady("\(branch) no longer exists locally or on origin.")
        }
        let identity = try await commitIdentity(in: repository, git: git)

        do {
            switch method {
            case .mergeCommit:
                try await mergeOrAbort(identity + ["merge", "--no-ff", "--no-edit", ref], branch: branch, in: repository, git: git)
            case .squash:
                try await mergeOrAbort(["merge", "--squash", ref], branch: branch, in: repository, git: git)
                try await git.run(identity + ["commit", "-m", run.title.isEmpty ? "Merge \(branch)" : run.title], in: repository)
            case .rebase:
                let rebased = try await rebase(ref, onto: base, branch: branch, run: run, repository: repository, identity: identity, git: git)
                try await git.run(["merge", "--ff-only", rebased], in: repository)
            }
        } catch {
            try? await restore(repository, to: original, git: git)
            throw error
        }

        try await deleteBranch(branch, local: localBranch, in: repository, git: git)
        return "Merged \(branch) into \(base)."
    }

    public func pushBase(_ run: Run) async throws -> String {
        let git = try requireGit(forRun: run)
        guard let project = try runtime.database.project(id: run.projectId) else { throw WorkflowDriverError.notReady("The project is gone.") }
        guard let base = run.baseBranch else { throw WorkflowDriverError.notReady("This run has no base branch to push.") }
        let remote = try await git.execute(["remote", "get-url", "origin"], in: project.url)
        guard remote.succeeded else { throw WorkflowDriverError.noRemote("\(project.name) has no origin remote to push \(base) to.") }
        try await git.run(["push", "origin", base], in: project.url)
        let commit = try await git.run(["rev-parse", "--short", base], in: project.url).trimmed
        return "Pushed \(base) to origin · \(commit)"
    }

    private func commitIdentity(in repository: URL, git: GitClient) async throws -> [String] {
        let name = try await git.execute(["config", "user.name"], in: repository)
        let email = try await git.execute(["config", "user.email"], in: repository)
        if name.succeeded, email.succeeded, !name.standardOutput.trimmed.isEmpty, !email.standardOutput.trimmed.isEmpty {
            return []
        }
        return ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]
    }

    private func mergeOrAbort(_ arguments: [String], branch: String, in repository: URL, git: GitClient) async throws {
        let result = try await git.execute(arguments, in: repository)
        guard !result.succeeded else { return }
        let conflicted = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: repository))?
            .split(separator: "\n").map(String.init) ?? []
        _ = try? await git.run(["merge", "--abort"], in: repository)
        if conflicted.isEmpty {
            throw WorkflowDriverError.unsafeMerge("Merging \(branch) failed: \(result.standardError.trimmed).")
        }
        throw WorkflowDriverError.mergeConflict(branch: branch, files: conflicted)
    }

    private func rebase(_ ref: String, onto base: String, branch: String, run: Run, repository: URL, identity: [String], git: GitClient) async throws -> String {
        let manager = WorktreeManager(repository: repository, git: git)
        let path = try manager.path(forAgent: "rebase-run-\(try requireRunID(run))")
        if (try? await git.fileSystem.fileExists(path)) == true {
            _ = try? await git.run(["worktree", "remove", "--force", path.path], in: repository)
        }
        try await manager.ensureExcluded()
        try await git.fileSystem.createDirectory(manager.crewDirectory)
        try await git.run(["worktree", "add", "--detach", path.path, ref], in: repository)
        let result = try? await git.execute(identity + ["rebase", base], in: path)
        var head: String?
        var conflicted: [String] = []
        if result?.succeeded == true {
            head = try? await git.run(["rev-parse", "HEAD"], in: path).trimmed
        } else {
            conflicted = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: path))?
                .split(separator: "\n").map(String.init) ?? []
            _ = try? await git.run(["rebase", "--abort"], in: path)
        }
        _ = try? await git.run(["worktree", "remove", "--force", path.path], in: repository)
        if let head { return head }
        if !conflicted.isEmpty { throw WorkflowDriverError.mergeConflict(branch: branch, files: conflicted) }
        throw WorkflowDriverError.unsafeMerge("Rebasing \(branch) onto \(base) failed: \(result?.standardError.trimmed ?? "git didn’t run").")
    }

    private func restore(_ repository: URL, to commit: String, git: GitClient) async throws {
        _ = try? await git.run(["merge", "--abort"], in: repository)
        try await git.run(["reset", "--merge", commit], in: repository)
    }

    private func deleteBranch(_ branch: String, local: Bool, in repository: URL, git: GitClient) async throws {
        if try await git.hasCommit("refs/remotes/origin/\(branch)", in: repository) {
            let result = try await git.execute(["push", "origin", "--delete", branch], in: repository)
            if !result.succeeded {
                _ = try? await git.run(["fetch", "--prune", "origin"], in: repository)
            }
        }
        guard local else { return }
        let manager = WorktreeManager(repository: repository, git: git)
        for worktree in (try? await manager.list()) ?? [] where worktree.branch == branch {
            await willRemoveWorktree(worktree.path)
            try? await manager.remove(worktree, force: true, deleteBranch: false)
        }
        _ = try? await git.run(["branch", "-D", branch], in: repository)
    }

    private func cleanUp(runId: Int64, project: Project, git: GitClient) async {
        guard let sessions = try? runtime.runSessions(runId: runId, projectId: project.id ?? -1) else { return }
        let manager = WorktreeManager(project: project, git: git)
        let worktrees = (try? await manager.list()) ?? []
        for session in sessions {
            session.stop()
            if let path = session.agent.worktreeURL, let worktree = worktrees.first(where: { realPath(of: $0.path) == realPath(of: path) }) {
                await willRemoveWorktree(worktree.path)
                try? await manager.remove(worktree, force: true, deleteBranch: session.agent.readOnly)
            }
        }
        for worktree in worktrees where worktree.agent.hasSuffix("-run-\(runId)") {
            await willRemoveWorktree(worktree.path)
            try? await manager.remove(worktree, force: true, deleteBranch: worktree.agent.hasPrefix("qa-"))
        }
        if let spec = specStore.link(runId: runId) {
            _ = try? await git.run(["branch", "-D", spec.branch], in: project.url)
        }
    }
}

enum YAMLWorkflow {
    static func decode(_ text: String) throws -> WorkflowDefinition {
        try YAMLDecoder().decode(WorkflowDefinition.self, from: text)
    }
}
