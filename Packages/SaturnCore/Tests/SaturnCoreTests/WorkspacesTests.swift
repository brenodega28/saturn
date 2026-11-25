import Darwin
import Foundation
import Testing
@testable import SaturnCore

@Suite struct SetupScriptRunnerTests {
    struct Sandbox {
        let worktree: URL
        let logs: URL

        static func make() throws -> Sandbox {
            let root = FileManager.default.temporaryDirectory.appending(path: "saturn-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
            let worktree = root.appending(path: "worktree", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            return Sandbox(worktree: worktree, logs: root.appending(path: "logs", directoryHint: .isDirectory))
        }

        var log: String {
            (try? String(contentsOf: SetupRecord.logFile(in: logs), encoding: .utf8)) ?? ""
        }

        func delete() {
            try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent())
        }
    }

    var environment: [String: String] {
        ToolLocator().environment(merging: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "CUSTOM_FLAG": "from-saturn"])
    }

    @Test func successCapturesOutputAndPassesVariables() async throws {
        let sandbox = try Sandbox.make()
        defer { sandbox.delete() }
        let runner = SetupScriptRunner(environment: environment)
        let record = try await runner.run(
            script: "echo \"agent=$SATURN_AGENT port=$SATURN_PORT flag=$CUSTOM_FLAG\"\necho \"cwd=$(pwd -P)\"\necho \"tree=$SATURN_WORKTREE\"\necho oops >&2",
            in: sandbox.worktree,
            variables: WorktreePreparation(projectId: 1, agentID: 7, agentName: "Django Dev 1", worktree: sandbox.worktree, port: 8013, logDirectory: sandbox.logs).variables,
            logDirectory: sandbox.logs
        )

        #expect(record.status == .succeeded)
        #expect(record.exitCode == 0)
        #expect(record.endedAt != nil)
        #expect(sandbox.log.contains("agent=Django Dev 1 port=8013 flag=from-saturn"))
        #expect(sandbox.log.contains("cwd=\(realPath(of: sandbox.worktree))"))
        #expect(sandbox.log.contains("tree=\(sandbox.worktree.path)"))
        #expect(sandbox.log.contains("oops"))
        let stored = try #require(SetupRecord.load(from: sandbox.logs))
        #expect(stored.status == .succeeded)
        #expect(stored.tail == record.tail)
    }

    @Test func failureThrowsWithTheLastLines() async throws {
        let sandbox = try Sandbox.make()
        defer { sandbox.delete() }
        let runner = SetupScriptRunner(environment: environment)
        let script = (1...20).map { "echo line-\($0)" }.joined(separator: "\n") + "\necho 'pip: no such package' >&2\nexit 3"

        await #expect(throws: SetupScriptError.self) {
            try await runner.run(script: script, in: sandbox.worktree, variables: [:], logDirectory: sandbox.logs)
        }
        do {
            try await runner.run(script: script, in: sandbox.worktree, variables: [:], logDirectory: sandbox.logs)
        } catch let SetupScriptError.failed(code, tail) {
            #expect(code == 3)
            let lines = tail.split(separator: "\n")
            #expect(lines.count == SetupScriptRunner.tailLineCount)
            #expect(lines.last == "pip: no such package")
            #expect(!tail.contains("line-5\n"))
        }
        let record = try #require(SetupRecord.load(from: sandbox.logs))
        #expect(record.status == .failed)
        #expect(record.exitCode == 3)
        #expect(record.tail.hasSuffix("pip: no such package"))
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        let sandbox = try Sandbox.make()
        defer { sandbox.delete() }
        let runner = SetupScriptRunner(environment: environment, timeout: .milliseconds(800), killGracePeriod: .milliseconds(300))
        let started = ContinuousClock.now
        var thrown: SetupScriptError?
        do {
            try await runner.run(script: "echo installing\nsleep 60 &\necho $! > child.pid\nwait", in: sandbox.worktree, variables: [:], logDirectory: sandbox.logs)
        } catch let error as SetupScriptError {
            thrown = error
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        guard case .timedOut(_, let tail) = thrown else {
            Issue.record("Expected a timeout, got \(String(describing: thrown))")
            return
        }
        #expect(tail.contains("installing"))
        #expect(SetupRecord.load(from: sandbox.logs)?.status == .timedOut)

        let pidText = try String(contentsOf: sandbox.worktree.appending(path: "child.pid"), encoding: .utf8)
        let child = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(child, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(child, 0) != 0)
    }

