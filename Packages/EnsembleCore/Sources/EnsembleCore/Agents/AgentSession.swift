import Foundation
import Observation

public struct AgentTurn: Sendable, Hashable {
    public var text: String
    public var images: [ChatAttachment]

    public init(_ text: String, images: [ChatAttachment] = []) {
        self.text = text
        self.images = images
    }

    static func joining(_ turns: [AgentTurn]) -> AgentTurn {
        AgentTurn(
            turns.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
            images: turns.flatMap(\.images)
        )
    }
}

@MainActor
@Observable
public final class AgentSession: Identifiable {
    public static let continuePrompt = "Continue where you left off."
    public static let handBackPrompt = """
        I made changes in your worktree while you were paused. Check `git status` and `git diff` before continuing, \
        then carry on with the task.
        """

    public nonisolated let id: Int64
    public private(set) var agent: Agent
    public private(set) var transcript: Transcript
    public private(set) var queuedTurns: [AgentTurn] = []
    public private(set) var waitingTurn: AgentTurn?
    public private(set) var apiRetry: APIRetry?
    @ObservationIgnored private var deferredTurn: AgentTurn?
    @ObservationIgnored private var currentTurn: AgentTurn?
    @ObservationIgnored private var apiErrorInProcess: ClaudeAPIError?
    @ObservationIgnored private var sessionStartedInProcess = false
    @ObservationIgnored private var apiFailures = 0
    @ObservationIgnored private var crashRestarts = 0
    @ObservationIgnored private var isRestoringWorktree = false

    @ObservationIgnored private unowned let runtime: AgentRuntime
    @ObservationIgnored private let log: TranscriptLog
    private var handle: AgentProcessHandle?
    private var stopTarget: AgentStatus?
    @ObservationIgnored private var restartAfterStop = false
    @ObservationIgnored private var pendingFailure: String?
    @ObservationIgnored private var launchedMode: ProviderMode?
    @ObservationIgnored private var turnCompletedInProcess = false
    @ObservationIgnored private var latestReply: String?

    init(agent: Agent, runtime: AgentRuntime) {
        self.id = agent.id ?? -1
        self.agent = agent
        self.runtime = runtime
        self.log = TranscriptLog(url: runtime.paths.transcript(agent.id ?? -1))
        self.transcript = Transcript(lines: log.readLines())
    }

    public var queuedMessages: [String] { queuedTurns.map(\.text) }

    public var isRunning: Bool { handle != nil }

    public var isStopping: Bool { stopTarget != nil }

    public var isQueued: Bool { waitingTurn != nil }

    public var retryingAt: Date? {
        isQueued && runtime.isCoolingDown ? runtime.apiCooldownUntil : nil
    }

    public var canResume: Bool {
        handle == nil && !isQueued && [.paused, .interrupted, .stopped, .failed].contains(agent.status)
    }

    public func setPinned(_ pinned: Bool) {
        guard agent.isPinned != pinned else { return }
        agent.isPinned = pinned
        persist()
    }

    public func togglePin() {
        setPinned(!agent.isPinned)
    }

    public func attach(toRun runId: Int64) {
        guard agent.runId != runId else { return }
        agent.runId = runId
        agent.runStepId = nil
        persist()
    }

    func reassign(runId: Int64, runStepId: Int64?, planTaskId: String, task: String, skills: [String], worktree: URL, branch: String, baseBranch: String?) {
        agent.runId = runId
        agent.runStepId = runStepId
        agent.planTaskId = planTaskId
        agent.task = task
        agent.skills = skills
        agent.worktreePath = worktree.path
        agent.branch = branch
        agent.baseBranch = baseBranch
        agent.status = .idle
        agent.sessionId = nil
        persist()
    }

    func adoptWorktree(_ worktree: Worktree, baseBranch: String?, port: Int?) {
        agent.worktreePath = worktree.path.path
        agent.branch = worktree.branch
        agent.baseBranch = baseBranch ?? worktree.head
        agent.port = port
        agent.readOnly = false
        persist()
    }

    func startNewSession() {
        guard handle == nil, !isQueued, agent.sessionId != nil else { return }
        agent.sessionId = nil
        persist()
    }

