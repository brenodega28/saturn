import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct PermissionRoutingTests {
    @MainActor struct LeadRun {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let run: Run
        let lead: AgentSession
        let builders: [AgentSession]

        var database: AppDatabase { harness.database }
        var projectId: Int64 { harness.project.id! }
        var runId: Int64 { run.id! }

        func hook(_ command: String, from session: AgentSession) async -> JSONValue {
            await harness.runtime.handleHook(PermissionRoutingTests.bash(command), agentID: session.id)
        }

        func cards() throws -> [LeadMessage] {
            try database.leadMessages(taskId: run.taskId).filter { $0.kind == .permission }
        }

        func permissionItems() throws -> [ChatRequest] {
            try database.openChatRequests(projectId: projectId).filter { $0.kind == .permission }
        }

        func requests() throws -> [PermissionRequest] {
            try database.writer.read { db in try PermissionRequest.order(Column("id")).fetchAll(db) }
        }

        func answerLatestCard(_ decision: PermissionDecision) throws {
            let card = try #require(try cards().last)
            try harness.runtime.answerPermission(requestId: try #require(card.permissionRequestId), decision: decision)
        }
    }

    static func bash(_ command: String) -> JSONValue {
        .object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string(command)])])
    }

    static func decision(_ reply: JSONValue) -> String? {
        reply["hookSpecificOutput"]?["permissionDecision"]?.string
    }

    static func reason(_ reply: JSONValue) -> String? {
        reply["hookSpecificOutput"]?["permissionDecisionReason"]?.string
    }

    static func userTexts(_ session: AgentSession) -> [String] {
        session.transcript.entries.compactMap { if case .user(let text) = $0.content { text } else { nil } }
    }

    static func occurrences(of phrase: String, in session: AgentSession) -> Int {
        userTexts(session).reduce(0) { $0 + $1.components(separatedBy: phrase).count - 1 }
    }

    func makeRun(in existing: AgentHarness? = nil, workflow workflowName: String = "feature-delivery", builderNames: [String] = ["Dev 1", "Dev 2"]) async throws -> LeadRun {
        let harness: AgentHarness
        if let existing {
            harness = existing
        } else {
            harness = try await AgentHarness.make()
            try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
            try LegacyWorkflows.install(repository: harness.repo.root)
        }
        let workflow = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow(workflowName))
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        let projectId = try #require(harness.project.id)
        let now = Date()
        let task = try harness.database.insert(Chat(
            projectId: projectId, title: "Check the JDK", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now
        ))
        let taskId = try #require(task.id)
        let run = try harness.database.insert(Run(
            projectId: projectId, taskId: taskId, workflow: "feature-delivery", status: .running, startedAt: now,
            title: task.title, workflowSnapshot: try ProjectConfigLoader.encodeYAML(workflow)
        ), state: RunEngineState())
        let runId = try #require(run.id)
        let lead = try harness.runtime.createLeadAgent(in: harness.project, taskId: taskId)
        lead.attach(toRun: runId)
        var builders: [AgentSession] = []
        for (index, name) in builderNames.enumerated() {
            builders.append(try await harness.runtime.createRunAgent(
                in: harness.project, kind: .builder, name: name, runId: runId, runStepId: nil, planTaskId: "t\(runId)-\(index)",
                task: "Check the JDK", git: harness.repo.git
            ))
        }
        return LeadRun(harness: harness, driver: driver, run: run, lead: lead, builders: builders)
    }

    func addRun(to setup: LeadRun, builderName: String) async throws -> AgentSession {
        let now = Date()
        let run = try setup.database.insert(Run(
            projectId: setup.projectId, taskId: setup.run.taskId, workflow: "feature-delivery", status: .running, startedAt: now,
            title: "Second pass", workflowSnapshot: setup.run.workflowSnapshot
        ), state: RunEngineState())
        return try await setup.harness.runtime.createRunAgent(
            in: setup.harness.project, kind: .builder, name: builderName, runId: try #require(run.id), runStepId: nil, planTaskId: "t-second",
            task: "Clean up", git: setup.harness.repo.git
        )
    }

    @Test func aRiskyCommandInALeadChatRunBecomesAPendingCard() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        let reply = await setup.hook("rm -rf build", from: setup.builders[0])

        #expect(Self.decision(reply) == "deny")
        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        let request = try #require(try setup.requests().first)
        #expect(request.status == .pending && request.capability == .riskyCommands && request.request == "rm -rf build")
        #expect(request.rules == ["rm"] && request.taskId == setup.run.taskId)
        #expect(request.runId == setup.runId && request.requestId == nil)
        let card = try #require(try setup.cards().first)
        #expect(try setup.cards().count == 1)
        #expect(card.permissionRequestId == request.id && card.permissionStatus == .pending)
        #expect(card.title == "Dev 1" && card.text == "rm -rf build" && card.capability == .riskyCommands)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func everydayCommandsRunWithoutAskingAnyone() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        for command in ["java -version", "swift test", "ls && java -version | head > out.txt", "kotlinc -version 2>&1", #"git commit -m "Fix A; B""#] {
            let reply = await setup.hook(command, from: setup.builders[0])
            #expect(Self.decision(reply) == "allow", "\(command)")
        }
        #expect(try setup.requests().isEmpty)
        #expect(try setup.cards().isEmpty)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func pendingCardsAreCountedUntilAnswered() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let feed = PendingPermissionFeed(database: setup.database)
        feed.start()
        defer { feed.stop() }

        _ = await setup.hook("rm -rf build", from: setup.builders[0])
        _ = await setup.hook("git reset --hard", from: setup.builders[1])

        #expect(try setup.cards().count == 2)
        #expect(try setup.database.pendingPermissionCounts(projectId: setup.projectId) == [setup.run.taskId: 2])
        try await waitUntil { feed.count(taskId: setup.run.taskId) == 2 }
        #expect(feed.count(projectId: setup.projectId) == 2)
        try setup.answerLatestCard(.deny)
        #expect(try setup.database.pendingPermissionCounts(projectId: setup.projectId) == [setup.run.taskId: 1])
        let first = try #require(try setup.cards().first?.permissionRequestId)
        try setup.harness.runtime.answerPermission(requestId: first, decision: .allow)
        #expect(try setup.database.pendingPermissionCounts(projectId: setup.projectId).isEmpty)
        try await waitUntil { feed.count(projectId: setup.projectId) == 0 }
    }

    @Test func theLeadIsToldOnceAndToldNotToAnswer() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        _ = await setup.hook("rm -rf build", from: setup.builders[0])
        let again = await setup.hook("rm -rf build", from: setup.builders[0])

        #expect(Self.reason(again) == AgentRuntime.waitingReason)
        try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains("asked to run") } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.occurrences(of: "asked to run", in: setup.lead) == 1)
        #expect(Self.userTexts(setup.lead).contains { $0.contains("Dev 1 asked to run `rm -rf build`. The user sees an Allow/Deny card in this chat; don’t answer it yourself.") })
        #expect(try setup.cards().count == 1)
    }

    @Test func aSimilarRequestWhileACardIsOpenWaitsOnThatCard() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        _ = await setup.hook("rm -rf build", from: setup.builders[0])

        let second = await setup.hook("rm notes.txt", from: setup.builders[1])
        let third = await setup.hook("ls && rm -f out.txt", from: setup.builders[1])

        #expect(Self.reason(second) == AgentRuntime.waitingReason)
        #expect(Self.reason(third) == AgentRuntime.waitingReason)
        #expect(try setup.cards().count == 1)
        #expect(try setup.requests().count == 2)

        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.userTexts(setup.builders[1]).contains { $0.hasPrefix("The user allowed you to run `rm notes.txt`") } }
        #expect(try setup.requests().allSatisfy { $0.status == .allowed })
        #expect(Self.decision(await setup.hook("rm notes.txt", from: setup.builders[1])) == "allow")
        try await waitUntil { Self.occurrences(of: "The user answered", in: setup.lead) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.occurrences(of: "asked to run", in: setup.lead) == 1)
        #expect(Self.occurrences(of: "The user answered", in: setup.lead) == 1)
    }

    @Test func allowCoversSimilarCommandsForEveryAgentInTheChatOnly() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        _ = await setup.hook("rm -rf build", from: setup.builders[0])

        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.userTexts(setup.builders[0]).contains("The user allowed you to run `rm -rf build`. Go ahead; anything similar (`rm`) won’t need asking again in this chat.") }
        #expect(try setup.cards().first?.permissionStatus == .allowed)
        #expect(Self.decision(await setup.hook("rm -rf build", from: setup.builders[0])) == "allow")
        #expect(Self.reason(await setup.hook("rm -rf dist coverage", from: setup.builders[1])) == AgentRuntime.alreadyAllowedReason)
        #expect(Self.decision(await setup.hook("rm notes.txt", from: setup.lead)) == "allow")
        #expect(try setup.cards().count == 1)

        let different = await setup.hook("git reset --hard", from: setup.builders[0])
        #expect(Self.reason(different) == AgentRuntime.leadChatReason)
        #expect(try setup.cards().count == 2)

        let other = try await makeRun(in: setup.harness, builderNames: ["Dev 3"])
        let elsewhere = await other.hook("rm -rf build", from: other.builders[0])
        #expect(Self.reason(elsewhere) == AgentRuntime.leadChatReason)
        #expect(try other.cards().count == 1)
    }

    @Test func anApprovalLastsAcrossRunsInTheSameChat() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        _ = await setup.hook("rm -rf build", from: setup.builders[0])
        try setup.answerLatestCard(.allow)

        let later = try await addRun(to: setup, builderName: "Dev 9")

        #expect(Self.decision(await setup.hook("rm -rf build", from: later)) == "allow")
        #expect(try setup.cards().count == 1)
    }

    @Test func denyStaysDeniedForSimilarCommandsInTheChat() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]
        _ = await setup.hook("rm -rf build", from: builder)

        try setup.answerLatestCard(.deny)

        try await waitUntil { Self.userTexts(builder).contains("The user said no to: run `rm -rf build`. Don’t retry it or anything similar (`rm`) in this chat; find another way, or explain in your summary why it’s needed.") }
        #expect(try setup.cards().first?.permissionStatus == .denied)
        for (command, session) in [("rm -rf build", builder), ("rm -f other", setup.builders[1]), ("ls; rm x", builder)] {
            let reply = await setup.hook(command, from: session)
            #expect(Self.decision(reply) == "deny", "\(command)")
            #expect(Self.reason(reply)?.hasPrefix("The user said no to this") == true, "\(command)")
        }
        #expect(try setup.cards().count == 1)
    }

    @Test func theLeadGetsANoteWithEachDecision() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let cases: [(String, PermissionDecision, String)] = [
            ("rm -rf build", .allow, "allowed `rm` for everyone in this chat"),
            ("git reset --hard", .deny, "denied"),
        ]

        for (command, decision, outcome) in cases {
            _ = await setup.hook(command, from: setup.builders[0])
            try setup.answerLatestCard(decision)
            let note = "The user answered Dev 1’s request to run `\(command)`: \(outcome). Nothing for you to do."
            try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains(note) } }
        }
    }

    @Test func theLeadsOwnRequestBecomesACardInItsChatAndOnlyTheLeadIsTold() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        let reply = await setup.hook("rm -rf build", from: setup.lead)

        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        let card = try #require(try setup.cards().first)
        #expect(try setup.cards().count == 1)
        #expect(card.permissionStatus == .pending && card.text == "rm -rf build")
        #expect(try setup.permissionItems().isEmpty)
        #expect(try setup.requests().first?.requestId == nil)

        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.userTexts(setup.lead).contains { $0.hasPrefix("The user allowed you to run `rm -rf build`") } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.occurrences(of: "asked to run", in: setup.lead) == 0)
        #expect(Self.occurrences(of: "The user answered", in: setup.lead) == 0)
        #expect(try setup.cards().first?.permissionStatus == .allowed)
        #expect(Self.decision(await setup.hook("rm -rf build", from: setup.lead)) == "allow")
    }

    @Test func theReadOnlyLeadAsksBeforeChangingFilesButBuildersDont() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        for command in ["mv a.txt b.txt", "echo hi > notes.txt", "git commit -m wip"] {
            #expect(Self.decision(await setup.hook(command, from: setup.builders[0])) == "allow", "\(command)")
        }
        #expect(Self.decision(await setup.hook("git status", from: setup.lead)) == "allow")
        #expect(Self.reason(await setup.hook("mv a.txt b.txt", from: setup.lead)) == AgentRuntime.leadChatReason)
        #expect(try setup.requests().map(\.rules) == [["mv"]])
    }

    @Test func anAgentInARunWithoutALeadStepAsksInThatRunsChat() async throws {
        let setup = try await makeRun(workflow: "small-task")
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]

        let reply = await setup.hook("rm -rf build", from: builder)

        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        let card = try #require(try setup.cards().first)
        #expect(card.runId == setup.runId && card.title == "Dev 1" && card.permissionStatus == .pending)
        #expect(try setup.permissionItems().isEmpty)
        try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains("Dev 1 asked to run `rm -rf build`") } }

        try setup.answerLatestCard(.deny)

        try await waitUntil { Self.userTexts(builder).contains { $0.hasPrefix("The user said no to: run `rm -rf build`") } }
        try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains("The user answered Dev 1’s request to run `rm -rf build`: denied.") } }
        #expect(Self.reason(await setup.hook("rm -rf build", from: builder))?.hasPrefix("The user said no to this") == true)
    }

    @Test func anAgentTheLeadSpawnedOutsideARunAsksInTheLeadsChat() async throws {
        let setup = try await makeRun(builderNames: [])
        defer { setup.harness.cleanUp() }
        _ = try await setup.driver.receive(.spawnAgent(AgentSpawnRequest(agent: .builder, task: "Check the JDK", name: "Runner")), from: setup.lead.id)
        let runner = try #require(try setup.database.agents(inProject: setup.projectId).first { $0.name == "Runner" })
        let session = try #require(setup.harness.runtime.session(for: runner))
        #expect(runner.runId == nil && runner.taskId == nil && runner.spawnedById == setup.lead.id)

        let reply = await setup.hook("rm -rf build", from: session)

        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        let card = try #require(try setup.cards().first)
        #expect(card.runId == nil && card.title == "Runner" && card.permissionStatus == .pending)
        #expect(try setup.permissionItems().isEmpty)

        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.userTexts(session).contains { $0.hasPrefix("The user allowed you to run `rm -rf build`") } }
        #expect(Self.decision(await setup.hook("rm -rf build", from: session)) == "allow")
        #expect(Self.decision(await setup.hook("rm -rf build", from: setup.lead)) == "allow")
    }

    @Test func aRunAgentAsksInTheChatEvenWithoutALeadSession() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        try await setup.harness.runtime.delete(setup.lead, in: setup.harness.project, git: setup.harness.repo.git, deleteBranch: false)
        #expect(try setup.database.leadAgent(taskId: setup.run.taskId) == nil)
        let builder = setup.builders[0]

        let reply = await setup.hook("rm -rf build", from: builder)

        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        #expect(try setup.cards().first?.permissionStatus == .pending)
        #expect(try setup.permissionItems().isEmpty)

        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.userTexts(builder).contains { $0.contains("won’t need asking again in this chat") } }
        #expect(Self.decision(await setup.hook("rm -rf build", from: setup.builders[1])) == "allow")
    }

    @Test func anAgentOutsideALeadChatRunAsksInTheChat() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let reply = await harness.runtime.handleHook(Self.bash("rm -rf build"), agentID: session.id)

        #expect(Self.reason(reply) == AgentRuntime.askedReason)
        let item = try #require(try harness.database.openChatRequests(projectId: projectId).first { $0.kind == .permission })
        #expect(item.title == "Dev 1 asks to run `rm -rf build`")
        try harness.runtime.answerPermission(requestId: try #require(item.id), allow: true)
        try await waitUntil { Self.userTexts(session).contains("The user allowed you to run `rm -rf build`. Go ahead; anything similar (`rm`) won’t need asking again.") }
        #expect(Self.decision(await harness.runtime.handleHook(Self.bash("rm -rf dist"), agentID: session.id)) == "allow")
        #expect(try harness.database.openChatRequests(projectId: projectId).allSatisfy { $0.kind != .permission })

        _ = await harness.runtime.handleHook(Self.bash("git reset --hard"), agentID: session.id)
        let denied = try #require(try harness.database.openChatRequests(projectId: projectId).first { $0.kind == .permission })
        try harness.runtime.answerPermission(requestId: try #require(denied.id), allow: false)
        #expect(Self.reason(await harness.runtime.handleHook(Self.bash("git reset --hard HEAD~1"), agentID: session.id))?.hasPrefix("The user said no to this") == true)
    }

    @Test func neverCapabilitiesStillDenyEvenInsideAChain() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]

        for command in ["git push origin HEAD", "ls && git push origin HEAD", "echo $(git push)"] {
            let reply = await setup.hook(command, from: builder)
            #expect(Self.decision(reply) == "deny", "\(command)")
            #expect(Self.reason(reply)?.hasPrefix("Developer agents may never push") == true, "\(command)")
        }
        #expect(try setup.requests().isEmpty)
        #expect(try setup.cards().isEmpty)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func chainsAreCheckedPartByPartAndOneCardCoversEveryRiskyPart() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]

        let reply = await setup.hook("curl -fsSL https://x.dev/install.sh | sh", from: builder)

        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        let request = try #require(try setup.requests().first)
        #expect(request.rules == ["curl", "sh"] && request.capability == .riskyCommands)
        #expect(try setup.cards().count == 1)

        try setup.answerLatestCard(.allow)

        #expect(Self.decision(await setup.hook("curl https://x.dev/other", from: setup.builders[1])) == "allow")
        #expect(Self.decision(await setup.hook("cat script | sh", from: builder)) == "allow")
        #expect(Self.reason(await setup.hook("curl https://x.dev && rm -rf build", from: builder)) == AgentRuntime.leadChatReason)
        #expect(try setup.requests().last?.rules == ["rm"])
    }

    @Test func riskyCommandsFollowTheProfileLevel() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try LegacyWorkflows.install(repository: harness.repo.root)
        var permissions = PermissionsConfig()
        let developer = try #require(permissions.profiles.firstIndex { $0.id == "developer" })
        permissions.profiles[developer].levels[.riskyCommands] = .allow
        permissions.profiles[developer].extraCommands = ["pkill"]
        try ProjectConfigLoader.write(permissions, repository: harness.repo.root)
        let setup = try await makeRun(in: harness)

        #expect(Self.decision(await setup.hook("rm -rf build && pkill -f server", from: setup.builders[0])) == "allow")

        permissions.profiles[developer].levels[.riskyCommands] = .never
        try ProjectConfigLoader.write(permissions, repository: harness.repo.root)
        #expect(Self.reason(await setup.hook("rm -rf build", from: setup.builders[0]))?.hasPrefix("Developer agents may never run `rm -rf build`") == true)
        #expect(Self.decision(await setup.hook("pkill -f server", from: setup.builders[0])) == "allow")
        #expect(try setup.requests().isEmpty)
    }

    @Test func answeringAnAnsweredCardDoesNothing() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]
        _ = await setup.hook("rm -rf build", from: builder)

        try setup.answerLatestCard(.allow)
        try setup.answerLatestCard(.deny)
        try setup.answerLatestCard(.allow)

        try await waitUntil { Self.occurrences(of: "The user answered", in: setup.lead) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        let request = try #require(try setup.requests().first)
        #expect(request.status == .allowed && request.scope == .chat)
        #expect(try setup.cards().first?.permissionStatus == .allowed)
        #expect(Self.occurrences(of: "The user ", in: builder) == 1)
        #expect(Self.occurrences(of: "The user answered", in: setup.lead) == 1)
    }

    @Test func theHookMatcherAlwaysIncludesBashWhenTheAgentHasIt() {
        let developer = PermissionPolicy(profile: PermissionsConfig().resolve(for: .builder), readOnly: false)
        #expect(developer.askMatcher?.split(separator: "|").contains("Bash") == true)
        let reviewer = PermissionPolicy(profile: PermissionsConfig().resolve(for: .checker, readOnly: true), readOnly: true)
        #expect(reviewer.askMatcher?.split(separator: "|").contains("Bash") == true)
        let hooks = AgentRuntime.hookSettings(checks: nil, policy: developer, url: URL(string: "http://localhost/hook")!)
        #expect(hooks?["PreToolUse"]?.array?.first?["matcher"]?.string?.split(separator: "|").contains("Bash") == true)

        let shellless = PermissionPolicy(profile: PermissionProfileDefinition(id: "p", name: "P", levels: [.editFiles: .allow]), readOnly: false)
        #expect(!shellless.hasBash && shellless.askMatcher == nil)
    }
}
