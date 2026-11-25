import Foundation

public struct WorktreePreparation: Sendable, Equatable {
    public let projectId: Int64
    public let agentID: Int64?
    public let agentName: String
    public let worktree: URL
    public let port: Int?
    public let logDirectory: URL

    public init(projectId: Int64, agentID: Int64?, agentName: String, worktree: URL, port: Int?, logDirectory: URL) {
        self.projectId = projectId
        self.agentID = agentID
        self.agentName = agentName
        self.worktree = worktree
        self.port = port
        self.logDirectory = logDirectory
    }

    public var variables: [String: String] {
        var variables = ["SATURN_WORKTREE": worktree.path, "SATURN_AGENT": agentName]
        if let port { variables["SATURN_PORT"] = String(port) }
        return variables
    }
}

extension AgentRuntime {
    public func runSetupScript(_ preparation: WorktreePreparation) async throws {
        guard let project = try database.project(id: preparation.projectId) else { return }
        let settings = project.settings
        let script = settings.setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        let runner = SetupScriptRunner(
            environment: setupEnvironment(),
            timeout: .seconds(max(1, settings.setupTimeoutMinutes) * 60)
        )
        try await runner.run(script: script, in: preparation.worktree, variables: preparation.variables, logDirectory: preparation.logDirectory)
    }

    public func isSettingUp(_ session: AgentSession) -> Bool {
        settingUp.contains(session.id)
    }

    public func setupLogDirectory(for agent: Agent) -> URL? {
        agent.id.map(paths.agentDirectory)
    }

    public func setupRecord(for agent: Agent) -> SetupRecord? {
        setupLogDirectory(for: agent).flatMap(SetupRecord.load)
    }

    public func setupFailed(_ session: AgentSession) -> Bool {
        guard !isSettingUp(session), session.agent.status == .failed, let record = setupRecord(for: session.agent) else { return false }
        return record.status != .succeeded && record.status != .running
    }

    public func retrySetup(_ session: AgentSession) {
        guard !isSettingUp(session), !session.isRunning, session.agent.worktreeURL != nil else { return }
        session.clearSetupFailure()
        let startTurn = session.agent.runId == nil && !session.agent.task.isEmpty && session.transcript.session == nil
        startAfterPreparing(session, startTurn: startTurn)
    }

    public func repairSetup(of session: AgentSession) async throws {
        guard setupFailed(session) else { return }
        session.clearSetupFailure()
        try await prepareWorktree(of: session)
    }

    public func prepareIntegrationWorktree(at path: URL, name: String, projectId: Int64) async throws {
        guard needsSetup(projectId: projectId) else { return }
        let key = realPath(of: path)
        let owner = try database.agents(inProject: projectId).first { agent in
            agent.archivedAt == nil && agent.worktreeURL.map(realPath(of:)) == key
        }
        let port: Int?
        if let owner {
            port = owner.port
        } else if let reserved = reservedPorts[key] {
            port = reserved
        } else {
            port = try nextPort(forProject: projectId)
            if let port { reservedPorts[key] = port }
        }
        let preparation = WorktreePreparation(
            projectId: projectId,
            agentID: owner?.id,
            agentName: owner?.name ?? name,
            worktree: path,
            port: port,
            logDirectory: owner?.id.map(paths.agentDirectory) ?? paths.pendingWorkspaceDirectory(path.lastPathComponent)
        )
        guard let hook = worktreePrepared else { return }
        if let id = owner?.id { settingUp.insert(id) }
        defer { if let id = owner?.id { settingUp.remove(id) } }
        try await hook(preparation)
    }

    func canRestoreWorktree(of agent: Agent) -> Bool {
        !agent.readOnly && agent.worktreeURL != nil && agent.branch != nil
            && ((try? database.project(id: agent.projectId)).flatMap { $0 }.flatMap(projectGit) != nil)
    }

    func restoreWorktree(of session: AgentSession) async throws {
        let agent = session.agent
        guard let project = try database.project(id: agent.projectId), let git = projectGit(project),
              let path = agent.worktreeURL, let branch = agent.branch else {
            throw AgentLaunchError.missingWorktree(agent.name)
        }
        try await WorktreeManager(project: project, git: git).restore(at: path, branch: branch)
        try await prepareWorktree(of: session)
    }

    func nextPort(forProject projectId: Int64) throws -> Int? {
        guard let base = try database.project(id: projectId)?.settings.basePort else { return nil }
        let taken = PortAllocator.takenPorts(by: try database.agents(inProject: projectId)).union(reservedPorts.values)
        return PortAllocator.port(base: base, taken: taken)
    }

    func needsSetup(projectId: Int64) -> Bool {
        guard worktreePrepared != nil, let project = try? database.project(id: projectId) else { return false }
        return !project.settings.setupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepareWorktree(of session: AgentSession) async throws {
        let agent = session.agent
        guard let hook = worktreePrepared, let worktree = agent.worktreeURL, let id = agent.id,
              needsSetup(projectId: agent.projectId) else { return }
        let preparation = WorktreePreparation(
            projectId: agent.projectId,
            agentID: id,
            agentName: agent.name,
            worktree: worktree,
            port: agent.port,
            logDirectory: paths.agentDirectory(id)
        )
        settingUp.insert(id)
        defer { settingUp.remove(id) }
        do {
            try await hook(preparation)
        } catch {
            session.failSetup(error.localizedDescription)
            throw error
        }
    }

    func startAfterPreparing(_ session: AgentSession, startTurn: Bool) {
        guard session.agent.worktreeURL != nil, needsSetup(projectId: session.agent.projectId) else {
            if startTurn { session.start() }
            return
        }
        settingUp.insert(session.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.prepareWorktree(of: session)
                self.settingUp.remove(session.id)
                if startTurn { session.start() }
            } catch {
                self.settingUp.remove(session.id)
            }
        }
    }

    func adoptIntegrationSetupLog(from worktree: URL, into session: AgentSession) {
        let pending = paths.pendingWorkspaceDirectory(worktree.lastPathComponent)
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        let destination = paths.agentDirectory(session.id)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in [SetupRecord.logFileName, SetupRecord.recordFileName] {
            let target = destination.appending(path: name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: pending.appending(path: name), to: target)
        }
        try? FileManager.default.removeItem(at: pending)
    }

    func launchEnvironment(for agent: Agent) throws -> [String: String] {
        var environment = try launchEnvironment()
        if let port = agent.port {
            environment["PORT"] = String(port)
            environment["SATURN_PORT"] = String(port)
        }
        return environment
    }

    func setupEnvironment() -> [String: String] {
        processEnvironment.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE"
        }
    }

    static func portGuide(_ port: Int) -> String {
        "Your dev server port is \(port). `PORT` and `SATURN_PORT` are set to it; run any server you start on this port so it doesn’t collide with other agents’ worktrees."
    }
}