    public func send(_ message: String, images: [ChatAttachment] = []) {
        let turn = AgentTurn(message.trimmingCharacters(in: .whitespacesAndNewlines), images: images.filter(\.isImage))
        guard !turn.text.isEmpty || !turn.images.isEmpty else { return }
        if handle != nil || isQueued || isRestoringWorktree {
            queuedTurns.append(turn)
        } else {
            beginTurn(with: turn)
        }
    }

    public func pause() {
        requestStop(.paused)
    }

    public func stop() {
        queuedTurns.removeAll()
        requestStop(.stopped)
    }

    public func takeOver() {
        requestStop(.takenOver)
    }

    public func resume() {
        guard handle == nil, !isQueued, !isRestoringWorktree else { return }
        let turn = deferredTurn ?? AgentTurn(transcript.session == nil && !agent.task.isEmpty ? agent.task : Self.continuePrompt)
        record(notice: .resumed)
        beginTurn(with: turn)
    }

    public func handBack() {
        guard handle == nil, agent.status == .takenOver else { return }
        record(notice: .handedBack)
        beginTurn(with: AgentTurn(Self.handBackPrompt))
    }

    public func restart() {
        leaveQueue()
        if handle != nil {
            restartAfterStop = true
            queuedTurns.removeAll()
            requestStop(.stopped)
        } else {
            performRestart()
        }
    }

    func start() {
        guard !agent.task.isEmpty else { return }
        record(notice: .started)
        beginTurn(with: AgentTurn(agent.task))
    }

    func startQueuedTurn() {
        guard let turn = waitingTurn else { return }
        waitingTurn = nil
        #if DEBUG
        runtime.debugTrace?.lifecycle("dequeued", agent: agent)
        #endif
        launchTurn(with: turn)
    }

    @discardableResult
    func markInterrupted(detail: String) -> AgentProcessHandle? {
        leaveQueue()
        let interrupted = handle
        interrupted?.terminate()
        handle = nil
        stopTarget = nil
        agent.status = .interrupted
        agent.processID = nil
        record(notice: .interrupted, detail: detail)
        persist()
        return interrupted
    }

    func terminateForDeletion() {
        leaveQueue()
        stopTarget = .stopped
        handle?.terminate()
        handle = nil
    }

    func failSetup(_ message: String) {
        fail(message)
    }

    func clearSetupFailure() {
        guard handle == nil, agent.status == .failed else { return }
        agent.status = .idle
        agent.lastError = nil
        persist()
    }

    func archive(detail: String, at date: Date) {
        guard handle == nil else { return }
        leaveQueue()
        agent.status = .stopped
        agent.archivedAt = date
        record(notice: .stopped, detail: detail)
        persist()
    }

    @discardableResult
    private func leaveQueue() -> AgentTurn? {
        guard let turn = waitingTurn else { return nil }
        waitingTurn = nil
        runtime.dequeue(self)
        return turn
    }

    private func performRestart() {
        restartAfterStop = false
        agent.sessionId = nil
        deferredTurn = nil
        apiFailures = 0
        crashRestarts = 0
        record(notice: .restarted)
        guard !agent.task.isEmpty else {
            agent.status = .idle
            persist()
            return
        }
        beginTurn(with: AgentTurn(agent.task))
    }

