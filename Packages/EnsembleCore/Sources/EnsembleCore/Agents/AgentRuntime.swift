import Darwin
import Foundation
import Observation

public enum AgentError: Error, LocalizedError, Equatable {
    case nameTaken(String)
    case emptyTask
    case providerNotChosen
    case unknownModel(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "An agent named \(name) already exists in this project."
        case .emptyTask: "Describe a task for the agent."
        case .providerNotChosen: "Choose whether agents use an Anthropic API key or your Claude sign-in before starting one."
        case .unknownModel(let model): "“\(model)” isn’t a model Claude Code knows. Use an alias like sonnet or a full name starting with claude-."
        }
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case apiKeyMissing
    case wrongCredentials(expected: ProviderMode, actualSource: String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            "Agents are set to use an Anthropic API key, but none is stored in the Keychain. Add one in Settings."
        case .wrongCredentials(let expected, let source):
            "Claude Code started with credentials from “\(source)” instead of your \(expected.title). Ensemble stopped the turn so it isn’t billed to the wrong account."
        }
    }
}

public enum AgentLaunchError: Error, LocalizedError, Equatable {
    case missingWorktree(String)
    case missingProject(String)

    public var errorDescription: String? {
        switch self {
        case .missingWorktree(let name): "The worktree for \(name) is missing."
        case .missingProject(let name): "The project folder for \(name) is missing."
        }
    }
}

struct TurnSetup {
    let directory: URL
    let systemPrompt: String
    let readOnly: Bool
    let additionalDirectories: [URL]
    var extraArguments: [String] = []
    var extraAllowedTools: [String] = []
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
@Observable
public final class AgentRuntime {
    public let database: AppDatabase
    public let paths: AppPaths
    public var claudeExecutable: URL?
    public var processEnvironment: [String: String]
    public var providerMode: ProviderMode?
    public var mcpServer: EnsembleMCPServer?
    public var handoffTools: @MainActor (Agent) -> Set<HandoffTool> = { _ in [] }
    public var worktreePrepared: (@MainActor (WorktreePreparation) async throws -> Void)?
    public internal(set) var settingUp: Set<Int64> = []
    public private(set) var usageRevision = 0

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let launcher: any AgentProcessLauncher
    @ObservationIgnored let stopGracePeriod: Duration
    @ObservationIgnored private var sessions: [Int64: AgentSession] = [:]
    private var turnQueue: [Int64: [Int64]] = [:]
    @ObservationIgnored public internal(set) var memoryUpdateAgents: Set<Int64> = []
    @ObservationIgnored var reservedPorts: [String: Int] = [:]

    public init(
        database: AppDatabase,
        paths: AppPaths,
        secrets: any SecretStore,
        providerMode: ProviderMode?,
        launcher: any AgentProcessLauncher = ClaudeProcessLauncher(),
        claudeExecutable: URL? = nil,
        processEnvironment: [String: String] = [:],
        stopGracePeriod: Duration = .seconds(8)
    ) {
        self.database = database
        self.paths = paths
        self.secrets = secrets
        self.providerMode = providerMode
        self.launcher = launcher
        self.claudeExecutable = claudeExecutable
        self.processEnvironment = processEnvironment
        self.stopGracePeriod = stopGracePeriod
    }

    public func session(for agent: Agent) -> AgentSession? {
        guard let id = agent.id else { return nil }
        if let session = sessions[id] { return session }
        let session = AgentSession(agent: agent, runtime: self)
        sessions[id] = session
        return session
    }

    public func sessions(inProject projectId: Int64) throws -> [AgentSession] {
        try database.agents(inProject: projectId).compactMap { session(for: $0) }
    }

    public var hasRunningAgents: Bool {
        sessions.values.contains { $0.isRunning }
    }

    @discardableResult
    public func spawn(
        in project: Project,
        name: String,
        model: AgentModel,
        task: String,
        git: GitClient,
        now: Date = .now
    ) async throws -> AgentSession {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerMode != nil else { throw AgentError.providerNotChosen }
        guard let projectId = project.id else { throw AgentError.emptyTask }
        guard !task.isEmpty else { throw AgentError.emptyTask }
        guard !Slug.make(name).isEmpty else { throw WorktreeError.invalidName(name) }
        let existing = try database.agents(inProject: projectId)
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || Slug.make($0.name) == Slug.make(name) }) else {
            throw AgentError.nameTaken(name)
        }

