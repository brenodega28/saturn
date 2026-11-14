import Foundation
import GRDB
import Observation

@MainActor
@Observable
public final class DaemonConnection: Identifiable {
    public let client: DaemonClient
    public let replica: ReplicaDatabase
    public private(set) var revision = 0
    @ObservationIgnored public var onError: (@MainActor (String, Error) -> Void)?
    @ObservationIgnored public var onEvent: (@MainActor (DaemonEvent) -> Void)?
    @ObservationIgnored private var sessions: [Int64: LiveAgentSession] = [:]
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var wasConnected = false

    public init(client: DaemonClient, replica: ReplicaDatabase) {
        self.client = client
        self.replica = replica
        client.onEvent = { [weak self] event in self?.onEvent?(event) }
        observation = DatabaseRegionObservation(tracking: .fullDatabase).start(
            in: replica.database.writer,
            onError: { _ in },
            onChange: { [weak self] _ in
                Task { @MainActor in self?.replicaChanged() }
            }
        )
        observeConnection()
    }

    public nonisolated var id: DaemonID { replica.daemonID }

    public var database: AppDatabase { replica.database }

    public var identity: DaemonIdentity? { client.identity }

    public var name: String { client.identity?.name ?? "Ensemble daemon" }

    public var live: LiveState { client.live }

    public var state: DaemonConnectionState { client.state }

    public var isConnected: Bool { client.state.isConnected }

    public var environment: DaemonEnvironment { live.environment }

    public func start() { client.start() }

    public func stop() {
        sessions.values.forEach { $0.stopStreaming() }
        client.stop()
    }

    private func observeConnection() {
        withObservationTracking {
            _ = client.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let connected = self.client.state.isConnected
                if connected, !self.wasConnected {
                    self.sessions.values.forEach { $0.connectionResumed() }
                    self.revision += 1
                }
                self.wasConnected = connected
                self.observeConnection()
            }
        }
    }

    private func replicaChanged() {
        revision += 1
        guard !sessions.isEmpty else { return }
        let ids = Array(sessions.keys)
        let agents = (try? database.writer.read { db in try Agent.filter(ids: ids).fetchAll(db) }) ?? []
        let byID = Dictionary(agents.compactMap { agent in agent.id.map { ($0, agent) } }, uniquingKeysWith: { first, _ in first })
        for (id, session) in sessions {
            if let agent = byID[id] {
                if session.agent != agent { session.agent = agent }
            } else {
                session.stopStreaming()
                sessions[id] = nil
            }
        }
    }

    public func send<C: DaemonCommand>(_ command: C) async throws -> C.Response {
        try await client.send(command)
    }

    public func perform<C: DaemonCommand>(_ failureTitle: String, _ command: C) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.send(command)
            } catch {
                self.onError?(failureTitle, error)
            }
        }
    }

    public func session(for agent: Agent) -> LiveAgentSession? {
        guard let id = agent.id else { return nil }
        if let session = sessions[id] { return session }
        let session = LiveAgentSession(agent: agent, connection: self)
        sessions[id] = session
        return session
    }

    public func session(agentID: Int64) -> LiveAgentSession? {
        if let session = sessions[agentID] { return session }
        guard let agent = try? database.agent(id: agentID) else { return nil }
        return session(for: agent)
    }

    public func sessions(inProject projectId: Int64) throws -> [LiveAgentSession] {
        _ = revision
        return try database.agents(inProject: projectId).compactMap { session(for: $0) }
    }

    public func runSessions(runId: Int64, projectId: Int64) throws -> [LiveAgentSession] {
        try sessions(inProject: projectId).filter { $0.agent.runId == runId }
    }

    public func runningCount(inProject projectId: Int64) -> Int {
        ((try? sessions(inProject: projectId)) ?? []).filter(\.isRunning).count
    }

    public func queuedSessions(inProject projectId: Int64) -> [LiveAgentSession] {
        ((try? sessions(inProject: projectId)) ?? []).filter(\.isQueued)
    }

    public func leadSession(for chat: Chat) -> LiveAgentSession? {
        guard let taskId = chat.id, let agent = try? database.leadAgent(taskId: taskId) else { return nil }
        return session(for: agent)
    }

    public func workingSessions(for chat: Chat) -> [LiveAgentSession] {
        _ = revision
        guard let taskId = chat.id,
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
            .compactMap { session(for: $0) }
            .filter { $0.isRunning || $0.isQueued }
    }

    public func run(id: Int64) -> Run? {
        _ = revision
        return (try? database.run(id: id)) ?? nil
    }

    public func activeRuns(projectID: Int64) -> [Run] {
        _ = revision
        return ((try? database.runs(projectId: projectID)) ?? [])
            .filter(\.isActive)
            .sorted { ($0.startedAt, $0.id ?? 0) < ($1.startedAt, $1.id ?? 0) }
    }

    public func hold(runID: Int64) -> RunHold? {
        _ = revision
        return (try? database.engineState(runId: runID))?.hold
    }

    public var holds: [Int64: RunHold] {
        _ = revision
        let states = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, engineState FROM run WHERE status IN ('waitingOnYou', 'running', 'paused', 'pending', 'interrupted')")
        }) ?? []
        var holds: [Int64: RunHold] = [:]
        for row in states {
            let id: Int64 = row["id"]
            let json: String = row["engineState"] ?? "{}"
            if let hold = try? JSONDecoder().decode(RunEngineState.self, from: Data(json.utf8)).hold {
                holds[id] = hold
            }
        }
        return holds
    }

    public func waitingReason(runID: Int64) -> RunHold? {
        hold(runID: runID)
    }

    public var waitingForCapacity: Set<Int64> { live.waitingForCapacity }

    public func isDriving(runID: Int64) -> Bool { live.drivingRunIDs.contains(runID) }

    public func workflow(for run: Run) throws -> WorkflowDefinition {
        guard let workflow = run.workflowDefinition else {
            throw RunEngineError.invalidState("The workflow saved with “\(run.title)” couldn’t be read.")
        }
        return workflow
    }

    public var usageRevision: Int {
        _ = revision
        return live.usageRevision
    }

    public func fileData(_ kind: FileKind, id: String) async throws -> Data {
        try await client.readFile(kind, id: id)
    }

    public func git(for project: Project) -> GitClient? {
        guard let projectID = project.id else { return nil }
        let connection = self
        return GitClient(
            executor: { arguments, directory in
                try await connection.send(CodeCommands.Exec(projectID: projectID, arguments: arguments, directory: directory)).commandResult
            },
            fileSystem: DaemonFileSystem(connection: self)
        )
    }

    public var fileSystem: DaemonFileSystem { DaemonFileSystem(connection: self) }
}

