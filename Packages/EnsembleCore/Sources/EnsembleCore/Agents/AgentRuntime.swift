import Darwin
import Foundation
import Observation

public enum AgentError: Error, LocalizedError, Equatable {
    case nameTaken(String)
    case emptyTask
    case providerNotChosen

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "An agent named \(name) already exists in this project."
        case .emptyTask: "Describe a task for the agent."
        case .providerNotChosen: "Choose whether agents use an Anthropic API key or your Claude sign-in before starting one."
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

@MainActor
@Observable
public final class AgentRuntime {
    public let database: AppDatabase
    public let paths: AppPaths
    public var claudeExecutable: URL?
    public var processEnvironment: [String: String]
    public var providerMode: ProviderMode?
    public private(set) var usageRevision = 0

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let launcher: any AgentProcessLauncher
    @ObservationIgnored let stopGracePeriod: Duration
    @ObservationIgnored private var sessions: [Int64: AgentSession] = [:]

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
            createdAt: now,
            updatedAt: now
        ))
        guard let session = session(for: agent) else { throw AgentError.emptyTask }
        session.start()
        usageDidChange()
        return session
    }

    public func delete(_ session: AgentSession, in project: Project, git: GitClient, deleteBranch: Bool) async throws {
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
    }

    public func recoverAfterLaunch() throws {
        for agent in try database.agentsWithLiveProcesses() {
            if let pid = agent.processID {
                Self.terminateLeftoverClaude(pid: pid)
            }
            session(for: agent)?.markInterrupted(detail: "Ensemble wasn’t running when this turn ended.")
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