        let manager = WorktreeManager(repository: project.url, git: git)
        let base = try await git.currentBranch(in: project.url)
        let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
        let worktree = try await manager.create(agent: name, slug: taskSlug.isEmpty ? "task" : taskSlug)

        let agent = try database.insert(Agent(
            projectId: projectId,
            role: "claude-code",
            name: name,
            worktreePath: worktree.path.path,
            branch: worktree.branch,
            status: .idle,
            model: model.rawValue,
            task: task,
            baseBranch: base ?? worktree.head,
            port: try nextPort(forProject: projectId),
            createdAt: now,
            updatedAt: now
        ))
        guard let session = session(for: agent) else { throw AgentError.emptyTask }
        startAfterPreparing(session, startTurn: true)
        usageDidChange()
        return session
    }

    public static let maxSpawnCount = 8

    public func agentNames(for base: String, count: Int, inProject projectId: Int64) throws -> [String] {
        AgentNaming.names(base: base, count: count, existing: try database.agents(inProject: projectId).map(\.name))
    }

    @discardableResult
    public func spawn(
        in project: Project,
        role: RoleDefinition,
        count: Int,
        config: ProjectConfig,
        git: GitClient,
        pinned: Bool = false,
        name: String? = nil,
        model: String? = nil,
        task: String = "",
        now: Date = .now
    ) async throws -> [AgentSession] {
        guard providerMode != nil else { throw AgentError.providerNotChosen }
        guard let projectId = project.id else { throw AgentError.emptyTask }
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? role.model
        guard ModelCatalog.isValid(model) else { throw AgentError.unknownModel(model) }
        let count = min(max(count, 1), Self.maxSpawnCount)
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? role.name
        guard !Slug.make(base).isEmpty else { throw WorktreeError.invalidName(base) }
        let names = try agentNames(for: base, count: count, inProject: projectId)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBranch = try await git.currentBranch(in: project.url)
        let manager = WorktreeManager(repository: project.url, git: git)
        let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))

        var spawned: [AgentSession] = []
        for agentName in names {
            var worktreePath: String?
            var branch: String?
            var base = baseBranch
            if role.editsCode {
                let worktree = try await manager.create(agent: agentName, slug: taskSlug.isEmpty ? "task" : taskSlug)
                worktreePath = worktree.path.path
                branch = worktree.branch
                base = baseBranch ?? worktree.head
            }
            let agent = try database.insert(Agent(
                projectId: projectId,
                role: role.id,
                name: agentName,
                worktreePath: worktreePath,
                branch: branch,
                status: .idle,
                isPinned: pinned,
                model: model,
                task: task,
                baseBranch: base,
                readOnly: !role.editsCode,
                port: worktreePath == nil ? nil : try nextPort(forProject: projectId),
                createdAt: now,
                updatedAt: now
            ))
            guard let session = session(for: agent) else { continue }
            spawned.append(session)
        }
        usageDidChange()
        for session in spawned {
            startAfterPreparing(session, startTurn: !task.isEmpty)
        }
        return spawned
    }

    func turnSetup(for agent: Agent) throws -> TurnSetup {
        try checkMonthlyBudget(for: agent)
        let project = try database.project(id: agent.projectId)
        let repository = project?.url
        let directory: URL
        if agent.readOnly, let worktree = agent.worktreeURL {
            directory = worktree
        } else if agent.readOnly {
            guard let repository else { throw AgentLaunchError.missingProject(agent.name) }
            directory = repository
        } else {
            guard let worktree = agent.worktreeURL else { throw AgentLaunchError.missingWorktree(agent.name) }
            directory = worktree
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw agent.readOnly ? AgentLaunchError.missingProject(agent.name) : AgentLaunchError.missingWorktree(agent.name)
        }

        var prompt = agent.readOnly
            ? ClaudeLaunch.readOnlySystemPrompt(agentName: agent.name, directory: directory)
            : ClaudeLaunch.systemPrompt(agentName: agent.name, worktree: directory, branch: agent.branch)
        if let repository {
            let config = ProjectConfigLoader.load(repository: repository)
            if let role = config.role(agent.role) {
                let context = RoleContext.build(role: role, config: config, repository: repository).systemPrompt
                if !context.isEmpty { prompt += "\n\n" + context }
            }
            if let memory = memoryPromptSection(for: agent, repository: repository) { prompt += "\n\n" + memory }
        }
        if let port = agent.port {
            prompt += "\n\n" + Self.portGuide(port)
        }

        var additional: [URL] = []
        if agent.readOnly, let runId = agent.runId {
            let root = realPath(of: directory) + "/"
            additional = try database.agents(inProject: agent.projectId)
                .filter { $0.runId == runId && $0.id != agent.id }
                .compactMap(\.worktreeURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) && !(realPath(of: $0) + "/").hasPrefix(root) }
        }
        var setup = TurnSetup(directory: directory, systemPrompt: prompt, readOnly: agent.readOnly, additionalDirectories: additional)
        let tools = handoffTools(agent)
        if let server = mcpServer, let agentID = agent.id, !tools.isEmpty {
            server.revokeAll(agent: agentID)
            let endpoint = server.register(agent: agentID, tools: tools)
            setup.extraArguments = try endpoint.launchArguments(configDirectory: paths.agentDirectory(agentID))
            setup.extraAllowedTools = endpoint.allowedTools
            setup = TurnSetup(
                directory: setup.directory,
                systemPrompt: setup.systemPrompt + "\n\n" + Self.handoffGuide(tools),
                readOnly: setup.readOnly,
                additionalDirectories: setup.additionalDirectories,
                extraArguments: setup.extraArguments,
                extraAllowedTools: setup.extraAllowedTools
            )
        }
        return try addingMemoryAccess(to: setup, for: agent, repository: repository)
    }

    static func handoffGuide(_ tools: Set<HandoffTool>) -> String {
        let lines = HandoffTool.allCases.filter(tools.contains).map { "- `\($0.qualifiedName)`: \($0.description)" }
        return "You are part of an Ensemble workflow run. Hand your work back through these tools:\n" + lines.joined(separator: "\n")
    }

    public func maxConcurrentAgents(inProject projectId: Int64) -> Int {
        let limit = (try? database.project(id: projectId))??.settings.maxConcurrentAgents ?? ProjectSettings().maxConcurrentAgents
        return max(1, limit)
    }

    public func runningCount(inProject projectId: Int64) -> Int {
        sessions.values.filter { $0.agent.projectId == projectId && $0.isRunning }.count
    }

    public func queuedSessions(inProject projectId: Int64) -> [AgentSession] {
        (turnQueue[projectId] ?? []).compactMap { sessions[$0] }
    }

    func shouldQueue(_ session: AgentSession) -> Bool {
        let projectId = session.agent.projectId
        let waiting = turnQueue[projectId] ?? []
        if waiting.contains(session.id) { return true }
        return !waiting.isEmpty || runningCount(inProject: projectId) >= maxConcurrentAgents(inProject: projectId)
    }

    func enqueue(_ session: AgentSession) {
        let projectId = session.agent.projectId
        if !(turnQueue[projectId] ?? []).contains(session.id) {
            turnQueue[projectId, default: []].append(session.id)
        }
    }

    func dequeue(_ session: AgentSession) {
        turnQueue[session.agent.projectId]?.removeAll { $0 == session.id }
    }

    public func startQueuedTurns(inProject projectId: Int64) {
        let limit = maxConcurrentAgents(inProject: projectId)
        while runningCount(inProject: projectId) < limit, let next = turnQueue[projectId]?.first {
            turnQueue[projectId]?.removeFirst()
            sessions[next]?.startQueuedTurn()
        }
    }

    public func delete(_ session: AgentSession, in project: Project, git: GitClient, deleteBranch: Bool) async throws {
        dequeue(session)
        session.terminateForDeletion()
        let manager = WorktreeManager(repository: project.url, git: git)
        if let path = session.agent.worktreeURL,
           let worktree = try await manager.list().first(where: { $0.agent == path.lastPathComponent }) {
            try await manager.remove(worktree, force: true, deleteBranch: deleteBranch)
        } else if deleteBranch, let branch = session.agent.branch {
            _ = try? await git.run(["branch", "-D", branch], in: project.url)
        }
        try database.deleteAgent(id: session.id)
        sessions[session.id] = nil
        try? FileManager.default.removeItem(at: paths.agentDirectory(session.id))
        usageDidChange()
        if let projectId = project.id {
            startQueuedTurns(inProject: projectId)
        }
    }

    public func recoverAfterLaunch() throws {
        for agent in try database.agentsWithLiveProcesses() {
            if let pid = agent.processID {
                Self.terminateLeftoverClaude(pid: pid)
            }
            session(for: agent)?.markInterrupted(detail: "Ensemble wasn’t running when this turn ended.")
        }
        for agent in try database.agentsQueuedOutsideRuns() {
            session(for: agent)?.markInterrupted(detail: "Ensemble quit while this agent was queued.")
        }
    }

    public func terminateAll(gracePeriod: Duration = .seconds(2)) {
        let handles = sessions.values
            .filter(\.isRunning)
            .compactMap { $0.markInterrupted(detail: "Ensemble quit during this turn.") }
        let deadline = ContinuousClock.now + gracePeriod
        while handles.contains(where: \.isRunning), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for handle in handles where handle.isRunning {
            handle.kill()
        }
    }

    func launchEnvironment() throws -> [String: String] {
        switch providerMode {
        case nil:
            throw AgentError.providerNotChosen
        case .claudeSignIn:
            return ProviderMode.claudeSignIn.environment(base: processEnvironment, apiKey: nil)
        case .apiKey:
            guard let key = try secrets.read(.anthropicAPIKey), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderError.apiKeyMissing
            }
            return ProviderMode.apiKey.environment(base: processEnvironment, apiKey: key)
        }
    }

    func usageDidChange() {
        usageRevision += 1
    }

    static func terminateLeftoverClaude(pid: Int32) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path.lowercased().contains("claude") else { return }
        kill(pid, SIGTERM)
    }
}

