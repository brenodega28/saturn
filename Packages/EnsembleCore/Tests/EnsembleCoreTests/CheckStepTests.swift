import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct CheckStepTests {
    let workflows = WorkflowDriverTests()

    func makeSetup(checks: ChecksConfig, checkStep: WorkflowStep = WorkflowStep(id: "checks", type: .check, next: "end")) async throws -> WorkflowDriverTests.Setup {
        let setup = try await workflows.makeSetup()
        let repo = setup.harness.repo.root
        try ProjectConfigLoader.write(checks, repository: repo)
        try ProjectConfigLoader.write(WorkflowDefinition(
            id: "checked", name: "Checked",
            steps: [
                WorkflowStep(id: "build", type: .agent, role: "claude-code", instructions: "Build it.", next: checkStep.id),
                checkStep,
            ],
            end: WorkflowEnd(action: .leave, cleanUpWorktrees: false)
        ), repository: repo)
        return setup
    }

    func start(_ setup: WorkflowDriverTests.Setup) throws -> Run {
        let now = Date()
        let task = try setup.harness.database.insert(ProjectTask(
            projectId: setup.project.id!, title: "Fix refunds", body: "Refunds can exceed the captured total.", source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        let config = ProjectConfigLoader.load(repository: setup.harness.repo.root)
        return try setup.engine.start(task: task, workflow: try #require(config.workflow("checked")), project: setup.project)
    }

    func waitForEnd(_ setup: WorkflowDriverTests.Setup, run: Run) async throws -> Run {
        try await waitUntil(timeout: .seconds(60)) {
            let status = (try? setup.harness.database.run(id: run.id!))??.status
            return status == .succeeded || status == .failed || setup.engine.holds[run.id!] != nil
        }
        return try #require(try setup.harness.database.run(id: run.id!))
    }

    func checkOutput(_ setup: WorkflowDriverTests.Setup, run: Run) throws -> StepOutput? {
        try setup.harness.database.runSteps(runId: run.id!).last { $0.stepId == "checks" && $0.status == .succeeded }?
            .output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }
    }

    @Test func failingChecksGoBackToTheBuilderUntilTheyPass() async throws {
        let setup = try await makeSetup(checks: ChecksConfig(
            checks: [CheckDefinition(name: "status", kind: .test, command: "test -f status.txt || { echo 'status.txt is missing'; exit 1; }")],
            protectedPaths: ["README.md"]
        ))
        defer { setup.harness.cleanUp() }
        try "".write(to: setup.harness.bin.appending(path: "touch-readme"), atomically: true, encoding: .utf8)

        let run = try start(setup)
        let finished = try await waitForEnd(setup, run: run)
        #expect(finished.status == .succeeded)

        let output = try #require(try checkOutput(setup, run: run))
        #expect(output.summary == "All checks passed after 2 rounds.")
        #expect(output.checks.first?.round == 2)
        #expect(output.checks.first?.passed == true)

        let correction = try String(contentsOf: setup.harness.bin.appending(path: "last-correction.txt"), encoding: .utf8)
        #expect(correction.contains("# Checks failed (round 1 of 2)"))
        #expect(correction.contains("status.txt is missing"))
        #expect(!correction.contains("previous session was closed"))

        let pins = try await setup.harness.database.writer.read { db in try Pin.fetchAll(db) }
        let testChange = try #require(pins.first { $0.tags == ["test-change"] })
        #expect(testChange.file == "README.md")
        #expect(testChange.title == "Test changed: README.md")
        #expect(testChange.startLine == 2)
    }

    @Test func checksThatStayRedHoldTheRunInTheInbox() async throws {
        let setup = try await makeSetup(checks: ChecksConfig(
            checks: [CheckDefinition(name: "unit", kind: .test, command: "echo 'FAILED test_refund_cap'; exit 1")]
        ))
        defer { setup.harness.cleanUp() }

        let run = try start(setup)
        _ = try await waitForEnd(setup, run: run)
        #expect(setup.engine.holds[run.id!]?.reason == .stepFailed)
        let item = try #require(try setup.harness.database.openInboxItems(projectId: setup.project.id!).last)
        #expect(item.title == "“checks” failed")
        #expect(item.body.hasPrefix("Checks still fail after 2 rounds."))
        #expect(item.body.contains("FAILED test_refund_cap"))
        let hold = try #require(setup.engine.holds[run.id!])
        let stored = try #require(try setup.harness.database.run(id: run.id!))
        #expect(hold.isChecksExhausted(in: stored.snapshotWorkflow))
        #expect(!RunHold(reason: .stepFailed, stepId: "build", message: "").isChecksExhausted(in: stored.snapshotWorkflow))
    }

    @Test func afterTwoFailedCorrectionsTheBuilderStartsAFreshSession() async throws {
        let setup = try await makeSetup(
            checks: ChecksConfig(checks: [CheckDefinition(name: "unit", kind: .test, command: "exit 1")]),
            checkStep: WorkflowStep(id: "checks", type: .check, maxRounds: 4, next: "end")
        )
        defer { setup.harness.cleanUp() }

        let run = try start(setup)
        _ = try await waitForEnd(setup, run: run)
        #expect(setup.engine.holds[run.id!]?.reason == .stepFailed)

        let correction = try String(contentsOf: setup.harness.bin.appending(path: "last-correction.txt"), encoding: .utf8)
        #expect(correction.contains("# Checks failed (round 3 of 4)"))
        #expect(correction.contains("previous session was closed"))
        #expect(correction.contains("## Your task"))
        #expect(correction.contains("Fix refunds"))
        let builderLaunches = setup.harness.launches().filter { $0.contains("You are Claude Code") }
        #expect(builderLaunches.count == 4)
        #expect(builderLaunches[1].contains("--resume"))
        #expect(builderLaunches[2].contains("--resume"))
        #expect(builderLaunches[3].contains("--session-id"))
    }

    @Test func testFirstNeedsAReproductionCommitThatFails() async throws {
        let setup = try await makeSetup(
            checks: ChecksConfig(checks: [CheckDefinition(name: "unit", kind: .test, command: "test -f fixed.txt")]),
            checkStep: WorkflowStep(id: "checks", type: .check, testFirst: true, next: "end")
        )
        defer { setup.harness.cleanUp() }

        let run = try start(setup)
        let finished = try await waitForEnd(setup, run: run)
        #expect(finished.status == .succeeded)
        let builder = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.runId == run.id && !$0.readOnly })
        let log = try await setup.harness.repo.git.run(["log", "--format=%s", "main..\(builder.branch!)"], in: setup.harness.repo.root)
        #expect(log.contains("Reproduce: refunds over the captured total"))
        let worktrees = try await setup.harness.repo.git.run(["worktree", "list"], in: setup.harness.repo.root)
        #expect(!worktrees.contains("reproduction"))
    }

    @Test func testFirstRejectsAReproductionThatAlreadyPasses() async throws {
        let setup = try await makeSetup(
            checks: ChecksConfig(checks: [CheckDefinition(name: "unit", kind: .test, command: "test -f fixed.txt")]),
            checkStep: WorkflowStep(id: "checks", type: .check, maxRounds: 1, testFirst: true, next: "end")
        )
        defer { setup.harness.cleanUp() }
        try "".write(to: setup.harness.bin.appending(path: "bad-repro"), atomically: true, encoding: .utf8)

        let run = try start(setup)
        _ = try await waitForEnd(setup, run: run)
        let item = try #require(try setup.harness.database.openInboxItems(projectId: setup.project.id!).last)
        #expect(item.body.contains("already passes unit, so its test doesn’t reproduce the problem"))
    }

    @Test func buildersAreToldAboutTheChecksAndTestFirst() async throws {
        let setup = try await makeSetup(
            checks: ChecksConfig(checks: [CheckDefinition(name: "unit", kind: .test, command: "true")], protectedPaths: ["tests/**"]),
            checkStep: WorkflowStep(id: "checks", type: .check, testFirst: true, next: "end")
        )
        defer { setup.harness.cleanUp() }

        let run = try start(setup)
        _ = try await waitForEnd(setup, run: run)
        let launch = try #require(setup.harness.launches().first { $0.contains("You are Claude Code") })
        #expect(launch.contains("Ensemble runs these checks on your worktree"))
        #expect(launch.contains("matching `tests/**` are protected"))
        #expect(launch.contains("\"hooks\""))
        let builder = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.runId == run.id && !$0.readOnly })
        let transcript = try String(contentsOf: setup.harness.runtime.paths.transcript(builder.id!), encoding: .utf8)
        #expect(transcript.contains("## Test first"))
    }
}

