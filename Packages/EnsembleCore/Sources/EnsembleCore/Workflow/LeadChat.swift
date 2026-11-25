import Foundation

public enum LeadChatError: Error, LocalizedError, Equatable {
    case proposalClosed
    case runInProgress
    case unknownWorkflow(String)

    public var errorDescription: String? {
        switch self {
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
    var database: AppDatabase { runtime.database }

    public init(runtime: AgentRuntime, engine: RunEngine, driver: AgentWorkflowDriver) {
        self.runtime = runtime
        self.engine = engine
        self.driver = driver
        runtime.observeReplies { [weak self] agent, reply in self?.record(reply: reply, from: agent) }
        runtime.observeTurnEnds { [weak self] session in self?.cleanUpAfterLeadTurn(session) }
    }

    @discardableResult
    public func createRequest(
        _ text: String, attachments: [ChatAttachment] = [], in project: Project, workflow: String? = nil,
        leadModel: String? = nil, leadEffort: LeadEffort? = nil, now: Date = .now
    ) async throws -> Chat {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let projectId = project.id, !typed.isEmpty || !attachments.isEmpty else { throw AgentError.emptyTask }
        let task = try database.insert(Chat(
            projectId: projectId, title: Self.title(text: typed, attachments: attachments),
            body: ChatAttachment.prompt(text: typed, attachments: attachments), source: .chat,
            workflow: workflow, status: .incoming, leadModel: leadModel, leadEffort: leadEffort, createdAt: now, updatedAt: now
        ))
        try await send(typed, attachments: attachments, to: task, in: project, now: now)
        return task
    }

    public func send(
        _ text: String, attachments: [ChatAttachment] = [], to task: Chat, in project: Project, now: Date = .now
    ) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let taskId = task.id, !body.isEmpty || !attachments.isEmpty else { return }
        try await driver.ensureServer()
        let session = try leadSession(for: task, in: project)
        if let current = try database.task(id: taskId), current.isClosed || current.isFinished {
            try database.setClosed(taskId: taskId, reason: nil, at: now)
            driver.closingTasks.remove(taskId)
        }
        try database.insert(LeadMessage(
            projectId: task.projectId, taskId: taskId, kind: .user, text: body, createdAt: now,
            attachments: try ChatAttachmentStore(paths: runtime.paths).store(attachments)
        ))
        let prompt = ChatAttachment.prompt(text: body, attachments: attachments)
        #if DEBUG
        runtime.debugTrace?.chatMessage(body, direction: "user_to_agent", chat: "lead", agent: session.agent, at: now)
        #endif
        let notes = [
            driver.rejectionNote(projectId: task.projectId, taskId: taskId),
            try workflowNote(taskId: taskId), try statusNote(taskId: taskId),
        ].compactMap(\.self)
        let status = notes.isEmpty ? "" : (prompt.isEmpty ? "" : "\n\n---\n") + notes.joined(separator: "\n\n---\n")
        session.send(prompt + status, images: attachments.filter(\.isImage))
    }

    public func deliverSpecFeedback(_ message: String, taskId: Int64, now: Date = .now) async throws {
        guard let task = try database.task(id: taskId), let project = try database.project(id: task.projectId) else { return }
        try await driver.ensureServer()
        let session = try leadSession(for: task, in: project)
        try database.insert(LeadMessage(projectId: task.projectId, taskId: taskId, kind: .specFeedback, text: message, createdAt: now))
        #if DEBUG
        runtime.debugTrace?.chatMessage(message, direction: "user_to_agent", chat: "lead", agent: session.agent, at: now)
        #endif
        session.send(SpecFeedback.leadPrompt(message))
    }

    static func title(text: String, attachments: [ChatAttachment]) -> String {
        if !text.isEmpty { return LeadRequest.title(for: text) }
        if let pasted = attachments.lazy.compactMap(\.pastedText).first(where: { !LeadRequest.title(for: $0).isEmpty }) {
            return LeadRequest.title(for: pasted)
        }
        return "Image"
    }

    @discardableResult
    public func close(_ task: Chat, as reason: RequestCloseReason, in project: Project, git: GitClient, now: Date = .now) async throws -> Chat {
        guard let taskId = task.id, try database.task(id: taskId) != nil else { throw RunEngineError.invalidState("The request is gone.") }
        guard !(try hasActiveRun(taskId: taskId)) else { throw LeadChatError.runInProgress }
        for agent in try database.requestAgents(taskId: taskId) {
            guard let session = runtime.session(for: agent) else { continue }
            try await runtime.delete(session, in: project, git: git, deleteBranch: true)
        }
        guard !(try hasActiveRun(taskId: taskId)), let closed = try database.setClosed(taskId: taskId, reason: reason, at: now) else {
            throw LeadChatError.runInProgress
        }
        await driver.specReviews?.endSpecReview(taskId: taskId)
        return closed
    }

    @discardableResult
    public func finish(_ task: Chat, now: Date = .now) throws -> Chat {
        guard let taskId = task.id else { throw ChatActionError.notFound }
        guard !(try hasActiveRun(taskId: taskId)) else { throw LeadChatError.runInProgress }
        guard let finished = try database.setFinished(taskId: taskId, at: now) else { throw ChatActionError.notFound }
        return finished
    }

    public func deleteAgentsOfClosedRequests(in project: Project, git: GitClient) async {
        guard let projectId = project.id, let tasks = try? database.closedTasks(projectId: projectId) else { return }
        for taskId in tasks.compactMap(\.id) {
            await deleteAgents(ofClosedTask: taskId, in: project, git: git)
        }
    }

    func deleteAgents(ofClosedTask taskId: Int64, in project: Project, git: GitClient) async {
        guard (try? database.task(id: taskId))??.isClosed == true, (try? hasActiveRun(taskId: taskId)) == false else { return }
        for agent in (try? database.requestAgents(taskId: taskId)) ?? [] {
            guard let session = runtime.session(for: agent) else { continue }
            try? await runtime.delete(session, in: project, git: git, deleteBranch: true)
        }
    }

    func cleanUpAfterLeadTurn(_ session: AgentSession) {
        guard session.agent.kind == .lead, let taskId = session.agent.taskId, driver.closingTasks.remove(taskId) != nil,
              let project = try? database.project(id: session.agent.projectId), let git = try? driver.requireGit(for: project) else { return }
        Task { await deleteAgents(ofClosedTask: taskId, in: project, git: git) }
    }

    private func hasActiveRun(taskId: Int64) throws -> Bool {
        try database.runs(taskId: taskId).contains { (engine.runs[$0.id ?? -1] ?? $0).isActive }
    }

    public func leadSession(for task: Chat) -> AgentSession? {
        guard let taskId = task.id, let agent = try? database.leadAgent(taskId: taskId) else { return nil }
        return runtime.session(for: agent)
    }

    public func workingSessions(for task: Chat) -> [AgentSession] {
        guard let taskId = task.id,
              let requestAgents = try? database.requestAgents(taskId: taskId),
              let spawned = try? database.spawnedAgents(taskId: taskId) else { return [] }
        let leadId = (try? database.leadAgent(taskId: taskId))??.id
        var seen = Set<Int64>()
        return (requestAgents + spawned)
            .filter { agent in
                guard let id = agent.id, id != leadId else { return false }
                return seen.insert(id).inserted
            }
            .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
            .compactMap { runtime.session(for: $0) }
            .filter { $0.isRunning || $0.isQueued }
    }

    @discardableResult
    public func start(_ proposal: LeadMessage, in project: Project) async throws -> Run {
        let current = try openProposal(proposal)
        guard let workflow = current.workflow else { throw LeadChatError.proposalClosed }
        let launch = RunLaunch(taskId: current.taskId, workflow: workflow, title: current.title, brief: current.text)
        let run = try await start(launch, in: project) { _ = try self.openProposal(proposal) }
        var started = try database.leadMessage(id: current.id ?? -1) ?? current
        started.status = .started
        started.runId = run.id
        try database.save(started)
        return run
    }

    @discardableResult
    public func approveSpec(taskId: Int64, in project: Project) async throws -> Run {
        guard let task = try database.task(id: taskId) else { throw RunEngineError.invalidState("The request is gone.") }
        guard !(try hasActiveRun(taskId: taskId)) else { throw LeadChatError.runInProgress }
        let store = SpecStore(paths: runtime.paths)
        guard FileManager.default.fileExists(atPath: store.draftURL(projectId: task.projectId, taskId: taskId).path),
              let document = try store.draft(projectId: task.projectId, taskId: taskId) else { throw SpecReviewError.noDraft }
        guard document.status == .draft || document.status == .rejected || document.status == .approved else { throw SpecReviewError.committed }
        if let proposal = try openProposal(taskId: taskId) {
            return try await approving(document, in: task) { try await start(proposal, in: project) }
        }
        let config = ProjectConfigLoader.load(repository: project.filesRoot)
        let workflow = [Self.specWorkflow, task.workflow, config.preferences.defaultWorkflow].compactMap(\.self).first { config.workflow($0) != nil }
        guard let workflow else { throw LeadChatError.unknownWorkflow(Self.specWorkflow) }
        let launch = RunLaunch(taskId: taskId, workflow: workflow, title: document.title, brief: Self.brief(for: document))
        return try await approving(document, in: task) { try await start(launch, in: project) {} }
    }

    private func approving(_ document: SpecDocument, in task: Chat, start: () async throws -> Run) async throws -> Run {
        try setSpecStatus(.approved, of: document, in: task)
        do {
            return try await start()
        } catch {
            try? setSpecStatus(document.status, of: document, in: task)
            throw error
        }
    }

    static let specWorkflow = "feature-delivery"

    static func brief(for document: SpecDocument) -> String {
        var parts = [document.summary.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        if !document.acceptanceCriteria.isEmpty {
            parts.append("Acceptance criteria:\n" + document.acceptanceCriteria.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    struct RunLaunch {
        var taskId: Int64
        var workflow: String
        var title: String?
        var brief: String
    }

    private func start(_ launch: RunLaunch, in project: Project, recheck: () throws -> Void) async throws -> Run {
        let taskId = launch.taskId
        guard try database.task(id: taskId) != nil else { throw RunEngineError.invalidState("The request is gone.") }
        guard try !database.runs(taskId: taskId).contains(where: \.isActive) else { throw LeadChatError.runInProgress }
        let config = ProjectConfigLoader.load(repository: project.filesRoot)
        guard let workflow = config.workflow(launch.workflow) else { throw LeadChatError.unknownWorkflow(launch.workflow) }
        try await clearPreviousRunAgents(taskId: taskId, in: project)
        try recheck()
        guard let task = try database.task(id: taskId) else { throw RunEngineError.invalidState("The request is gone.") }
        guard try !database.runs(taskId: taskId).contains(where: \.isActive) else { throw LeadChatError.runInProgress }
        let lead = try database.leadAgent(taskId: taskId)
        let spec = try pendingSpec(taskId: taskId, projectId: task.projectId)
        if task.isClosed || task.isFinished {
            try database.setClosed(taskId: taskId, reason: nil, at: .now)
        }
        let run = try engine.start(task: task, workflow: workflow, project: project, title: launch.title, brief: launch.brief)
        if let spec {
            try attachSpec(to: run, taskId: taskId, document: spec, project: project, config: config)
            Task { [weak self] in await self?.driver.specReviews?.endSpecReview(taskId: taskId) }
        }
        try database.markSpecDraftStarted(taskId: taskId, runId: run.id)
        if let lead, let runID = run.id {
            runtime.session(for: lead)?.attach(toRun: runID)
        }
        return run
    }

    private func setSpecStatus(_ status: SpecStatus, of document: SpecDocument, in task: Chat) throws {
        guard let taskId = task.id else { return }
        let store = SpecStore(paths: runtime.paths)
        var updated = document
        updated.status = status
        try store.write(updated, to: store.draftURL(projectId: task.projectId, taskId: taskId))
    }

    private func clearPreviousRunAgents(taskId: Int64, in project: Project) async throws {
        let sessions = try database.previousRunAgents(taskId: taskId).compactMap { runtime.session(for: $0) }
        guard !sessions.isEmpty else { return }
        let git = try driver.requireGit(for: project)
        var cleared: [Agent] = []
        for session in sessions {
            let agent = session.agent
            try await runtime.delete(session, in: project, git: git, deleteBranch: false)
            cleared.append(agent)
        }
        let names = cleared.map { database.displayName(of: $0) }.joined(separator: ", ")
        try database.insert(LeadMessage(
            projectId: project.id ?? cleared[0].projectId, taskId: taskId, kind: .note,
            text: "Cleared \(database.previousRunSummary(of: cleared)): \(names)", createdAt: .now
        ))
    }

    public func reject(_ proposal: LeadMessage) throws {
        try dismiss(proposal)
        try driver.rejectSpec(projectId: proposal.projectId, taskId: proposal.taskId)
    }

    public func dismiss(_ proposal: LeadMessage) throws {
        var dismissed = try openProposal(proposal)
        dismissed.status = .dismissed
        try database.save(dismissed)
    }

    private func openProposal(taskId: Int64) throws -> LeadMessage? {
        try database.leadMessages(taskId: taskId).last { $0.kind == .proposal && $0.status == .open }
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

    private func leadSession(for task: Chat, in project: Project) throws -> AgentSession {
        if let session = leadSession(for: task) { return session }
        guard let taskId = task.id else { throw AgentError.emptyTask }
        let session = try runtime.createLeadAgent(in: project, taskId: taskId)
        if let model = task.leadModel { session.setModel(model) }
        return session
    }

    func workflowNote(taskId: Int64) throws -> String? {
        guard let workflow = try database.task(id: taskId)?.workflow else { return nil }
        return "Ensemble note (not written by the user): the user picked the `\(workflow)` workflow for this chat. Propose runs with it unless they ask for another."
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
                lines.append("Agents: " + agents.map { "\(database.displayName(of: $0)) (\($0.kind?.rawValue ?? $0.role), \(Self.describe($0.status)))" }.joined(separator: "; ") + ".")
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