public struct ExecResult: Codable, Sendable, Hashable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    init(_ result: CommandResult) {
        exitCode = result.exitCode
        standardOutput = result.standardOutput
        standardError = result.standardError
    }

    public var commandResult: CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: standardOutput, standardError: standardError)
    }
}

public struct DaemonFileSystem: ProjectFileSystem {
    let connection: DaemonConnection

    public var isLocal: Bool { false }

    public func fileExists(_ url: URL) async throws -> Bool {
        try await connection.send(CodeCommands.FileExists(path: url.path))
    }

    public func createDirectory(_ url: URL) async throws {
        _ = try await connection.send(CodeCommands.CreateDirectory(path: url.path))
    }

    public func readText(_ url: URL) async throws -> String? {
        try await readData(url).map { String(decoding: $0, as: UTF8.self) }
    }

    public func readData(_ url: URL) async throws -> Data? {
        try await connection.send(CodeCommands.ReadFile(path: url.path))
    }

    public func writeData(_ data: Data, to url: URL) async throws {
        _ = try await connection.send(CodeCommands.WriteFile(path: url.path, data: data))
    }

    public func writeText(_ text: String, to url: URL) async throws {
        try await writeData(Data(text.utf8), to: url)
    }

    public func subdirectories(of url: URL) async throws -> [URL] {
        try await connection.send(CodeCommands.Subdirectories(path: url.path)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func removeItem(_ url: URL) async throws {
        _ = try await connection.send(CodeCommands.RemoveItem(path: url.path))
    }

    public func canonicalPath(_ url: URL) -> String {
        LocalFileSystem.trimmingTrailingSlashes(url.standardizedFileURL.path)
    }
}