    @Test func tailSkipsBlankLines() throws {
        let sandbox = try Sandbox.make()
        defer { sandbox.delete() }
        try FileManager.default.createDirectory(at: sandbox.logs, withIntermediateDirectories: true)
        let log = SetupRecord.logFile(in: sandbox.logs)
        try "a\n\nb\n   \nc\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(SetupScriptRunner.tail(of: log, lines: 2) == "b\nc")
    }
}

@Suite struct PortAllocatorTests {
    @Test func picksTheLowestFreePortFromTheBase() {
        #expect(PortAllocator.port(base: 8000, taken: []) == 8000)
        #expect(PortAllocator.port(base: 8000, taken: [8000, 8002]) == 8001)
        #expect(PortAllocator.port(base: 0, taken: []) == nil)
        #expect(PortAllocator.port(base: 65535, taken: [65535]) == nil)
    }

    @Test func archivedAgentsReleaseTheirPorts() {
        let now = Date()
        let agents = [
            Agent(projectId: 1, role: "r", name: "a", status: .idle, port: 8000, createdAt: now, updatedAt: now),
            Agent(projectId: 1, role: "r", name: "b", status: .stopped, port: 8001, archivedAt: now, createdAt: now, updatedAt: now),
            Agent(projectId: 1, role: "r", name: "c", status: .idle, createdAt: now, updatedAt: now),
        ]
        #expect(PortAllocator.takenPorts(by: agents) == [8000])
    }
}

@MainActor
@Suite(.serialized) struct WorkspaceRuntimeTests {
    let builder = AgentKind.builder
    let reviewer = AgentKind.checker

    func configure(_ h: AgentHarness, _ change: (inout ProjectSettings) -> Void) throws -> Project {
        var settings = ProjectSettings()
        change(&settings)
        let id = try #require(h.project.id)
        try h.database.updateSettings(settings, forProject: id)
        return try #require(try h.database.project(id: id))
    }

    func spawn(_ h: AgentHarness, project: Project, role: AgentKind? = nil, count: Int = 1, pinned: Bool = false) async throws -> [AgentSession] {
        try await h.runtime.spawn(in: project, kind: role ?? builder, count: count, git: h.repo.git, pinned: pinned)
    }

    func makeRun(_ h: AgentHarness, status: RunStatus) throws -> Int64 {
        let projectId = try #require(h.project.id)
        let task = try h.database.insert(Chat(projectId: projectId, title: "Refunds", body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let run = try h.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: status, startedAt: .now, title: "Refunds"), state: RunEngineState())
        return try #require(run.id)
    }

    @Test func portsAreUniqueStableAndReachTheAgent() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let project = try configure(h) { $0.basePort = 8100 }

        let crew = try await spawn(h, project: project, count: 3)
        #expect(crew.map(\.agent.port) == [8100, 8101, 8102])
        let lone = try await spawn(h, project: project, role: reviewer)
        #expect(lone.first?.agent.port == nil)

        try await h.runtime.delete(crew[1], in: project, git: h.repo.git, deleteBranch: true)
        let refill = try await spawn(h, project: project)
        #expect(refill.first?.agent.port == 8101)
        let stored = try h.database.agents(inProject: try #require(project.id)).compactMap(\.port).sorted()
        #expect(stored == [8100, 8101, 8102])

        let first = try #require(try h.database.agent(id: crew[0].id))
        #expect(first.port == 8100)
        let environment = try h.runtime.launchEnvironment(for: first)
        #expect(environment["PORT"] == "8100")
        #expect(environment["SATURN_PORT"] == "8100")
        #expect(try h.runtime.turnSetup(for: first).systemPrompt.contains("Your dev server port is 8100"))
    }

    @Test func noBasePortMeansNoPort() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let crew = try await spawn(h, project: h.project)
        #expect(crew.first?.agent.port == nil)
        let environment = try h.runtime.launchEnvironment(for: try #require(crew.first?.agent))
        #expect(environment["PORT"] == nil)
    }

    @Test func setupScriptRunsInTheNewWorktreeBeforeTheFirstTurn() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let project = try configure(h) {
            $0.basePort = 9200
            $0.setupScript = "echo \"port $SATURN_PORT for $SATURN_AGENT\" > prepared.txt\necho installed"
        }
        h.runtime.worktreePrepared = { [runtime = h.runtime] in try await runtime.runSetupScript($0) }