    private func requestStop(_ target: AgentStatus) {
        if let turn = leaveQueue(), target != .stopped {
            deferredTurn = turn
        }
        guard let handle else {
            if agent.status != target {
                agent.status = target
                record(notice: notice(for: target))
                persist()
            }
            return
        }
        stopTarget = target
        if turnCompletedInProcess {
            handle.closeInput()
        } else {
            try? handle.send(line: ClaudeEvent.interruptLine(requestID: UUID().uuidString))
        }
        let grace = runtime.stopGracePeriod
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.handle === handle else { return }
            handle.terminate()
        }
    }

    private func beginTurn(with turn: AgentTurn) {
        deferredTurn = nil
        if runtime.shouldQueue(self) {
            waitingTurn = turn
            runtime.enqueue(self)
            agent.status = .waiting
            persist()
            #if DEBUG
            runtime.debugTrace?.lifecycle("queued", detail: "Concurrency limit \(runtime.maxConcurrentAgents(inProject: agent.projectId)) reached", agent: agent)
            #endif
            return
        }
        launchTurn(with: turn)
    }

    private func launchTurn(with turn: AgentTurn, mayRestoreWorktree: Bool = true) {
        if let project = runtime.remoteProject(of: agent) {
            prepareRemoteLaunch(of: turn, in: project, mayRestoreWorktree: mayRestoreWorktree)
            return
        }
        launchTurn(with: turn, mayRestoreWorktree: mayRestoreWorktree, remote: nil)
    }

    private func prepareRemoteLaunch(of turn: AgentTurn, in project: Project, mayRestoreWorktree: Bool) {
        latestReply = nil
        currentTurn = turn
        agent.status = .working
        agent.lastError = nil
        persist()
        Task { [weak self] in
            guard let self else { return }
            do {
                let host = try await self.runtime.remoteHostProvider(project)
                if !self.agent.readOnly, let worktree = self.agent.worktreeURL, try await !project.fileSystem.fileExists(worktree) {
                    if mayRestoreWorktree, self.runtime.canRestoreWorktree(of: self.agent) {
                        self.restoreWorktree(thenLaunch: turn)
                    } else {
                        self.fail(AgentLaunchError.missingWorktree(self.agent.name).localizedDescription)
                    }
                    return
                }
                if self.agent.isPinned, self.runtime.memoryUpdateAgents.contains(self.id) {
                    try await project.fileSystem.createDirectory(AgentMemory.directory(in: project.url))
                }
                guard self.agent.status == .working, self.handle == nil else { return }
                self.launchTurn(with: turn, mayRestoreWorktree: mayRestoreWorktree, remote: host)
            } catch {
                guard self.agent.status == .working else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func launchTurn(with turn: AgentTurn, mayRestoreWorktree: Bool, remote: RemoteAgentHost?) {
        latestReply = nil
        currentTurn = turn
        guard let executable = runtime.claudeExecutable ?? remote.map({ URL(fileURLWithPath: $0.claudePath) }) else {
            fail("Claude Code isn’t available. Check Settings › Tools.")
            return
        }
        let setup: TurnSetup
        do {
            setup = try runtime.turnSetup(for: agent, remote: remote)
        } catch {
            if case AgentLaunchError.missingWorktree = error, mayRestoreWorktree, runtime.canRestoreWorktree(of: agent) {
                restoreWorktree(thenLaunch: turn)
            } else {
                fail(error.localizedDescription)
            }
            return
        }

        let session: ClaudeLaunch.Session
        if let sessionID = agent.sessionId, transcript.session?.sessionID == sessionID {
            if !agent.hasSessionTotals {
                agent.seedSessionTotals(fromTranscript: log.readLines())
            }
            session = .resume(sessionID)
        } else {
            let sessionID = agent.sessionId ?? UUID().uuidString.lowercased()
            agent.sessionId = sessionID
            agent.startSessionTotals()
            session = .new(sessionID)
        }

        let environment: [String: String]
        do {
            environment = try runtime.launchEnvironment(for: agent)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let launch = ClaudeLaunch(
            executable: executable,
            worktree: setup.directory,
            session: session,
            model: agent.model,
            systemPrompt: setup.systemPrompt,
            environment: environment,
            readOnly: setup.readOnly,
            additionalDirectories: setup.additionalDirectories,
            extraArguments: setup.extraArguments,
            extraAllowedTools: setup.extraAllowedTools,
            hooks: setup.hooks,
            permissions: setup.permissions,
            askTools: setup.askTools,
            remote: remote.map {
                RemoteAgentLaunch(
                    host: $0, stateDirectory: $0.stateDirectory(forAgent: id),
                    mcpConfiguration: setup.mcpConfiguration, apiKey: environment["ANTHROPIC_API_KEY"]
                )
            }
        )

        do {
            let (handle, output) = try runtime.launcher.launch(launch)
            self.handle = handle
            launchedMode = runtime.providerMode
            pendingFailure = nil
            turnCompletedInProcess = false
            apiErrorInProcess = nil
            sessionStartedInProcess = false
            apiRetry = nil
            try handle.send(line: ClaudeEvent.userLine(turn.text, images: turn.images))
            record(line: ClaudeEvent.userLine(turn.text, images: turn.images, includingImageData: false))
            #if DEBUG
            runtime.debugTrace?.launched(launch, turn: turn, agent: agent)
            #endif
            agent.status = .working
            agent.processID = handle.processIdentifier
            agent.lastError = nil
            persist()
            Task { [weak self] in
                for await item in output {
                    self?.receive(item, from: handle)
                }
            }
        } catch {
            handle?.terminate()
            handle = nil
            fail(error.localizedDescription)
        }
    }

    private func receive(_ output: ProcessOutput, from source: AgentProcessHandle) {
        guard source === handle else { return }
        switch output {
        case .line(let line):
            #if DEBUG
            runtime.debugTrace?.received(line, agent: agent)
            #endif
            let events = ClaudeEvent.parse(line: line)
            guard !events.isEmpty else { return }
            if !events.allSatisfy(\.isPartial) {
                log.append(line)
            }
            for event in events {
                if case .sessionStarted(let info) = event {
                    sessionStartedInProcess = true
                    if let mode = launchedMode, case let keySource = info.apiKeySource ?? "unreported", keySource != mode.expectedKeySource {
                        pendingFailure = ProviderError.wrongCredentials(expected: mode, actualSource: keySource).localizedDescription
                        source.kill()
                    }
                }
                transcript.apply(event)
                switch event {
                case .assistantText(let text):
                    latestReply = text
                case .apiRetry(let retry):
                    apiRetry = retry
                case .apiError(let error):
                    apiErrorInProcess = error
                    latestReply = nil
                case .turnCompleted(let result):
                    apiRetry = nil
                    if result.isAPIError {
                        var error = apiErrorInProcess ?? ClaudeAPIError(kind: "unknown", message: result.text ?? "")
                        error.status = error.status ?? result.apiErrorStatus
                        apiErrorInProcess = error
                        latestReply = nil
                    }
                    account(result)
                    source.closeInput()
                    killIfLingering(source)
                    if let reply = latestReply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
                        latestReply = nil
                        runtime.turnReplied(agent, reply)
                    }
                default:
                    break
                }
            }
        case .exited(let code, let standardError):
            #if DEBUG
            runtime.debugTrace?.processExited(code: code, standardError: standardError, agent: agent)
            #endif
            processEnded(code: code, standardError: standardError)
        }
    }

    private func killIfLingering(_ source: AgentProcessHandle) {
        let grace = runtime.lingerGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.handle === source, self.stopTarget == nil, self.pendingFailure == nil, self.turnCompletedInProcess else { return }
            self.record(notice: .stopped, detail: "Claude Code was still running background tasks after its turn ended, so Ensemble ended them.")
            source.kill()
        }
    }

    private func account(_ result: TurnResult) {
        let cost = agent.addTurnCost(of: result, continuingProcess: turnCompletedInProcess)
        turnCompletedInProcess = true
        #if DEBUG
        runtime.debugTrace?.turnCompleted(result, costUSD: cost, agent: agent)
        #endif
        agent.inputTokens += result.usage.input
        agent.outputTokens += result.usage.output
        agent.cacheReadTokens += result.usage.cacheRead
        agent.cacheWriteTokens += result.usage.cacheWrite
        persist()
        do {
            try runtime.database.record(UsageEntry(
                projectId: agent.projectId,
                runId: agent.runId,
                agentId: agent.id,
                model: transcript.session?.model ?? agent.model,
                inputTokens: result.usage.input,
                outputTokens: result.usage.output,
                cacheReadTokens: result.usage.cacheRead,
                cacheWriteTokens: result.usage.cacheWrite,
                costUSD: cost,
                recordedAt: .now
            ))
        } catch {
            agent.lastError = "Couldn’t record usage: \(error.localizedDescription)"
        }
        runtime.usageDidChange()
    }

    private func processEnded(code: Int32, standardError: String) {
        handle = nil
        agent.processID = nil
        apiRetry = nil
        defer { runtime.startQueuedTurns(inProject: agent.projectId) }

        if let failure = pendingFailure {
            pendingFailure = nil
            stopTarget = nil
            restartAfterStop = false
            fail(failure)
            return
        }

        if let target = stopTarget {
            stopTarget = nil
            agent.status = target
            record(notice: notice(for: target))
            persist()
            if restartAfterStop { performRestart() }
            return
        }

        if let error = apiErrorInProcess {
            apiErrorInProcess = nil
            recover(from: error)
            return
        }

        if turnCompletedInProcess {
            apiFailures = 0
            crashRestarts = 0
            agent.status = .idle
            persist()
            if !queuedTurns.isEmpty {
                let next = AgentTurn.joining(queuedTurns)
                queuedTurns.removeAll()
                beginTurn(with: next)
            } else {
                runtime.turnEnded(self)
            }
            return
        }

        let output = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = output.isEmpty ? "Claude Code exited with code \(code) before finishing the turn." : output
        if sessionStartedInProcess, crashRestarts < runtime.crashRestartLimit {
            crashRestarts += 1
            record(notice: .retrying, detail: "Claude Code stopped unexpectedly, so Ensemble restarted the turn. \(message)")
            beginTurn(with: retryTurn())
            return
        }
        crashRestarts = 0
        fail(message)
    }

    private func recover(from error: ClaudeAPIError) {
        guard error.isTransient else {
            apiFailures = 0
            fail("\(error.summary). \(error.message)")
            return
        }
        let delays = runtime.apiRetryDelays
        apiFailures += 1
        guard apiFailures <= delays.count else {
            apiFailures = 0
            fail("\(error.summary), and \(delays.count) retries didn’t get through. \(error.message)")
            return
        }
        let until = runtime.coolDown(for: delays[apiFailures - 1])
        let time = until.formatted(date: .omitted, time: .standard)
        record(notice: .retrying, detail: "\(error.summary). Trying again at \(time) (retry \(apiFailures) of \(delays.count)).")
        agent.lastError = error.message
        beginTurn(with: retryTurn())
    }

    private func retryTurn() -> AgentTurn {
        sessionStartedInProcess ? AgentTurn(Self.continuePrompt) : (currentTurn ?? AgentTurn(Self.continuePrompt))
    }

    private func restoreWorktree(thenLaunch turn: AgentTurn) {
        agent.status = .working
        record(notice: .restoringWorktree, detail: "\(agent.worktreePath ?? "The worktree") was missing, so Ensemble is recreating it from \(agent.branch ?? "its branch").")
        persist()
        isRestoringWorktree = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRestoringWorktree = false }
            do {
                try await self.runtime.restoreWorktree(of: self)
                guard self.agent.status == .working, self.handle == nil else { return }
                self.launchTurn(with: turn, mayRestoreWorktree: false)
            } catch {
                guard self.agent.status != .failed else { return }
                self.fail("The worktree for \(self.agent.name) is missing and couldn’t be restored. \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        agent.status = .failed
        agent.lastError = message
        queuedTurns.removeAll()
        record(notice: .failed, detail: message)
        persist()
        runtime.turnEnded(self)
    }

    private func notice(for status: AgentStatus) -> EnsembleNotice {
        switch status {
        case .paused: .paused
        case .takenOver: .takenOver
        case .interrupted: .interrupted
        default: .stopped
        }
    }

    private func record(notice: EnsembleNotice, detail: String? = nil) {
        #if DEBUG
        runtime.debugTrace?.lifecycle(notice.rawValue, detail: detail, agent: agent)
        #endif
        record(line: ClaudeEvent.noticeLine(notice, detail: detail))
    }

    private func record(line: String) {
        log.append(line)
        for event in ClaudeEvent.parse(line: line) {
            transcript.apply(event)
        }
    }

    private func persist() {
        agent.updatedAt = .now
        do {
            try runtime.database.save(agent)
        } catch {
            agent.lastError = "Couldn’t save agent state: \(error.localizedDescription)"
        }
    }
}

struct TranscriptLog {
    let url: URL

    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    func readLines() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
