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
    var systemPrompt: String
    let readOnly: Bool
    var additionalDirectories: [URL]
    var extraArguments: [String] = []
    var extraAllowedTools: [String] = []
    var hooks: JSONValue?
    var permissions: PermissionPolicy?
    var askTools: [String] = []
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
    public var gitProvider: @MainActor () -> GitClient? = { nil }
    public var apiRetryDelays: [Duration] = [.seconds(60), .seconds(300), .seconds(900), .seconds(1800), .seconds(3600)]
    public var crashRestartLimit = 1
    public internal(set) var settingUp: Set<Int64> = []
    public private(set) var usageRevision = 0
    public private(set) var apiCooldownUntil: Date?
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?
    @ObservationIgnored var hookStates: [Int64: AgentHookState] = [:]

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let launcher: any AgentProcessLauncher
    @ObservationIgnored let stopGracePeriod: Duration
    @ObservationIgnored private var sessions: [Int64: AgentSession] = [:]
    @ObservationIgnored private var replyObservers: [@MainActor (Agent, String) -> Void] = []
    @ObservationIgnored private var turnEndObservers: [@MainActor (AgentSession) -> Void] = []
    private var turnQueue: [Int64: [Int64]] = [:]
    @ObservationIgnored public internal(set) var memoryUpdateAgents: Set<Int64> = []
    @ObservationIgnored var reservedPorts: [String: Int] = [:]
    #if DEBUG
    @ObservationIgnored var debugTrace: DebugTrace?
    #endif

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
        #if DEBUG
        self.debugTrace = DebugTrace(paths: paths) { [database] runId in (try? database.run(id: runId))??.title }
        #endif
    }

    public func observeReplies(_ observer: @escaping @MainActor (Agent, String) -> Void) {
        replyObservers.append(observer)
    }

    func turnReplied(_ agent: Agent, _ reply: String) {
        for observer in replyObservers {
            observer(agent, reply)
        }
    }

    public func observeTurnEnds(_ observer: @escaping @MainActor (AgentSession) -> Void) {
        turnEndObservers.append(observer)
    }

    func turnEnded(_ session: AgentSession) {
        for observer in turnEndObservers {
            observer(session)
        }
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
        let base = try await git.baseBranch(of: project.url)
        let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
        let worktree = try await manager.create(agent: name, slug: taskSlug.isEmpty ? "task" : taskSlug, from: base)

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

    public nonisolated static let maxSpawnCount = 8

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
        spawnedBy spawner: Agent? = nil,
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
        let baseBranch = try await git.baseBranch(of: project.url)
        let manager = WorktreeManager(repository: project.url, git: git)
        let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))

        var spawned: [AgentSession] = []
        for agentName in names {
            var worktreePath: String?
            var branch: String?
            var base = baseBranch
            if role.editsCode {
                let worktree = try await manager.create(agent: agentName, slug: taskSlug.isEmpty ? "task" : taskSlug, from: baseBranch)
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
                spawnedById: spawner?.id,
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

        let tools = handoffTools(agent)
        let config = repository.map { ProjectConfigLoader.load(repository: $0) }
        let policy = PermissionPolicy(profile: (config?.permissions ?? PermissionsConfig()).resolve(for: config?.role(agent.role), readOnly: agent.readOnly), readOnly: agent.readOnly)
        let name = AgentNaming.displayName(of: agent, config: config)
        var prompt = agent.readOnly
            ? ClaudeLaunch.readOnlySystemPrompt(agentName: name, directory: directory, canOpenWorktree: mcpServer != nil && tools.contains(.openWorktree), commands: policy.commands)
            : ClaudeLaunch.systemPrompt(agentName: name, worktree: directory, branch: agent.branch, commands: policy.commands)
        if let guide = ClaudeLaunch.askGuide(policy), mcpServer != nil { prompt += "\n\n" + guide }
        var isLead = false
        if let repository, let config {
            if let role = config.role(agent.role) {
                isLead = role.canSpawn
                let context = RoleContext.build(role: role, config: config, repository: repository).systemPrompt
                if !context.isEmpty { prompt += "\n\n" + context }
            }
            if agent.taskId != nil {
                prompt += "\n\n" + Self.leadChatGuide(workflows: config.workflows, defaultWorkflow: config.preferences.defaultWorkflow)
            } else if agent.runId != nil {
                prompt += "\n\n" + Self.webToolsGuide
            }
            if let memory = memoryPromptSection(for: agent, repository: repository) { prompt += "\n\n" + memory }
            if !agent.readOnly, let checks = config.checks, let guide = Self.checksGuide(checks) { prompt += "\n\n" + guide }
        }
        if mcpServer != nil, agent.taskId == nil, let spawnerID = agent.spawnedById, let spawner = try database.agent(id: spawnerID) {
            prompt += "\n\n" + Self.spawnedAgentGuide(spawner: AgentNaming.displayName(of: spawner, config: config))
        }
        if let port = agent.port {
            prompt += "\n\n" + Self.portGuide(port)
        }

        var additional: [URL] = []
        if agent.readOnly || isLead, let runId = agent.runId {
            let root = realPath(of: directory) + "/"
            additional = try database.agents(inProject: agent.projectId)
                .filter { $0.runId == runId && $0.id != agent.id }
                .compactMap(\.worktreeURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) && !(realPath(of: $0) + "/").hasPrefix(root) }
        }
        var setup = TurnSetup(directory: directory, systemPrompt: prompt, readOnly: agent.readOnly, additionalDirectories: additional)
        setup.permissions = policy
        if agent.taskId != nil || agent.runId != nil {
            switch policy.level(.network) {
            case .allow: setup.extraAllowedTools += AgentPermissions.webTools
            case .ask where mcpServer != nil: setup.askTools += AgentPermissions.webTools
            default: break
            }
            setup.extraAllowedTools += AgentPermissions.artifactTools
        }
        if policy.level(.editFiles) == .ask, mcpServer != nil { setup.askTools += AgentPermissions.fileWritingTools }
        let hookChecks = agent.readOnly ? nil : config?.checks
        if let server = mcpServer, let agentID = agent.id {
            server.revokeAll(agent: agentID)
            let endpoint = server.register(agent: agentID, tools: tools)
            if !tools.isEmpty {
                setup.extraArguments = try endpoint.launchArguments(configDirectory: paths.agentDirectory(agentID))
                setup.extraAllowedTools += endpoint.allowedTools
                setup.systemPrompt += "\n\n" + Self.handoffGuide(tools)
            }
            setup.hooks = Self.hookSettings(checks: hookChecks, policy: policy, url: server.hookURL(for: endpoint))
        }
        return try addingMemoryAccess(to: setup, for: agent, repository: repository)
    }

    static func handoffGuide(_ tools: Set<HandoffTool>) -> String {
        let lines = HandoffTool.allCases.filter(tools.contains).map { "- `\($0.qualifiedName)`: \($0.description)" }
        return "Ensemble gives you these tools to hand back your work and coordinate with other agents:\n" + lines.joined(separator: "\n")
    }

    static var webToolsGuide: String {
        "You can use \(codeList(AgentPermissions.webTools)) to look things up on the web. "
            + "To open a claude.ai artifact link the user shares, call `Artifact` with `action: \"read\"` and the link as `url`; "
            + "never fetch artifact links with `WebFetch`, because their pages are drawn by JavaScript and come back empty. "
            + "Use \(codeList(AgentPermissions.artifactDataTools)) for an artifact's data and comments."
    }

    static func codeList(_ names: [String]) -> String {
        let quoted = names.map { "`\($0)`" }
        guard let last = quoted.last, quoted.count > 1 else { return quoted.joined() }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    static func leadChatGuide(workflows: [WorkflowDefinition], defaultWorkflow: String? = nil) -> String {
        let list = workflows.map { workflow in
            let marker = workflow.id == defaultWorkflow ? " (the default: propose it unless another fits clearly better)" : ""
            return "- `\(workflow.id)`: \(workflow.displayName)\(marker)\(workflow.description.isEmpty ? "" : " — \(workflow.description)")"
        }
        return """
        # Chatting with the user
        You are the lead for one request in Ensemble. The user talks to you in a chat; each of their messages arrives as your next turn, and your final text in a turn is shown to them as your reply. Keep replies short and direct.
        Answer questions by reading the code. \(webToolsGuide) When work should be done, propose a run with `\(HandoffTool.proposeRun.qualifiedName)`. The user starts it; then you plan it as the run's lead, with everything you discussed. Only change code yourself when it can't wait for a run, after opening your own worktree with `\(HandoffTool.openWorktree.qualifiedName)`.
        While a run is going, the user's messages come with its status. Answer from that status, and use `\(HandoffTool.messageAgent.qualifiedName)` to pass instructions on to the run's agents.
        During a run, questions the run's agents ask with `\(HandoffTool.askHuman.qualifiedName)` come to you, not the user, batched in one message from Ensemble. Answer what you can from the code, the conversation and the brief, and fix environment problems yourself where your tools allow (for example `\(HandoffTool.openWorktree.qualifiedName)` and allowed commands), replying to each agent with `\(HandoffTool.messageAgent.qualifiedName)`. Bring everything you can't resolve to the user as ONE merged `\(HandoffTool.askHuman.qualifiedName)` that names the agents each point affects, and once they answer, pass the answers back to each agent with `\(HandoffTool.messageAgent.qualifiedName)`.
        Workflows you can propose:
        \(list.isEmpty ? "(none; tell the user to add one in Settings › Workflows)" : list.joined(separator: "\n"))
        """
    }

    static func spawnedAgentGuide(spawner: String) -> String {
        """
        # Reporting back
        \(spawner) started you. When you end a turn, Ensemble sends \(spawner) your report: the summary you pass to `\(HandoffTool.submitResult.qualifiedName)`, or else your final reply. Questions you ask with `\(HandoffTool.askHuman.qualifiedName)` go to \(spawner), `\(HandoffTool.messageAgent.qualifiedName)` reaches only \(spawner), and \(spawner)'s messages arrive as your next message.
        """
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
        if waiting.contains(session.id) || isCoolingDown { return true }
        return !waiting.isEmpty || runningCount(inProject: projectId) >= maxConcurrentAgents(inProject: projectId)
    }

    public var isCoolingDown: Bool {
        apiCooldownUntil.map { $0 > .now } ?? false
    }

    func coolDown(for delay: Duration) -> Date {
        let until = Date.now.addingTimeInterval(delay / .seconds(1))
        if let current = apiCooldownUntil, current >= until { return current }
        apiCooldownUntil = until
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.apiCooldownUntil = nil
            self.cooldownTask = nil
            for projectId in self.turnQueue.keys {
                self.startQueuedTurns(inProject: projectId)
            }
        }
        return until
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
        guard !isCoolingDown else { return }
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
        let baseBranch = try await git.baseBranch(of: project.url)
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
                .create(agent: agentName, slug: taskSlug.isEmpty ? "task" : taskSlug, from: baseBranch)
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

    public func openWorktree(for session: AgentSession, in project: Project, git: GitClient) async throws {
        let agent = session.agent
        let baseBranch = try await git.baseBranch(of: project.url)
        let taskSlug = Slug.make((agent.task.nilIfEmpty ?? "lead").split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
        let worktree = try await WorktreeManager(repository: project.url, git: git)
            .create(agent: agent.name, slug: taskSlug.isEmpty ? "lead" : taskSlug, from: baseBranch)
        session.adoptWorktree(worktree, baseBranch: baseBranch, port: try nextPort(forProject: agent.projectId))
        usageDidChange()
        try await prepareWorktree(of: session)
    }

    public func createLeadAgent(in project: Project, role: RoleDefinition, taskId: Int64, now: Date = .now) throws -> AgentSession {
        guard providerMode != nil else { throw AgentError.providerNotChosen }
        guard let projectId = project.id else { throw AgentError.emptyTask }
        guard let name = try agentNames(for: role.name, count: 1, inProject: projectId).first else {
            throw WorktreeError.invalidName(role.name)
        }
        let agent = try database.insert(Agent(
            projectId: projectId, role: role.id, name: name, status: .idle, model: role.model,
            readOnly: true, taskId: taskId, createdAt: now, updatedAt: now
        ))
        guard let session = session(for: agent) else { throw AgentError.emptyTask }
        usageDidChange()
        return session
    }

    public func pauseAll(inProject projectId: Int64) throws -> Int {
        var paused = 0
        for session in try sessions(inProject: projectId) where session.isRunning || session.isQueued {
            session.pause()
            paused += 1
        }
        return paused
    }

    public func pinnedAgentToReuse(role: String, inProject projectId: Int64, excluding: Set<Int64>, activeRunIDs: Set<Int64>) throws -> AgentSession? {
        try database.agents(inProject: projectId)
            .filter { agent in
                guard let id = agent.id, agent.isPinned, agent.role == role, !agent.readOnly, agent.archivedAt == nil, agent.taskId == nil,
                      !excluding.contains(id), !(agent.runId.map(activeRunIDs.contains) ?? false) else { return false }
                return [.idle, .stopped, .interrupted].contains(agent.status)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .lazy.compactMap { self.session(for: $0) }
            .first { !$0.isRunning && !$0.isQueued }
    }

    public func reassign(
        _ session: AgentSession, toRun runId: Int64, runStepId: Int64?, planTaskId: String, task: String, in project: Project, git: GitClient
    ) async throws {
        let agent = session.agent
        let manager = WorktreeManager(repository: project.url, git: git)
        let base = try await git.baseBranch(of: project.url) ?? "HEAD"
        let slug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")).nilIfEmpty ?? "task"
        var branch = try manager.branchName(agent: agent.name, slug: slug)
        if try await git.hasCommit("refs/heads/\(branch)", in: project.url) { branch += "-run-\(runId)" }
        let worktree: URL
        if let existing = agent.worktreeURL, FileManager.default.fileExists(atPath: existing.path) {
            let status = try await git.run(["status", "--porcelain"], in: existing)
            guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowDriverError.notReady("\(agent.name) has uncommitted changes in its worktree, so it can’t take a new task.")
            }
            try await git.run(["switch", "-c", branch, base], in: existing)
            worktree = existing
        } else {
            let created = try await manager.create(agent: agent.name, slug: slug + (branch.hasSuffix("-run-\(runId)") ? "-run-\(runId)" : ""), from: base)
            worktree = created.path
            branch = created.branch ?? branch
        }
        session.reassign(runId: runId, runStepId: runStepId, planTaskId: planTaskId, task: task, worktree: worktree, branch: branch, baseBranch: base)
        usageDidChange()
        try await prepareWorktree(of: session)
    }

    public func runSessions(runId: Int64, projectId: Int64) throws -> [AgentSession] {
        try database.agents(inProject: projectId).filter { $0.runId == runId }.compactMap { session(for: $0) }
    }
}

