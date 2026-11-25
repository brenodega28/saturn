import Darwin
import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct AppRunnerTests {
    let folder: URL
    let log = ActivityLog()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "saturn-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        AppRunner.environment(from: ToolLocator().environment(merging: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "ANTHROPIC_API_KEY": "secret",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
        ]))
    }

    func makeRunner(grace: Duration = .seconds(5)) -> AppRunner {
        AppRunner(projectId: 42, log: log, environment: environment, killGracePeriod: grace)
    }

    static func freePort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, size)
                return getsockname(descriptor, generic, &size)
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func eventually(_ timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    var runMessages: [String] {
        log.entries.filter { $0.source == AppRunner.logSource }.map(\.message)
    }

    static func server(printing url: Bool) -> String {
        (url ? "echo \"  Local:   http://localhost:$PORT/\"\n" : "echo booting\n") + "sh -c 'exec nc -lk $PORT' &\nwait"
    }

    @Test func detectsThePortFromAPrintedURLAndStopKillsTheGroup() async throws {
        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.server(printing: true), label: "make dev", in: folder, branch: "main", port: port)
        let group = try #require(runner.processGroup)

        #expect(await eventually { runner.state.ports == [port] })
        #expect(await PortProbe.isListening(port: port))
        #expect(ListeningPorts.pids(inGroup: group).count >= 2)
        #expect(runner.isRunning(in: folder))
        #expect(!runner.isRunning(in: folder.appending(path: "other")))
        #expect(runMessages.first == "make dev · main")
        #expect(runMessages.contains("Local:   http://localhost:\(port)/"))
        #expect(runMessages.contains("ready · http://localhost:\(port) · main"))
        #expect(log.entries.filter { $0.source == AppRunner.logSource }.allSatisfy { $0.projectId == 42 })

        await runner.stop()

        #expect(runner.state == .stopped(exitCode: nil))
        #expect(runner.processGroup == nil)
        #expect(!runner.isRunning(in: folder))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(runMessages.last == "stopped")
    }

    @Test func detectsThePortFromListeningSocketsWhenNothingIsPrinted() async throws {
        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.server(printing: false), in: folder, branch: "crew/a/b", port: port)
        let group = try #require(runner.processGroup)

        #expect(await eventually { runner.state.ports == [port] })
        #expect(ListeningPorts.ports(inGroup: group).contains(port))
        if case .running(_, let since) = runner.state {
            #expect(since <= .now)
        } else {
            Issue.record("expected running, got \(runner.state)")
        }

        await runner.stop()
        #expect(!(await PortProbe.isListening(port: port)))
    }

    @Test func passesPortAndStripsAgentSecrets() async throws {
        let runner = makeRunner()
        await runner.start(command: "echo \"port=$PORT saturn=$SATURN_PORT key=${ANTHROPIC_API_KEY:-none} entry=${CLAUDE_CODE_ENTRYPOINT:-none} cwd=$(pwd -P)\"", in: folder, branch: "main", port: 5181)

        #expect(await eventually { runner.state == .stopped(exitCode: 0) })
        #expect(runMessages.contains("port=5181 saturn=5181 key=none entry=none cwd=\(realPath(of: folder))"))
        #expect(runMessages.last == "exited with code 0")
    }

    @Test func processExitingOnItsOwnReportsTheCode() async throws {
        let runner = makeRunner()
        await runner.start(command: "echo working\necho 'Error: something broke' >&2\necho 'just a warning' >&2\nexit 3", in: folder, branch: "main", port: nil)

        #expect(await eventually { runner.state == .stopped(exitCode: 3) })
        let entries = log.entries.filter { $0.source == AppRunner.logSource }
        #expect(entries.first { $0.message == "Error: something broke" }?.level == .error)
        #expect(entries.first { $0.message == "just a warning" }?.level == .info)
        #expect(entries.first { $0.message == "working" }?.level == .info)
        #expect(entries.last?.message == "exited with code 3")
        #expect(entries.last?.level == .error)
        #expect(runner.processGroup == nil)
    }

    @Test func startingAnotherBranchStopsTheFirst() async throws {
        let first = Self.freePort()
        let second = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.server(printing: true), in: folder, branch: "main", port: first)
        let firstGroup = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [first] })

        await runner.start(command: Self.server(printing: true), in: folder, branch: "crew/x/y", port: second)

        #expect(!ProcessGroup.isAlive(firstGroup))
        #expect(!(await PortProbe.isListening(port: first)))
        #expect(await eventually { runner.state.ports == [second] })
        #expect(runner.branch == "crew/x/y")
        #expect(runMessages.contains("stopped"))
        await runner.stop()
    }

    @Test func childrenIgnoringTermAreKilledAfterTheGracePeriod() async throws {
        let port = Self.freePort()
        let runner = makeRunner(grace: .seconds(1))
        let stubborn = #"perl -MIO::Socket::INET -e '$SIG{TERM} = "IGNORE"; my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ENV{PORT}, Listen => 5, ReuseAddr => 1) or die; sleep 600' &"# + "\nwait"
        await runner.start(command: stubborn, in: folder, branch: "main", port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        let started = ContinuousClock.now
        await runner.stop()

        #expect(ContinuousClock.now - started >= .seconds(1))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(runner.state == .stopped(exitCode: nil))
    }

    @Test func stopImmediatelyBlocksUntilTheGroupIsGone() async throws {
        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.server(printing: false), in: folder, branch: "main", port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        runner.stopImmediately()

        #expect(!ProcessGroup.isAlive(group))
        #expect(runner.state == .stopped(exitCode: nil))
        #expect(!(await PortProbe.isListening(port: port)))
    }

    @Test func idleCleanupStopsTheAppBeforeRemovingItsWorktree() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        var settings = ProjectSettings()
        settings.idleCleanupMinutes = 10
        try h.database.updateSettings(settings, forProject: projectId)
        let project = try #require(try h.database.project(id: projectId))
        let idle = try #require(try await h.runtime.spawn(in: project, kind: .builder, count: 1, git: h.repo.git, name: "Idle Dev").first)
        let worktree = try #require(idle.agent.worktreeURL)

        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.server(printing: false), in: worktree, branch: idle.agent.branch ?? "", port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        var worktreeExistedWhenStopped = false
        let scheduler = IdleCleanupScheduler(runtime: h.runtime) { h.repo.git }
        scheduler.willRemoveWorktree = { path in
            worktreeExistedWhenStopped = FileManager.default.fileExists(atPath: path.path)
            if runner.isRunning(in: path) { await runner.stop() }
        }
        let archived = await scheduler.sweep(now: .now.addingTimeInterval(11 * 60))

        #expect(archived == [idle.id])
        #expect(worktreeExistedWhenStopped)
        #expect(runner.state == .stopped(exitCode: nil))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func idleCleanupLeavesTheAppRunningInADirtyWorktree() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        let project = try #require(try h.database.project(id: projectId))
        let agent = try #require(try await h.runtime.spawn(in: project, kind: .builder, count: 1, git: h.repo.git).first)
        let worktree = try #require(agent.agent.worktreeURL)
        try "draft".write(to: worktree.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        var hookCalls = 0
        let scheduler = IdleCleanupScheduler(runtime: h.runtime) { h.repo.git }
        scheduler.willRemoveWorktree = { _ in hookCalls += 1 }

        #expect(await scheduler.sweep(now: .now.addingTimeInterval(60 * 60)).isEmpty)
        #expect(hookCalls == 0)
    }

    static func cacheWritingServer() -> String {
        "(while true; do mkdir -p .vite; date > .vite/stamp; sleep 0.05; done) &\n" + server(printing: false)
    }

    func hookStoppingRunner(_ runner: AppRunner, record: @escaping @MainActor (Bool) -> Void) -> @MainActor (URL) async -> Void {
        { path in
            guard runner.isRunning(in: path) else { return }
            record(FileManager.default.fileExists(atPath: path.path))
            await runner.stop()
        }
    }

    @Test func runCleanupStopsTheAppBeforeRemovingARunWorktree() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        let now = Date()
        let task = try h.database.insert(Chat(projectId: projectId, title: "Preview", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let run = try h.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: .running, startedAt: now, baseBranch: "main"), state: RunEngineState())
        let runId = try #require(run.id)
        let worktree = try await h.repo.manager.create(agent: "preview-run-\(runId)", slug: "preview").path

        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.cacheWritingServer(), in: worktree, branch: "preview", port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        var stoppedWhileWorktreeExisted: [Bool] = []
        let driver = AgentWorkflowDriver(runtime: h.runtime)
        driver.gitProvider = { h.repo.git }
        driver.willRemoveWorktree = hookStoppingRunner(runner) { stoppedWhileWorktreeExisted.append($0) }

        _ = try await driver.finish(run, end: WorkflowEnd(action: .leave, cleanUpWorktrees: true))

        #expect(stoppedWhileWorktreeExisted == [true])
        #expect(runner.state == .stopped(exitCode: nil))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(try await h.repo.manager.list().isEmpty)
    }

    @Test func mergingADeliveryStopsTheAppRunningInTheDeliveryWorktree() async throws {
        let setup = try await WorkflowDriverTests().makeMergeSetup()
        defer { setup.harness.cleanUp() }
        let worktree = try setup.harness.repo.manager.path(forAgent: "delivery-run-1")
        try await setup.harness.repo.manager.ensureExcluded()
        try await setup.git.run(["worktree", "add", worktree.path, WorkflowDriverTests.MergeSetup.branch], in: setup.root)

        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.cacheWritingServer(), in: worktree, branch: WorkflowDriverTests.MergeSetup.branch, port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        var stoppedWhileWorktreeExisted: [Bool] = []
        setup.driver.willRemoveWorktree = hookStoppingRunner(runner) { stoppedWhileWorktreeExisted.append($0) }

        _ = try await setup.driver.mergeDelivery(setup.run, method: .rebase)

        #expect(stoppedWhileWorktreeExisted == [true])
        #expect(runner.state == .stopped(exitCode: nil))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(try await setup.harness.repo.manager.list().isEmpty)
    }

    @Test func deletingAnAgentStopsTheAppBeforeRemovingItsWorktree() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        let project = try #require(try h.database.project(id: projectId))
        let agent = try #require(try await h.runtime.spawn(in: project, kind: .builder, count: 1, git: h.repo.git, name: "Doomed Dev").first)
        let worktree = try #require(agent.agent.worktreeURL)

        let port = Self.freePort()
        let runner = makeRunner()
        await runner.start(command: Self.cacheWritingServer(), in: worktree, branch: agent.agent.branch ?? "", port: port)
        let group = try #require(runner.processGroup)
        #expect(await eventually { runner.state.ports == [port] })

        var stoppedWhileWorktreeExisted: [Bool] = []
        h.runtime.willRemoveWorktree = hookStoppingRunner(runner) { stoppedWhileWorktreeExisted.append($0) }

        try await h.runtime.delete(agent, in: project, git: h.repo.git, deleteBranch: true)

        #expect(stoppedWhileWorktreeExisted == [true])
        #expect(runner.state == .stopped(exitCode: nil))
        #expect(!ProcessGroup.isAlive(group))
        #expect(!(await PortProbe.isListening(port: port)))
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func serverLinesAreCappedSoOtherLogRowsSurvive() async throws {
        let small = ActivityLog(capacity: 50)
        let runner = AppRunner(projectId: 42, log: small, environment: environment)
        small.sourceLimits[AppRunner.logSource] = 10
        small.append([LogEntry(date: .now, level: .info, source: "Dev 1", projectId: 42, message: "finished its turn")])

        await runner.start(command: "for i in $(seq 1 200); do echo line-$i; done", in: folder, branch: "main", port: nil)
        #expect(await eventually { runner.state == .stopped(exitCode: 0) })

        let runRows = small.entries.filter { $0.source == AppRunner.logSource }
        #expect(runRows.count == 10)
        #expect(runRows.last?.message == "exited with code 0")
        #expect(small.entries.contains { $0.source == "Dev 1" })
        let shared = ActivityLog()
        _ = AppRunner(projectId: 1, log: shared, environment: [:])
        #expect(shared.sourceLimits[AppRunner.logSource] == AppRunner.logLimit)
    }

    @Test func launchFailureIsReported() async throws {
        let runner = makeRunner()
        await runner.start(command: "true", in: folder.appending(path: "missing"), branch: "main", port: nil)

        if case .failed = runner.state {} else { Issue.record("expected failed, got \(runner.state)") }
        #expect(runner.processGroup == nil)
    }
}