        let session = try await h.runtime.spawn(in: project, kind: builder, count: 1, git: h.repo.git, task: "Add a world line to the README").first
        let agent = try #require(session)
        #expect(h.runtime.isSettingUp(agent))
        try await waitUntil { !h.runtime.isSettingUp(agent) && agent.agent.status == .idle && agent.transcript.session != nil }

        let worktree = try #require(agent.agent.worktreeURL)
        let prepared = try String(contentsOf: worktree.appending(path: "prepared.txt"), encoding: .utf8)
        #expect(prepared == "port 9200 for Builder\n")
        let log = try String(contentsOf: SetupRecord.logFile(in: h.data.appending(path: "agents/\(agent.id)")), encoding: .utf8)
        #expect(log.contains("installed"))
        #expect(h.runtime.setupRecord(for: agent.agent)?.status == .succeeded)
        #expect(h.launches().count == 1)
    }

    @Test func failedSetupMarksTheAgentFailedAndRetryRecovers() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let project = try configure(h) { $0.setupScript = "echo resolving\necho 'npm ERR! missing lockfile' >&2\nexit 2" }
        h.runtime.worktreePrepared = { [runtime = h.runtime] in try await runtime.runSetupScript($0) }

        let agent = try #require(try await spawn(h, project: project).first)
        try await waitUntil { !h.runtime.isSettingUp(agent) }
        #expect(agent.agent.status == .failed)
        #expect(agent.agent.lastError?.contains("npm ERR! missing lockfile") == true)
        #expect(h.runtime.setupFailed(agent))
        #expect(h.launches().isEmpty)

        _ = try configure(h) { $0.setupScript = "echo fixed" }
        h.runtime.retrySetup(agent)
        try await waitUntil { !h.runtime.isSettingUp(agent) }
        #expect(agent.agent.status == .idle)
        #expect(agent.agent.lastError == nil)
        #expect(!h.runtime.setupFailed(agent))
        #expect(h.runtime.setupRecord(for: agent.agent)?.status == .succeeded)
    }

    @Test func runAgentSetupFailureFailsTheStep() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let project = try configure(h) { $0.setupScript = "exit 9" }
        h.runtime.worktreePrepared = { [runtime = h.runtime] in try await runtime.runSetupScript($0) }
        let runId = try makeRun(h, status: .running)

        await #expect(throws: SetupScriptError.failed(exitCode: 9, tail: "")) {
            _ = try await h.runtime.createRunAgent(in: project, kind: builder, runId: runId, runStepId: nil, task: "Build it", git: h.repo.git)
        }
        let projectId = try #require(project.id)
        let agent = try #require(try h.database.agents(inProject: projectId).first)
        #expect(agent.status == .failed)
        #expect(h.runtime.settingUp.isEmpty)
    }

    @Test func integrationWorktreeSetupHandsItsPortAndLogToTheQAAgent() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let project = try configure(h) {
            $0.basePort = 7000
            $0.setupScript = "echo \"qa on $SATURN_PORT\""
        }
        h.runtime.worktreePrepared = { [runtime = h.runtime] in try await runtime.runSetupScript($0) }
        let runId = try makeRun(h, status: .running)
        _ = try await h.runtime.createRunAgent(in: project, kind: builder, runId: runId, runStepId: nil, task: "Build it", git: h.repo.git)

        let worktree = try await h.repo.manager.create(agent: "qa-run-\(runId)", slug: "combined")
        try await h.runtime.prepareIntegrationWorktree(at: worktree.path, name: "qa-run-\(runId)", projectId: try #require(project.id))
        let qa = try await h.runtime.createRunAgent(
            in: project, kind: reviewer, runId: runId, runStepId: nil, task: "Test", readOnlyWorktree: (worktree.path, worktree.branch), git: h.repo.git
        )
        #expect(qa.agent.port == 7001)
        let log = try String(contentsOf: SetupRecord.logFile(in: h.data.appending(path: "agents/\(qa.id)")), encoding: .utf8)
        #expect(log.contains("qa on 7001"))
        #expect(h.runtime.reservedPorts.isEmpty)

        try await h.runtime.prepareIntegrationWorktree(at: worktree.path, name: "qa-run-\(runId)", projectId: try #require(project.id))
        #expect(h.runtime.reservedPorts.isEmpty)
        #expect(h.runtime.setupRecord(for: qa.agent)?.status == .succeeded)
    }
}