@MainActor
@Suite(.serialized) struct AgentHookTests {
    func makeAgent(checks: ChecksConfig) async throws -> (AgentHarness, AgentSession, AgentWorkflowDriver) {
        let harness = try await AgentHarness.make()
        harness.runtime.gitProvider = { harness.repo.git }
        try ProjectConfigLoader.write(checks, repository: harness.repo.root)
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        try await driver.ensureServer()
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        return (harness, session, driver)
    }

    func post(_ input: JSONValue, to url: URL) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(input.compactJSON.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func protectedFilesThatExistOnTheBaseBranchCantBeEdited() async throws {
        let (harness, session, _) = try await makeAgent(checks: ChecksConfig(protectedPaths: ["README.md", "tests/**"]))
        defer { harness.cleanUp() }
        let server = try #require(harness.runtime.mcpServer)
        let url = server.hookURL(for: server.register(agent: session.id, tools: []))
        let worktree = try #require(session.agent.worktreeURL)

        let denied = try await post(.object([
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string(worktree.appending(path: "README.md").path)]),
        ]), to: url)
        #expect(denied["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
        #expect(denied["hookSpecificOutput"]?["permissionDecisionReason"]?.string?.hasPrefix("README.md is a protected file") == true)

        let newTest = try await post(.object([
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("Write"),
            "tool_input": .object(["file_path": .string(worktree.appending(path: "tests/test_refund_cap.py").path)]),
        ]), to: url)
        #expect(newTest == .object([:]))