extension AgentRuntime {
    public func createRunAgent(
        in project: Project,
        role: RoleDefinition,
        name: String? = nil,
        runId: Int64,
        runStepId: Int64?,
        planTaskId: String? = nil,
        task: String,
        readOnlyWorktree: (path: URL, branch: String?)? = nil,
        git: GitClient,
        now: Date = .now
    ) async throws -> AgentSession {
        guard providerMode != nil else { throw AgentError.providerNotChosen }
        guard let projectId = project.id else { throw AgentError.emptyTask }
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? role.name
        guard let agentName = try agentNames(for: base, count: 1, inProject: projectId).first else {
            throw WorktreeError.invalidName(base)
        }
        let baseBranch = try await git.currentBranch(in: project.url)
        var worktreePath: String?
        var branch: String?
        var resolvedBase = baseBranch
        var port: Int?
        if let readOnlyWorktree {
            worktreePath = readOnlyWorktree.path.path
            branch = readOnlyWorktree.branch
            port = try reservedPorts.removeValue(forKey: realPath(of: readOnlyWorktree.path)) ?? nextPort(forProject: projectId)
        } else if role.editsCode {
            let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
            let worktree = try await WorktreeManager(repository: project.url, git: git)
                .create(agent: agentName, slug: taskSlug.isEmpty ? "task" : taskSlug)
            worktreePath = worktree.path.path
            branch = worktree.branch
            resolvedBase = baseBranch ?? worktree.head
            port = try nextPort(forProject: projectId)
        }
        let agent = try database.insert(Agent(
            projectId: projectId,
            runId: runId,
            role: role.id,
            name: agentName,
            worktreePath: worktreePath,
            branch: branch,
            status: .idle,
            model: role.model,
            task: task,
            baseBranch: resolvedBase,
            runStepId: runStepId,
            readOnly: !role.editsCode,
            planTaskId: planTaskId,
            port: port,
            createdAt: now,
            updatedAt: now
        ))
        guard let session = session(for: agent) else { throw AgentError.emptyTask }
        usageDidChange()
        if let readOnlyWorktree {
            adoptIntegrationSetupLog(from: readOnlyWorktree.path, into: session)
        } else if worktreePath != nil {
            try await prepareWorktree(of: session)
        }
        return session
    }

    public func runSessions(runId: Int64, projectId: Int64) throws -> [AgentSession] {
        try database.agents(inProject: projectId).filter { $0.runId == runId }.compactMap { session(for: $0) }
    }
}