@MainActor
@Suite(.serialized) struct IdleCleanupTests {
    let builder = AgentKind.builder

    @Test func policyOnlyPicksUnpinnedIdleAgentsPastTheirTime() {
        let now = Date()
        let old = now.addingTimeInterval(-11 * 60)
        func agent(_ status: AgentStatus = .idle, pinned: Bool = false, runId: Int64? = nil, updated: Date = old, archived: Date? = nil) -> Agent {
            Agent(id: 1, projectId: 1, runId: runId, role: "r", name: "a", status: status, isPinned: pinned, archivedAt: archived, createdAt: old, updatedAt: updated)
        }
        #expect(IdleCleanupPolicy.isDue(agent(), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(), minutes: 0, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(updated: now.addingTimeInterval(-9 * 60)), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(pinned: true), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(.working), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(.failed), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(runId: 4), minutes: 10, activeRunIDs: [4], busyAgentIDs: [], now: now))
        #expect(IdleCleanupPolicy.isDue(agent(runId: 4), minutes: 10, activeRunIDs: [5], busyAgentIDs: [], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(), minutes: 10, activeRunIDs: [], busyAgentIDs: [1], now: now))
        #expect(!IdleCleanupPolicy.isDue(agent(archived: old), minutes: 10, activeRunIDs: [], busyAgentIDs: [], now: now))
        #expect(IdleCleanupPolicy.summary(minutes: 10) == "Removed after 10 minutes unless pinned")
        #expect(IdleCleanupPolicy.summary(minutes: 0) == "Kept until you delete them")
    }

    @Test func sweepArchivesIdleAgentsAndKeepsTheirBranches() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        var settings = ProjectSettings()
        settings.idleCleanupMinutes = 10
        try h.database.updateSettings(settings, forProject: projectId)
        let project = try #require(try h.database.project(id: projectId))

