import Foundation

public struct HostOptions: Sendable {
    public var claudeExecutable: URL?
    public var processEnvironment: [String: String]?
    public var changeRetention: Int
    public var listens: Bool
    public var socketPath: URL?
    public var stopGracePeriod: Duration
    public var pollInterval: Duration?
    public var livePublishInterval: Duration
    public var runsBackgroundLoops: Bool
    public var providerMode: ProviderMode?

    public init(
        claudeExecutable: URL? = nil,
        processEnvironment: [String: String]? = nil,
        changeRetention: Int = ChangeLog.defaultRetention,
        listens: Bool = true,
        socketPath: URL? = nil,
        stopGracePeriod: Duration = .seconds(8),
        pollInterval: Duration? = nil,
        livePublishInterval: Duration = .milliseconds(200),
        runsBackgroundLoops: Bool = true,
        providerMode: ProviderMode? = nil
    ) {
        self.claudeExecutable = claudeExecutable
        self.processEnvironment = processEnvironment
        self.changeRetention = changeRetention
        self.listens = listens
        self.socketPath = socketPath
        self.stopGracePeriod = stopGracePeriod
        self.pollInterval = pollInterval
        self.livePublishInterval = livePublishInterval
        self.runsBackgroundLoops = runsBackgroundLoops
        self.providerMode = providerMode
    }
}

@MainActor
public final class EnsembleHost {
    public let paths: AppPaths
    public let identity: DaemonIdentity
    public let database: AppDatabase
    public let changeLog: ChangeLog
    public let runtime: AgentRuntime
    public let driver: AgentWorkflowDriver
    public let engine: RunEngine
    public let leadChat: LeadChat
    public let idleCleanup: IdleCleanupScheduler
    public let stallReporter: StallReporter
    public let options: HostOptions
    public private(set) var settings: DaemonSettings
    public private(set) var environment = DaemonEnvironment()
    public private(set) var live = LiveState()
    public private(set) var server: DaemonServer?
    public private(set) var launchProblems: [String] = []
    let secrets: any SecretStore
    let locator = ToolLocator()
    let router = CommandRouter()
    var remoteHostInfos: [String: RemoteHostInfo] = [:]
    var pluginSkillCache: [Int64: Set<String>] = [:]
    private var lock: InstanceLock?
    private var loops: [Task<Void, Never>] = []
    private var gitExecutable: URL?
    private var stopped = false
    public var onStop: (@MainActor () -> Void)?

    public var git: GitClient? {
        gitExecutable.map { GitClient(executable: $0, runner: runner) }
    }

    var runner: CommandRunner {
        CommandRunner(environment: runtime.processEnvironment)
    }

    public static func start(paths: AppPaths, secrets: any SecretStore) async throws -> EnsembleHost {
        try await start(paths: paths, secrets: secrets, options: HostOptions())
    }

    public static func start(paths: AppPaths, secrets: any SecretStore, options: HostOptions) async throws -> EnsembleHost {
        let lock = try InstanceLock.acquire(paths: paths)
        let identity = try DaemonFiles.loadIdentity(paths: paths)
        let database = try AppDatabase.open(at: paths.database)
        let host = EnsembleHost(paths: paths, identity: identity, database: database, secrets: secrets, options: options, lock: lock)
        do {
            try await host.launch()
        } catch {
            await host.stop()
            throw error
        }
        return host
    }

    private init(paths: AppPaths, identity: DaemonIdentity, database: AppDatabase, secrets: any SecretStore, options: HostOptions, lock: InstanceLock) {
        self.paths = paths
        self.identity = identity
        self.database = database
        self.secrets = secrets
        self.options = options
        self.lock = lock
        self.changeLog = ChangeLog(database: database, retention: options.changeRetention)
        var settings = DaemonFiles.loadSettings(paths: paths) ?? DaemonSettings()
        if let mode = options.providerMode { settings.providerMode = mode }
        self.settings = settings
        let environment = options.processEnvironment ?? ToolLocator().environment()
        self.runtime = AgentRuntime(
            database: database, paths: paths, secrets: secrets, providerMode: settings.providerMode,
            claudeExecutable: options.claudeExecutable, processEnvironment: environment, stopGracePeriod: options.stopGracePeriod
        )
        self.driver = AgentWorkflowDriver(runtime: runtime)
        if let pollInterval = options.pollInterval { driver.pollInterval = pollInterval }
        self.engine = RunEngine(database: database, driver: driver)
        self.leadChat = LeadChat(runtime: runtime, engine: engine, driver: driver)
        self.idleCleanup = IdleCleanupScheduler(runtime: runtime)
        self.stallReporter = StallReporter(database: database)
    }