        let elsewhere = try await post(.object([
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string("/etc/hosts")]),
        ]), to: url)
        #expect(elsewhere == .object([:]))
    }

    @Test func failingEditChecksAreReportedBackAfterAnEdit() async throws {
        let (harness, session, _) = try await makeAgent(checks: ChecksConfig(checks: [
            CheckDefinition(name: "format", kind: .format, command: "echo 'README.md would be reformatted'; exit 1", onEdit: true),
        ]))
        defer { harness.cleanUp() }

        let reply = await harness.runtime.handleHook(.object(["hook_event_name": .string("PostToolUse"), "tool_name": .string("Edit")]), agentID: session.id)
        #expect(reply["decision"] == .string("block"))
        #expect(reply["reason"]?.string?.contains("README.md would be reformatted") == true)
    }

    @Test func theStopHookBlocksWhileChecksFailThenGivesUp() async throws {
        let (harness, session, _) = try await makeAgent(checks: ChecksConfig(checks: [
            CheckDefinition(name: "unit", kind: .test, command: "echo run >> \"$FAKE_DIR/stop-runs\"; grep -q world README.md && test -f done.txt"),
        ]))
        defer { harness.cleanUp() }
        let stop = { (active: Bool) in JSONValue.object(["hook_event_name": .string("Stop"), "stop_hook_active": .bool(active)]) }
        let worktree = try #require(session.agent.worktreeURL)
        let runs = { ((try? String(contentsOf: harness.bin.appending(path: "stop-runs"), encoding: .utf8)) ?? "").split(separator: "\n").count }
        try "hello\nworld\n".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)

        let first = await harness.runtime.handleHook(stop(false), agentID: session.id)
        #expect(first["decision"] == .string("block"))
        #expect(first["reason"]?.string?.hasPrefix("Don’t finish yet") == true)
        #expect(await harness.runtime.handleHook(stop(true), agentID: session.id)["decision"] == .string("block"))
        #expect(await harness.runtime.handleHook(stop(true), agentID: session.id) == .object([:]))

        #expect(runs() == 2)
        try "done\n".write(to: worktree.appending(path: "done.txt"), atomically: true, encoding: .utf8)
        #expect(await harness.runtime.handleHook(stop(false), agentID: session.id) == .object([:]))
        #expect(runs() == 3)
        #expect(await harness.runtime.handleHook(stop(false), agentID: session.id) == .object([:]))
        #expect(runs() == 3)
    }

    @Test func theStopHookSkipsAgentsThatChangedNothing() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        harness.runtime.gitProvider = { harness.repo.git }
        try ProjectConfigLoader.write(ChecksConfig(checks: [CheckDefinition(name: "unit", kind: .test, command: "exit 1")]), repository: harness.repo.root)
        let projectId = try #require(harness.project.id)
        let worktree = try await harness.repo.manager.create(agent: "idle", slug: "nothing")
        let agent = try harness.database.insert(Agent(
            projectId: projectId, role: "claude-code", name: "Idle", worktreePath: worktree.path.path, branch: worktree.branch,
            status: .idle, baseBranch: "main", createdAt: .now, updatedAt: .now
        ))
        let reply = await harness.runtime.handleHook(.object(["hook_event_name": .string("Stop")]), agentID: try #require(agent.id))
        #expect(reply == .object([:]))
    }
}

@MainActor
@Suite(.serialized) struct HarnessHealthTests {
    @Test func runsEveryCheckInAFreshWorktreeAndCleansUp() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try ProjectConfigLoader.write(ChecksConfig(checks: [
            CheckDefinition(name: "readme", kind: .test, command: "test -f README.md"),
            CheckDefinition(name: "deps", kind: .lint, command: "test -d node_modules || { echo 'node_modules missing'; exit 1; }"),
        ]), repository: harness.repo.root)

        let report = try await harness.runtime.checkHarness(of: harness.project, git: harness.repo.git)
        #expect(report.results.map(\.status) == [.passed, .failed])
        #expect(report.problems.count == 1)
        #expect(report.problems.first?.hasPrefix("deps failed (exit 1) on a clean checkout") == true)
        let worktrees = try await harness.repo.git.run(["worktree", "list"], in: harness.repo.root)
        #expect(!worktrees.contains(AgentRuntime.healthWorktreeName))
    }

    @Test func flagsAProjectWithoutChecksOrTests() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let empty = try await harness.runtime.checkHarness(of: harness.project, git: harness.repo.git)
        #expect(empty.problems.first?.hasPrefix("No checks are set up") == true)

        try ProjectConfigLoader.write(ChecksConfig(checks: [CheckDefinition(name: "lint", kind: .lint, command: "true")]), repository: harness.repo.root)
        let lintOnly = try await harness.runtime.checkHarness(of: harness.project, git: harness.repo.git)
        #expect(lintOnly.problems == ["No check of kind test, so agents’ work isn’t verified by tests."])
    }
}