        let idle = try #require(try await h.runtime.spawn(in: project, kind: builder, count: 1, git: h.repo.git, name: "Idle Dev").first)
        let pinned = try #require(try await h.runtime.spawn(in: project, kind: builder, count: 1, git: h.repo.git, pinned: true, name: "Pinned Dev").first)
        let task = try h.database.insert(Chat(projectId: projectId, title: "Refunds", body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let active = try h.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: .running, startedAt: .now), state: RunEngineState())
        let finished = try h.database.insert(Run(projectId: projectId, taskId: try #require(task.id), workflow: "small-task", status: .succeeded, startedAt: .now), state: RunEngineState())
        let inRun = try await h.runtime.createRunAgent(in: project, kind: builder, runId: try #require(active.id), runStepId: nil, task: "Build", git: h.repo.git)
        let afterRun = try await h.runtime.createRunAgent(in: project, kind: builder, runId: try #require(finished.id), runStepId: nil, task: "Build", git: h.repo.git)

        let scheduler = IdleCleanupScheduler(runtime: h.runtime) { h.repo.git }
        #expect(await scheduler.sweep(now: .now.addingTimeInterval(5 * 60)).isEmpty)
        let archived = await scheduler.sweep(now: .now.addingTimeInterval(11 * 60))
        #expect(Set(archived) == [idle.id, afterRun.id])

        let idleWorktree = try #require(idle.agent.worktreeURL)
        #expect(!FileManager.default.fileExists(atPath: idleWorktree.path))
        #expect(idle.agent.status == .stopped)
        #expect(idle.agent.archivedAt != nil)
        #expect(try h.database.agent(id: idle.id)?.archivedAt != nil)
        let branches = try await h.repo.branches()
        #expect(branches.contains(try #require(idle.agent.branch)))
        #expect(FileManager.default.fileExists(atPath: try #require(pinned.agent.worktreeURL).path))
        #expect(FileManager.default.fileExists(atPath: try #require(inRun.agent.worktreeURL).path))
        #expect(pinned.agent.archivedAt == nil)
        #expect(inRun.agent.archivedAt == nil)
        #expect(await scheduler.sweep(now: .now.addingTimeInterval(60 * 60)).isEmpty)
    }

    @Test func dirtyWorktreesAreLeftAlone() async throws {
        let h = try await AgentHarness.make()
        defer { h.cleanUp() }
        let projectId = try #require(h.project.id)
        let project = try #require(try h.database.project(id: projectId))
        let agent = try #require(try await h.runtime.spawn(in: project, kind: builder, count: 1, git: h.repo.git).first)
        let worktree = try #require(agent.agent.worktreeURL)
        try "draft".write(to: worktree.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let scheduler = IdleCleanupScheduler(runtime: h.runtime) { h.repo.git }
        #expect(await scheduler.sweep(now: .now.addingTimeInterval(60 * 60)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "notes.txt").path))
        #expect(agent.agent.archivedAt == nil)
    }
}

@Suite struct CrewTemplateTests {
    func makeFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "saturn-template-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func bundlesTheThreeTemplatesInOrder() throws {
        let templates = CrewTemplates.bundled
        #expect(templates.map(\.id) == ["django-react", "solo-with-review", "led-squad"])
        let django = try #require(CrewTemplates.template("django-react"))
        #expect(django.recommendedSkills == ["django-developer", "react-developer"])
        #expect(django.workflows == ["feature-delivery"])
        let solo = try #require(CrewTemplates.template("solo-with-review"))
        #expect(solo.recommendedSkills.isEmpty)
        #expect(solo.workflows == ["small-task"])
        let squad = try #require(CrewTemplates.template("led-squad"))
        #expect(squad.workflows == ["feature-delivery"])
    }

    @Test func installedTemplatesLoadWithoutIssues() throws {
        for template in CrewTemplates.bundled {
            let folder = makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try template.install(in: folder)
            let config = ProjectConfigLoader.load(repository: folder)
            #expect(config.issues.isEmpty, "\(template.id): \(config.issues.map(\.message))")
            #expect(config.workflows.map(\.id) == template.workflows)
        }
    }

    @Test func installKeepsExistingFiles() throws {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var custom = WorkflowDefinition(id: "small-task", name: "Our small task", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        custom.description = "Ours"
        try ProjectConfigLoader.write(custom, repository: folder)
        let skill = SkillLibrary.directory(in: folder).appending(path: "django-developer")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "ours".write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try #require(CrewTemplates.template("solo-with-review")).install(in: folder)
        try #require(CrewTemplates.template("django-react")).install(in: folder)
        #expect(ProjectConfigLoader.load(repository: folder).workflow("small-task")?.name == "Our small task")
        #expect(try String(contentsOf: skill.appending(path: "SKILL.md"), encoding: .utf8) == "ours")
        #expect(FileManager.default.fileExists(atPath: SkillLibrary.directory(in: folder).appending(path: "react-developer/SKILL.md").path))
    }

    @Test func createsARepositoryWithTheTemplateCommitted() async throws {
        let scratch = try await TestRepository.make()
        defer { scratch.delete() }
        let folder = makeFolder().appending(path: "shopfront", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        try await CrewTemplates.createRepository(at: folder, template: CrewTemplates.template("led-squad"), git: scratch.git)

        #expect(try await scratch.git.hasCommit("HEAD", in: folder))
        let files = try await scratch.git.run(["ls-files"], in: folder).split(separator: "\n").map(String.init)
        #expect(files.contains("README.md"))
        #expect(!files.contains { $0.hasPrefix(".saturn/roles/") })
        #expect(files.contains(".saturn/workflows/feature-delivery.yaml"))
        #expect(files.contains("AGENTS.md") && files.contains("CLAUDE.md"))
        #expect(AgentInstructions.status(repository: folder).isSetUp)
        let status = try await scratch.git.run(["status", "--porcelain"], in: folder)
        #expect(status.isEmpty)
    }
}

@Suite struct PortProbeTests {
    func bindLoopback(listening: Bool) throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
        }
        try #require(bound && (!listening || Darwin.listen(descriptor, 4) == 0))
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    @Test func detectsAListeningPort() async throws {
        let (descriptor, port) = try bindLoopback(listening: true)
        defer { close(descriptor) }
        #expect(await PortProbe.isListening(port: port))
    }

    @Test func aBoundPortWithoutAListenerIsNotRunning() throws {
        let (descriptor, port) = try bindLoopback(listening: false)
        defer { close(descriptor) }
        #expect(!PortProbe.connects(ipv4: port))
    }

    @Test func invalidPortsAreNeverListening() async {
        #expect(!(await PortProbe.isListening(port: 0)))
        #expect(!(await PortProbe.isListening(port: 70000)))
    }
}
