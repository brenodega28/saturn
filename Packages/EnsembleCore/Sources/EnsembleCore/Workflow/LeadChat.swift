import Foundation

public enum LeadChatError: Error, LocalizedError, Equatable {
    case noLeadRole
    case proposalClosed
    case runInProgress
    case unknownWorkflow(String)

    public var errorDescription: String? {
        switch self {
        case .noLeadRole: "This project has no lead role. Add a role with can_spawn: true in Crew › Roles."
        case .proposalClosed: "This proposal was already started or dismissed."
        case .runInProgress: "A run for this request is still going. Wait for it to end, or cancel it first."
        case .unknownWorkflow(let id): "The workflow “\(id)” no longer exists in .ensemble/workflows."
        }
    }
}

@MainActor
public final class LeadChat {
    public let runtime: AgentRuntime
    public let engine: RunEngine
    public let driver: AgentWorkflowDriver
    private var database: AppDatabase { runtime.database }

    public init(runtime: AgentRuntime, engine: RunEngine, driver: AgentWorkflowDriver) {
        self.runtime = runtime
        self.engine = engine
        self.driver = driver
        runtime.observeReplies { [weak self] agent, reply in self?.record(reply: reply, from: agent) }
    }

    @discardableResult
    public func createRequest(
        _ text: String, attachments: [ChatAttachment] = [], lead: RoleDefinition?, in project: Project, now: Date = .now
    ) async throws -> ProjectTask {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectId = project.id, !typed.isEmpty || !attachments.isEmpty else { throw AgentError.emptyTask }
        guard let lead else { throw LeadChatError.noLeadRole }
        let task = try database.insert(ProjectTask(
            projectId: projectId, title: Self.title(text: typed, attachments: attachments),
            body: ChatAttachment.prompt(text: typed, attachments: attachments), source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        try await send(typed, attachments: attachments, to: task, lead: lead, in: project, now: now)
        return task
    }

    public func send(
        _ text: String, attachments: [ChatAttachment] = [], to task: ProjectTask, lead: RoleDefinition?, in project: Project, now: Date = .now
    ) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let taskId = task.id, !body.isEmpty || !attachments.isEmpty else { return }
        try await driver.ensureServer()
        let session = try leadSession(for: task, lead: lead, in: project)
        if try database.task(id: taskId)?.isClosed == true {
            try database.setClosed(taskId: taskId, reason: nil, at: now)
        }
        try database.insert(LeadMessage(
            projectId: task.projectId, taskId: taskId, kind: .user, text: body, createdAt: now,
            attachments: try ChatAttachmentStore(paths: runtime.paths).store(attachments)
        ))
        let prompt = ChatAttachment.prompt(text: body, attachments: attachments)
        #if DEBUG
        runtime.debugTrace?.chatMessage(body, direction: "user_to_agent", chat: "lead", agent: session.agent, at: now)
        #endif
        let status = try statusNote(taskId: taskId).map { (prompt.isEmpty ? "" : "\n\n---\n") + $0 } ?? ""
        session.send(prompt + status, images: attachments.filter(\.isImage))
    }

    static func title(text: String, attachments: [ChatAttachment]) -> String {
        if !text.isEmpty { return LeadRequest.title(for: text) }
        if let pasted = attachments.lazy.compactMap(\.pastedText).first(where: { !LeadRequest.title(for: $0).isEmpty }) {
            return LeadRequest.title(for: pasted)
        }
        return "Image"
    }

    @discardableResult
    public func close(_ task: ProjectTask, as reason: RequestCloseReason, in project: Project, git: GitClient, now: Date = .now) async throws -> ProjectTask {
        guard let taskId = task.id, try database.task(id: taskId) != nil else { throw RunEngineError.invalidState("The request is gone.") }
        guard !(try hasActiveRun(taskId: taskId)) else { throw LeadChatError.runInProgress }
        for agent in try database.requestAgents(taskId: taskId) {
            guard let session = runtime.session(for: agent) else { continue }
            try await runtime.delete(session, in: project, git: git, deleteBranch: true)
        }
        guard !(try hasActiveRun(taskId: taskId)), let closed = try database.setClosed(taskId: taskId, reason: reason, at: now) else {
            throw LeadChatError.runInProgress
        }
        return closed
    }

    public func deleteAgentsOfClosedRequests(in project: Project, git: GitClient) async {
        guard let projectId = project.id, let tasks = try? database.closedTasks(projectId: projectId) else { return }
        for taskId in tasks.compactMap(\.id) where (try? hasActiveRun(taskId: taskId)) == false {
            for agent in (try? database.requestAgents(taskId: taskId)) ?? [] {
                guard let session = runtime.session(for: agent) else { continue }
                try? await runtime.delete(session, in: project, git: git, deleteBranch: true)
            }
        }
    }

    private func hasActiveRun(taskId: Int64) throws -> Bool {
        try database.runs(taskId: taskId).contains { (engine.runs[$0.id ?? -1] ?? $0).isActive }
    }

    public func leadSession(for task: ProjectTask) -> AgentSession? {
        guard let taskId = task.id, let agent = try? database.leadAgent(taskId: taskId) else { return nil }
        return runtime.session(for: agent)
    }

    @discardableResult
    public func start(_ proposal: LeadMessage, in project: Project) throws -> Run {
        let proposal = try openProposal(proposal)
        guard let workflowID = proposal.workflow else { throw LeadChatError.proposalClosed }
        guard let task = try database.task(id: proposal.taskId) else { throw RunEngineError.invalidState("The request is gone.") }
        guard try !database.runs(taskId: proposal.taskId).contains(where: \.isActive) else { throw LeadChatError.runInProgress }
        let config = ProjectConfigLoader.load(repository: project.url)
        guard let workflow = config.workflow(workflowID) else { throw LeadChatError.unknownWorkflow(workflowID) }
        let lead = try database.leadAgent(taskId: proposal.taskId)
        let leadRoleIDs = Set(config.roles.filter(\.canSpawn).map(\.id))
        let assigned = lead.map { workflow.assigningLead($0.role, replacing: leadRoleIDs) } ?? workflow
        if task.isClosed {
            try database.setClosed(taskId: proposal.taskId, reason: nil, at: .now)
        }
        let run = try engine.start(task: task, workflow: assigned, project: project, title: proposal.title, brief: proposal.text)
        if let lead, let runID = run.id {
            runtime.session(for: lead)?.attach(toRun: runID)
        }
        var started = proposal
        started.status = .started
        started.runId = run.id
        try database.save(started)
        return run
    }

    public func dismiss(_ proposal: LeadMessage) throws {
        var dismissed = try openProposal(proposal)
        dismissed.status = .dismissed
        try database.save(dismissed)
    }

    private func openProposal(_ proposal: LeadMessage) throws -> LeadMessage {
        guard let id = proposal.id, let current = try database.leadMessage(id: id),
              current.kind == .proposal, current.status == .open else { throw LeadChatError.proposalClosed }
        return current
    }

    func record(reply: String, from agent: Agent) {
        guard let taskId = agent.taskId else { return }
        _ = try? database.insert(LeadMessage(projectId: agent.projectId, taskId: taskId, kind: .lead, text: reply, createdAt: .now))
        #if DEBUG
        runtime.debugTrace?.chatMessage(reply, direction: "agent_to_user", chat: "lead", agent: agent)
        #endif
    }

    private func leadSession(for task: ProjectTask, lead: RoleDefinition?, in project: Project) throws -> AgentSession {
        if let session = leadSession(for: task) { return session }
        guard let lead, let taskId = task.id else { throw LeadChatError.noLeadRole }
        return try runtime.createLeadAgent(in: project, role: lead, taskId: taskId)
    }

    func statusNote(taskId: Int64) throws -> String? {
        let runs = try database.runs(taskId: taskId).map { engine.runs[$0.id ?? -1] ?? $0 }
        guard let run = runs.last(where: \.isActive) ?? runs.last, let runID = run.id else { return nil }
        let workflow = try? engine.workflow(for: run)
        let step = run.currentStep.map { id in workflow.map { RunTimeline.title(ofStep: id, in: $0) } ?? id }
        var lines = ["Ensemble status (not written by the user): run “\(run.title)” is \(Self.describe(run.status))\(step.map { run.isActive ? " at “\($0)”" : "" } ?? ""), \(run.costUSD.formatted(.currency(code: "USD"))) spent."]
        if run.isActive {
            let agents = try database.agents(inProject: run.projectId).filter { $0.runId == runID && $0.taskId != taskId && $0.archivedAt == nil }
            if !agents.isEmpty {
                lines.append("Agents: " + agents.map { "\($0.name) (\($0.role), \(Self.describe($0.status)))" }.joined(separator: "; ") + ".")
            }
            if let hold = engine.holds[runID] {
                lines.append("It is waiting for the user: \(Self.describe(hold.reason)).")
            }
        } else if let outcome = run.outcome, !outcome.isEmpty {
            lines.append("Outcome: \(outcome)")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ status: RunStatus) -> String {
        switch status {
        case .pending: "starting"
        case .running: "running"
        case .waitingOnYou: "waiting for the user"
        case .paused: "paused"
        case .interrupted: "interrupted"
        case .succeeded: "finished"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    static func describe(_ status: AgentStatus) -> String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .needsInput: "needs input"
        case .waiting: "queued"
        case .reviewing: "reviewing"
        case .paused: "paused"
        case .interrupted: "interrupted"
        case .stopped: "stopped"
        case .takenOver: "taken over by the user"
        case .failed: "failed"
        }
    }

    static func describe(_ reason: HoldReason) -> String {
        switch reason {
        case .planApproval: "approving the plan"
        case .approval: "an approval step"
        case .loopLimit: "deciding whether to loop again"
        case .stepBudget, .runBudget: "a budget decision"
        case .stepFailed: "a failed step"
        case .timedOut: "a timed-out step"
        case .gates: "a decision on gate findings"
        }
    }
}
