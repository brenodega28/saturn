import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct WeeklyBudgetTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test func aWeeklyBudgetBlocksNewWorkUntilAllowed() throws {
        let database = try AppDatabase.inMemory()
        var project = try database.openProject(at: FileManager.default.temporaryDirectory.appending(path: "weekly-\(UUID().uuidString)"))
        let id = try #require(project.id)
        var settings = ProjectSettings()
        settings.weeklyBudgetUSD = 10
        settings.monthlyBudgetUSD = 100
        try database.updateSettings(settings, forProject: id)
        project = try #require(try database.project(id: id))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 6, recordedAt: date("2026-10-19T09:00:00Z")))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 9, recordedAt: date("2026-10-27T09:00:00Z")))
        try database.record(UsageEntry(projectId: id, model: "sonnet", costUSD: 2, recordedAt: date("2026-10-28T09:00:00Z")))
        let now = date("2026-10-28T12:00:00Z")

        #expect(try database.weeklySpend(projectId: id, at: now, calendar: calendar) == 11)
        #expect(throws: BudgetError.projectWeeklyBudgetReached(project: project.name, budgetUSD: 10, spentUSD: 11)) {
            try database.checkProjectBudget(projectId: id, at: now, calendar: calendar)
        }
        let notices = try database.pendingWeeklyBudgetNotices(globalBudgetUSD: 50, at: now, calendar: calendar)
        #expect(notices.map(\.title) == ["80% of the weekly budget used", "Weekly budget reached"])
        #expect(notices.last?.body.contains("“Allow this week”") == true)

        try database.allowOverWeeklyBudget(projectId: id, at: now, calendar: calendar)
        try database.checkProjectBudget(projectId: id, at: now, calendar: calendar)
        #expect(try database.projectWeeklyBudgetStatus(projectId: id, at: date("2026-11-03T12:00:00Z"), calendar: calendar).allowedOverBudget == false)
    }
}

@MainActor
@Suite(.serialized) struct AgentControlTests {
    @Test func pauseAllPausesWorkingAndQueuedAgents() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        var settings = ProjectSettings()
        settings.maxConcurrentAgents = 1
        try harness.database.updateSettings(settings, forProject: try #require(harness.project.id))
        let first = try await harness.spawn("Dev 1")
        let second = try await harness.spawn("Dev 2")
        try await waitUntil { first.isRunning && second.isQueued }

        #expect(try harness.runtime.pauseAll(inProject: try #require(harness.project.id)) == 2)
        try await waitUntil { first.agent.status == .paused && second.agent.status == .paused }
        #expect(!second.isQueued)
    }

    @Test func approvalStepsCanRemindDaily() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        let workflow = WorkflowDefinition(id: "r", name: "R", steps: [
            WorkflowStep(id: "approve", type: .approval, remindDaily: true, routes: [StepOutcome.approved: WorkflowRoute(to: "end")]),
        ])
        let id = try await h.start(workflow)
        let opened = try #require(try h.database.inboxItems(runId: id).first).createdAt

        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(3600)).isEmpty)
        let first = try h.engine.postApprovalReminders(now: opened.addingTimeInterval(90_000))
        #expect(first.map(\.title) == ["Still waiting for you: Refunds v2"])
        #expect(first.first?.body.hasSuffix("has waited 1 day for your approval.") == true)
        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(100_000)).isEmpty)
        #expect(try h.engine.postApprovalReminders(now: opened.addingTimeInterval(180_000)).count == 1)
    }

    @Test func spawnStepsCanHandTasksToPinnedAgents() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let projectID = try #require(setup.project.id)
        let role = try #require(setup.config.role("claude-code"))
        let spawned = try await setup.harness.runtime.spawn(
            in: setup.project, role: role, count: 1, config: setup.config, git: setup.harness.repo.git, pinned: true, name: "Veteran"
        )
        let pinned = try #require(spawned.first)
        var feature = try #require(setup.config.workflow("feature-delivery"))
        let build = try #require(feature.steps.firstIndex { $0.id == "build" })
        feature.steps[build].reusePinned = true
        let task = try setup.harness.database.insert(ProjectTask(projectId: projectID, title: "Add alpha and beta", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now))
        let run = try setup.engine.start(task: task, workflow: feature, project: setup.project)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let veteran = try #require(try setup.harness.database.agent(id: pinned.id))
        #expect(veteran.runId == run.id)
        #expect(veteran.planTaskId != nil)
        #expect(veteran.isPinned)
        #expect(veteran.branch?.hasPrefix("crew/veteran/") == true)
        let builders = try setup.harness.database.agents(inProject: projectID).filter { $0.runId == run.id && $0.planTaskId != nil }
        #expect(builders.count == 2)
    }
}

@MainActor
@Suite struct WorkflowHistoryTests {
    @Test func savesKeepNotedVersionsThatCanBeRestored() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let first = WorkflowDefinition(id: "hotfix", name: "Hotfix", steps: [WorkflowStep(id: "fix", type: .agent, role: "claude-code")])
        let v1 = try ProjectConfigLoader.save(first, comparedTo: nil, note: "", repository: repository)
        var changed = v1
        changed.steps.append(WorkflowStep(id: "checks", type: .check))
        let v2 = try ProjectConfigLoader.save(changed, comparedTo: v1, note: "Run the checks", repository: repository)
        var moved = v2
        moved.steps[0].position = CanvasPosition(x: 40, y: 40)
        _ = try ProjectConfigLoader.save(moved, comparedTo: v2, note: "", repository: repository)

