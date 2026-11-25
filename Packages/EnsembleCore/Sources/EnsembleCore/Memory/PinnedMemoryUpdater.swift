import Foundation
import Observation

@MainActor
@Observable
public final class PinnedMemoryUpdater {
    public private(set) var updatingAgentIDs: Set<Int64> = []
    public private(set) var lastError: String?

    @ObservationIgnored public let runtime: AgentRuntime
    @ObservationIgnored public var pollInterval: Duration = .milliseconds(250)
    @ObservationIgnored public var turnTimeout: Duration = .seconds(600)
    @ObservationIgnored public var maximumLines = AgentMemory.maximumLines
    @ObservationIgnored private var handledRuns: Set<Int64> = []
    @ObservationIgnored private var inFlight: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var observedRunIDs: Set<Int64> = []
    @ObservationIgnored private weak var engine: RunEngine?

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    public static let completedStatuses: Set<RunStatus> = [.succeeded, .failed]

    public func observe(_ engine: RunEngine) {
        self.engine = engine
        observedRunIDs = Set(engine.runs.keys)
        track()
    }

    public func updateMemories(after run: Run) async {
        guard let runID = run.id else { return }
        if let running = inFlight[runID] {
            await running.value
            return
        }
        guard !handledRuns.contains(runID) else { return }
        handledRuns.insert(runID)
        let work = Task<Void, Never> { [weak self] in await self?.performUpdates(runID: runID, projectID: run.projectId) }
        inFlight[runID] = work
        await work.value
        inFlight[runID] = nil
    }

    public func prompt(for agent: Agent, memory: AgentMemory) -> String {
        let intro = """
            The run you were part of has finished. Before you go idle, update your memory so the next run starts smarter. \
            Keep only durable lessons: project conventions, commands that work, pitfalls you hit, and the user’s preferences. \
            Leave out anything specific to this one task. Merge with what is already there, drop notes that turned out wrong, \
            and keep the file under \(maximumLines) lines, one note per “- ” bullet.
            """
        if agent.readOnly {
            return intro + """


                You can’t write files, so reply with the complete updated memory between <memory> and </memory> and nothing else; \
                Ensemble saves it to \(memory.url.path) for you.
                """
        }
        return intro + """


            Your memory file is \(memory.url.path). Rewrite it with the Write tool (or adjust it with Edit). \
            It is the only file outside your worktree you may change, and you must not change anything else in this turn.
            """
    }

    public nonisolated static func memoryReply(in text: String) -> String? {
        guard let open = text.range(of: "<memory>"), let close = text.range(of: "</memory>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func track() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.runs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.runsChanged()
                self?.track()
            }
        }
    }

    private func runsChanged() {
        guard let engine else { return }
        let active = Set(engine.runs.keys)
        let ended = observedRunIDs.subtracting(active)
        observedRunIDs = active
        for runID in ended {
            guard let run = try? runtime.database.run(id: runID), Self.completedStatuses.contains(run.status) else { continue }
            Task { [weak self] in await self?.updateMemories(after: run) }
        }
    }

    private func performUpdates(runID: Int64, projectID: Int64) async {
        do {
            guard let project = try runtime.database.project(id: projectID) else { return }
            let pinned = try runtime.runSessions(runId: runID, projectId: projectID).filter { $0.agent.isPinned }
            guard !pinned.isEmpty else { return }
            var started: [(AgentSession, AgentMemory)] = []
            for session in pinned where await canLaunch(session.agent, project: project) {
                let memory = AgentMemory(repository: project.url, agentName: session.agent.name)
                try memory.prepareDirectory()
                runtime.memoryUpdateAgents.insert(session.id)
                updatingAgentIDs.insert(session.id)
                session.send(prompt(for: session.agent, memory: memory))
                started.append((session, memory))
            }
            for (session, memory) in started {
                await waitForTurnEnd(session)
                runtime.memoryUpdateAgents.remove(session.id)
                updatingAgentIDs.remove(session.id)
                if session.agent.readOnly, let reply = Self.memoryReply(in: lastAssistantText(session)) {
                    try AgentMemory(repository: project.filesRoot, agentName: session.agent.name).write(reply)
                }
                if session.agent.status == .failed {
                    lastError = "\(session.agent.name) couldn’t update its memory: \(session.agent.lastError ?? "unknown error")"
                }
            }
        } catch {
            lastError = "Couldn’t update pinned memory: \(error.localizedDescription)"
        }
    }

    private func canLaunch(_ agent: Agent, project: Project) async -> Bool {
        let directory = agent.worktreeURL ?? (agent.readOnly ? project.url : nil)
        guard let directory else { return false }
        return (try? await project.fileSystem.fileExists(directory)) == true
    }

    private func waitForTurnEnd(_ session: AgentSession) async {
        let deadline = ContinuousClock.now + turnTimeout
        try? await Task.sleep(for: pollInterval)
        while session.isRunning || session.isQueued || session.agent.status == .working || session.agent.status == .waiting {
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func lastAssistantText(_ session: AgentSession) -> String {
        for entry in session.transcript.entries.reversed() {
            if case .assistant(let text) = entry.content { return text }
        }
        return ""
    }
}