    private func wire() {
        driver.gitProvider = { [weak self] in self?.git }
        runtime.gitProvider = { [weak self] in self?.git }
        idleCleanup.gitProvider = { [weak self] in self?.git }
        runtime.pluginSkills = { [weak self] project in
            project.id.flatMap { self?.pluginSkillCache[$0] } ?? []
        }
        runtime.worktreePrepared = { [weak runtime] preparation in
            try await runtime?.runSetupScript(preparation)
        }
        let removing: @MainActor (URL) async -> Void = { [weak self] worktree in
            self?.server?.broadcast(.event(.worktreeRemoving(path: worktree.path)))
        }
        driver.willRemoveWorktree = removing
        runtime.willRemoveWorktree = removing
        idleCleanup.willRemoveWorktree = removing
        runtime.observeTurnEnds { [weak self] session in
            guard session.agent.kind == .lead, session.agent.status == .idle, let taskId = session.agent.taskId,
                  !session.isRunning, !session.isQueued else { return }
            self?.server?.broadcast(.event(.leadTurnEnded(taskId: taskId)))
        }
        let updater = PinnedMemoryUpdater(runtime: runtime)
        driver.memoryUpdater = updater
        updater.observe(engine)
        registerCommands()
    }

    private func launch() async throws {
        wire()
        await checkEnvironment()
        do {
            try runtime.recoverAfterLaunch()
        } catch {
            launchProblems.append("Couldn’t recover agents: \(error.localizedDescription)")
        }
        try await driver.ensureServer()
        do {
            try engine.recover()
        } catch {
            launchProblems.append("Couldn’t recover runs: \(error.localizedDescription)")
        }
        for problem in launchProblems {
            FileHandle.standardError.write(Data("ensembled: \(problem)\n".utf8))
        }
        engine.startOrphanWatchdog()
        publishLive()
        if options.runsBackgroundLoops {
            startLoops()
        }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.options.livePublishInterval else { return }
                try? await Task.sleep(for: interval)
                self?.publishLive()
            }
        })
        if options.listens {
            server = try DaemonServer(host: self, socket: options.socketPath ?? paths.daemonSocket)
        }
    }

    private func startLoops() {
        idleCleanup.start()
        loops.append(Task { [weak self] in
            await self?.deleteAgentsOfClosedRequests()
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for project in (try? self.database.openProjects()) ?? [] {
                    _ = try? WeeklySummary.postIfDue(for: project, database: self.database)
                }
                _ = try? self.engine.postApprovalReminders()
                try? await Task.sleep(for: .seconds(3600))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.reportStalledWorkers()
            }
        })
        loops.append(Task { [weak self] in
            var lastRevision = -1
            while !Task.isCancelled {
                guard let self else { return }
                if self.runtime.usageRevision != lastRevision {
                    lastRevision = self.runtime.usageRevision
                    self.checkBudgets()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        })
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        server?.broadcast(.event(.shuttingDown))
        server?.stop()
        server = nil
        loops.forEach { $0.cancel() }
        loops = []
        idleCleanup.stop()
        engine.stopOrphanWatchdog()
        runtime.terminateAll()
        changeLog.waitUntilFlushed()
        lock?.release()
        lock = nil
        onStop?()
    }

    public var isStopped: Bool { stopped }

    func deleteAgentsOfClosedRequests() async {
        for project in (try? database.openProjects()) ?? [] {
            guard let git = git(for: project) else { continue }
            await leadChat.deleteAgentsOfClosedRequests(in: project, git: git)
        }
    }

    func git(for project: Project) -> GitClient? {
        guard let destination = project.host else { return git }
        return GitClient(ssh: SSHClient(destination: destination, runner: runner))
    }

    func reportStalledWorkers(now: Date = .now) {
        var stalled: [StalledWorker] = []
        for project in (try? database.openProjects()) ?? [] {
            guard let id = project.id else { continue }
            for session in (try? runtime.sessions(inProject: id)) ?? [] where session.agent.kind != .lead {
                guard let last = session.lastOutputAt, session.isRunning else { continue }
                let run = session.agent.runId.flatMap { engine.runs[$0] ?? (try? database.run(id: $0)) ?? nil }
                let step = run.flatMap { run in (try? engine.workflow(for: run))?.step(run.currentStep ?? "") }
                stalled.append(StalledWorker(agent: session.agent, lastOutputAt: last, stallMinutes: WorkerState.stallMinutes(for: step)))
            }
        }
        _ = try? stallReporter.report(stalled, now: now)
    }

    func checkBudgets() {
        _ = try? database.recordBudgetNotices(globalBudgetUSD: settings.globalMonthlyBudgetUSD, globalWeeklyBudgetUSD: settings.globalWeeklyBudgetUSD)
    }

    func updateSettings(_ change: (inout DaemonSettings) -> Void) throws {
        change(&settings)
        try DaemonFiles.saveSettings(settings, paths: paths)
        runtime.providerMode = settings.providerMode
    }

    @discardableResult
    public func checkEnvironment() async -> DaemonEnvironment {
        let baseEnvironment = options.processEnvironment ?? locator.environment()
        let checkLocator = options.processEnvironment.map { ToolLocator(environment: $0) } ?? locator
        let report = await EnvironmentChecker(
            locator: checkLocator, runner: CommandRunner(environment: baseEnvironment), secrets: secrets, mode: settings.providerMode
        ).check()
        gitExecutable = report.git.path
        if options.claudeExecutable == nil {
            runtime.claudeExecutable = report.claude.isOK ? report.claude.path : nil
        }
        runtime.processEnvironment = baseEnvironment
        var environment = DaemonEnvironment(
            gitPath: report.git.path?.path,
            claudePath: (options.claudeExecutable ?? report.claude.path)?.path,
            claudeProblem: Self.problem(report.claude, tool: "Claude Code"),
            gitProblem: Self.problem(report.git, tool: "git"),
            providerMode: settings.providerMode,
            providerReady: report.provider.isOK,
            providerProblem: Self.describe(report.provider)
        )
        if options.claudeExecutable != nil { environment.claudeProblem = nil }
        environment.fileVaultOn = await Self.fileVaultStatus()
        environment.report = report
        environment.dataDirectory = paths.root.path
        environment.processEnvironment = ["PATH": baseEnvironment["PATH"] ?? "", "HOME": baseEnvironment["HOME"] ?? NSHomeDirectory()]
        self.environment = environment
        publishLive()
        return environment
    }

    static func fileVaultStatus() async -> Bool? {
        let url = URL(fileURLWithPath: "/usr/bin/fdesetup")
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let result = try? await CommandRunner().run(url, ["status"]) else { return nil }
        return result.standardOutput.contains("FileVault is On")
    }

    static func problem(_ check: ToolCheck, tool: String) -> String? {
        switch check {
        case .found: nil
        case .missing: "\(tool) isn’t installed on this machine."
        case .broken(_, let message): "\(tool) is installed but didn’t run: \(message)"
        }
    }

    static func describe(_ status: ProviderStatus) -> String? {
        switch status {
        case .notChosen: "Choose how agents sign in to Claude."
        case .apiKey(let isStored): isStored ? nil : "No Anthropic API key is stored on this machine."
        case .claudeSignIn(let account, let isSignedIn): isSignedIn ? account.map { "Signed in as \($0)" } : "Claude Code isn’t signed in on this machine. Run claude once and log in."
        }
    }

    func publishLive() {
        var state = LiveState()
        state.startedAt = live.startedAt
        state.environment = environment
        state.usageRevision = runtime.usageRevision
        state.apiCooldownUntil = runtime.apiCooldownUntil
        state.waitingForCapacity = engine.waitingForCapacity
        state.drivingRunIDs = Set(engine.runs.keys.filter { engine.isDriving(runID: $0) })
        state.mcpReady = runtime.mcpServer != nil
        let updating = driver.memoryUpdater?.updatingAgentIDs ?? []
        for project in (try? database.openProjects()) ?? [] {
            guard let id = project.id else { continue }
            for session in (try? runtime.sessions(inProject: id)) ?? [] {
                var agent = LiveAgent()
                agent.isRunning = session.isRunning
                agent.isStopping = session.isStopping
                agent.isQueued = session.isQueued
                agent.canResume = session.canResume
                agent.isSettingUp = runtime.isSettingUp(session)
                agent.setupFailed = runtime.setupFailed(session)
                agent.isUpdatingMemory = updating.contains(session.id)
                agent.queuedMessages = session.queuedMessages
                agent.lastOutputAt = session.lastOutputAt
                agent.retryingAt = session.retryingAt
                agent.apiRetry = session.apiRetry.map(LiveRetry.init)
                guard agent != LiveAgent() else { continue }
                state.agents[session.id] = agent
            }
        }
        guard state != live else { return }
        live = state
        server?.broadcast(.live(state))
    }

    public func status() -> DaemonStatus {
        DaemonStatus(
            identity: identity, buildVersion: EnsembleProtocol.buildVersion, pid: getpid(), dataDirectory: paths.root.path,
            activeRuns: live.activeRunCount, runningAgents: live.agents.values.filter(\.isRunning).count,
            clients: server?.clientCount ?? 0, environment: environment, startedAt: live.startedAt
        )
    }
}