        let history = ProjectConfigLoader.history(of: "hotfix", repository: repository)
        #expect(history.map(\.version) == [2, 1])
        #expect(history.map(\.note) == ["Run the checks", "First version"])
        #expect(history.first?.workflow?.steps.map(\.id) == ["fix", "checks"])

        let restored = try ProjectConfigLoader.restore(history[1], of: v2, repository: repository)
        #expect(restored.version == 3)
        #expect(restored.steps.map(\.id) == ["fix"])
        #expect(ProjectConfigLoader.history(of: "hotfix", repository: repository).first?.note == "Restored v1")
        #expect(ProjectConfigLoader.load(repository: repository).workflow("hotfix")?.version == 3)

        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: repository)
        let projectId = try #require(project.id)
        let task = try database.insert(ProjectTask(projectId: projectId, title: "T", body: "", source: .chat, status: .done, createdAt: .now, updatedAt: .now))
        let taskId = try #require(task.id)
        for cost in [2.0, 4.0] {
            _ = try database.insert(Run(projectId: projectId, taskId: taskId, workflow: "hotfix", workflowVersion: "2", status: .succeeded, costUSD: cost, startedAt: .now, endedAt: .now), state: RunEngineState())
        }
        _ = try database.insert(Run(projectId: projectId, taskId: taskId, workflow: "hotfix", workflowVersion: "2", status: .running, startedAt: .now), state: RunEngineState())
        let stats = try database.versionStats(of: "hotfix", projectId: projectId, versions: ProjectConfigLoader.history(of: "hotfix", repository: repository))
        let two = try #require(stats.first { $0.version.version == 2 })
        #expect(two.runs == 3 && two.activeRuns == 1 && two.averageCostUSD == 3)
    }
}

@MainActor
@Suite(.serialized) struct ConflictResolutionTests {
    func makeConflict() async throws -> (AgentHarness, AgentWorkflowDriver, Run, AgentSession, AgentSession) {
        let harness = try await AgentHarness.make()
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        let projectId = try #require(harness.project.id)
        let task = try harness.database.insert(ProjectTask(projectId: projectId, title: "Greeting", body: "", source: .chat, status: .running, createdAt: .now, updatedAt: .now))
        let taskId = try #require(task.id)
        let run = try harness.database.insert(Run(projectId: projectId, taskId: taskId, workflow: "w", status: .waitingOnYou, startedAt: .now, title: "Greeting"), state: RunEngineState())
        let role = RoleDefinition(id: "claude-code", name: "Claude Code")
        var sessions: [AgentSession] = []
        for (index, text) in ["hello from A", "hello from B"].enumerated() {
            let session = try await harness.runtime.createRunAgent(in: harness.project, role: role, name: "Dev \(index + 1)", runId: try #require(run.id), runStepId: nil, planTaskId: "t\(index)", task: "Greeting", git: harness.repo.git)
            let worktree = try #require(session.agent.worktreeURL)
            try "\(text)\n".write(to: worktree.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try await harness.repo.git.run(["commit", "-qam", "Change greeting"], in: worktree)
            sessions.append(session)
        }
        return (harness, driver, run, sessions[0], sessions[1])
    }

    @Test func keepingOneSideResolvesTheConflict() async throws {
        let (harness, driver, run, first, second) = try await makeConflict()
        defer { harness.cleanUp() }
        let conflict = MergeConflict(branch: try #require(first.agent.branch), other: try #require(second.agent.branch), otherIsBase: false, paths: ["README.md"])

        try await driver.keep(conflict.branch, resolving: conflict, in: run)
        let loserWorktree = try #require(second.agent.worktreeURL)
        #expect(try String(contentsOf: loserWorktree.appending(path: "README.md"), encoding: .utf8) == "hello from A\n")
        let merge = try await harness.repo.git.runner.run(harness.repo.git.executable, ["merge-tree", "--write-tree", conflict.branch, conflict.other], in: harness.repo.root)
        #expect(merge.succeeded)
    }

    @Test func askingToCombineStagesTheMergeForTheAuthor() async throws {
        let (harness, driver, run, first, second) = try await makeConflict()
        defer { harness.cleanUp() }
        let conflict = MergeConflict(branch: try #require(first.agent.branch), other: try #require(second.agent.branch), otherIsBase: false, paths: ["README.md"])

        #expect(try await driver.askToCombine(conflict, in: run) == "Dev 1")
        let worktree = try #require(first.agent.worktreeURL)
        let unmerged = try await harness.repo.git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree)
        #expect(unmerged.contains("README.md"))
        try await waitUntil { harness.launches().count == 1 }
        #expect(first.transcript.entries.contains { if case .user(let text) = $0.content { text.contains("# Resolve a merge conflict") } else { false } })
    }
}

@Suite struct PermissionPolicyTests {
    func profile(_ levels: [PermissionCapability: PermissionLevel]) -> PermissionProfileDefinition {
        PermissionProfileDefinition(id: "p", name: "Custom", levels: levels)
    }

    @Test func levelsShapeTheCommandsAndTools() {
        let developer = PermissionPolicy(profile: PermissionsConfig().resolve(for: RoleDefinition(id: "dev", name: "Dev")), readOnly: false)
        #expect(developer.profile.id == "developer")
        #expect(developer.commands.contains("pytest"))
        #expect(!developer.commands.contains("npm install"))
        #expect(!developer.commands.contains("git push"))

        let pusher = PermissionPolicy(profile: profile([.editFiles: .allow, .runShell: .ask, .installPackages: .allow, .gitPush: .allow]), readOnly: false)
        #expect(pusher.commands.contains("git status") && !pusher.commands.contains("pytest"))
        #expect(pusher.commands.contains("npm install") && pusher.commands.contains("git push"))

        let quiet = PermissionPolicy(profile: profile([.editFiles: .ask, .runShell: .never, .network: .ask]), readOnly: false)
        let launch = ClaudeLaunch(
            executable: URL(filePath: "/bin/claude"), worktree: URL(filePath: "/tmp"), session: .new("s"), model: "sonnet",
            systemPrompt: "", environment: [:], permissions: quiet, askTools: AgentPermissions.webTools + AgentPermissions.fileWritingTools
        )
        let arguments = launch.arguments
        let tools = arguments[arguments.firstIndex(of: "--tools")! + 1].split(separator: ",").map(String.init)
        #expect(!tools.contains("Bash"))
        #expect(tools.contains("Edit") && tools.contains("WebFetch"))
        let allowed = Set(arguments[(arguments.lastIndex(of: "--allowedTools")! + 1)...])
        #expect(allowed.isDisjoint(with: ["Edit", "WebFetch"]) && !allowed.contains { $0.hasPrefix("Edit(") })

        let reviewer = PermissionPolicy(profile: PermissionsConfig().resolve(for: nil, readOnly: true), readOnly: true)
        #expect(reviewer.level(.editFiles) == .never && !reviewer.commands.contains("npm ci"))
    }

    @Test func requestsAreClassifiedByCapability() {
        let policy = PermissionPolicy(profile: profile([:]), readOnly: false)
        #expect(policy.capability(ofTool: "Bash", input: .object(["command": .string("npm install left-pad")]))?.0 == .installPackages)
        #expect(policy.capability(ofTool: "Bash", input: .object(["command": .string("git push origin HEAD")]))?.0 == .gitPush)
        #expect(policy.capability(ofTool: "Bash", input: .object(["command": .string("curl https://x.dev")]))?.0 == .network)
        #expect(policy.capability(ofTool: "Bash", input: .object(["command": .string("pytest -q")]))?.0 == .runShell)
        #expect(policy.capability(ofTool: "WebFetch", input: .object(["url": .string("https://docs.dev")]))?.1 == "https://docs.dev")
        #expect(policy.capability(ofTool: "Read", input: nil) == nil)
    }
}

@MainActor
@Suite(.serialized) struct PermissionRequestTests {
    @Test func askHoldsTheActionUntilTheUserAnswers() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        let install: JSONValue = .object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("npm install left-pad")])])

        let first = await harness.runtime.handleHook(install, agentID: session.id)
        #expect(first["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
        let item = try #require(try harness.database.openInboxItems(projectId: projectId).first { $0.kind == .permission })
        #expect(item.title == "Dev 1 asks to install packages: `npm install left-pad`")
        let again = await harness.runtime.handleHook(install, agentID: session.id)
        #expect(again["hookSpecificOutput"]?["permissionDecisionReason"]?.string?.hasPrefix("Still waiting") == true)
        #expect(try harness.database.openInboxItems(projectId: projectId).count { $0.kind == .permission } == 1)

        try harness.runtime.answerPermission(inboxItemId: try #require(item.id), allow: true)
        try await waitUntil { harness.launches().count == 2 }
        #expect(session.transcript.entries.contains { if case .user(let text) = $0.content { text.contains("The user allowed you to install packages") } else { false } })
        let allowed = await harness.runtime.handleHook(install, agentID: session.id)
        #expect(allowed["hookSpecificOutput"]?["permissionDecision"] == .string("allow"))
        #expect(try harness.database.openInboxItems(projectId: projectId).allSatisfy { $0.kind != .permission })
    }

    @Test func neverDeniesWithoutAsking() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        let push: JSONValue = .object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("git push origin HEAD")])])
        let reply = await harness.runtime.handleHook(push, agentID: session.id)
        #expect(reply["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
        #expect(reply["hookSpecificOutput"]?["permissionDecisionReason"]?.string?.hasPrefix("Developer agents may never push") == true)
        #expect(try harness.database.openInboxItems(projectId: try #require(harness.project.id)).isEmpty)
        let test: JSONValue = .object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("pytest -q")])])
        #expect(await harness.runtime.handleHook(test, agentID: session.id) == .object([:]))
    }
}
