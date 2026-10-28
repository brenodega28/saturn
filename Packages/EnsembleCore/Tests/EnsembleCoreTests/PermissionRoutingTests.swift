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

        func permissionItems() throws -> [InboxItem] {
            try database.openInboxItems(projectId: projectId).filter { $0.kind == .permission }
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

    func makeRun(in existing: AgentHarness? = nil, builderNames: [String] = ["Dev 1", "Dev 2"]) async throws -> LeadRun {
        let harness: AgentHarness
        if let existing {
            harness = existing
        } else {
            harness = try await AgentHarness.make()
            try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
            try LegacyWorkflows.install(repository: harness.repo.root)
        }
        let workflow = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow("feature-delivery"))
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        let projectId = try #require(harness.project.id)
        let now = Date()
        let task = try harness.database.insert(ProjectTask(
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

    @Test func anUnlistedCommandInALeadChatRunBecomesAPendingCardInsteadOfASilentDeny() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        let reply = await setup.hook("java -version", from: setup.builders[0])

        #expect(Self.decision(reply) == "deny")
        #expect(Self.reason(reply) == AgentRuntime.leadChatReason)
        #expect(Self.reason(reply)?.contains("lead chat") == true)
        let request = try #require(try setup.requests().first)
        #expect(request.status == .pending && request.capability == .runShell && request.request == "java -version")
        #expect(request.runId == setup.runId && request.inboxItemId == nil)
        let card = try #require(try setup.cards().first)
        #expect(try setup.cards().count == 1)
        #expect(card.permissionRequestId == request.id && card.permissionStatus == .pending)
        #expect(card.title == "Dev 1" && card.text == "java -version" && card.capability == .runShell)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func theLeadIsToldOnceAndToldNotToAnswer() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        _ = await setup.hook("java -version", from: setup.builders[0])
        let again = await setup.hook("java -version", from: setup.builders[0])

        #expect(Self.reason(again) == AgentRuntime.waitingReason)
        try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains("asked to run") } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.occurrences(of: "asked to run", in: setup.lead) == 1)
        #expect(Self.userTexts(setup.lead).contains { $0.contains("Dev 1 asked to run `java -version`. The user sees an Allow/Deny card in this chat; don’t answer it yourself.") })
        #expect(try setup.cards().count == 1)
    }

    @Test func allowOnceLetsTheNextAttemptThroughAndThenAsksAgain() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]
        _ = await setup.hook("java -version", from: builder)

        try setup.answerLatestCard(.allowOnce)

        try await waitUntil { Self.userTexts(builder).contains { $0.hasPrefix("The user allowed you to run `java -version`") } }
        #expect(try setup.cards().first?.permissionStatus == .allowedOnce)
        #expect(Self.decision(await setup.hook("java -version", from: builder)) == "allow")
        let next = await setup.hook("java -version", from: builder)
        #expect(Self.reason(next) == AgentRuntime.leadChatReason)
        #expect(try setup.cards().count == 2)
        #expect(try setup.requests().first?.consumedAt != nil)
    }

    @Test func allowForRunCoversTheCommandNameForEveryAgentInTheRunOnly() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        _ = await setup.hook("java -version", from: setup.builders[0])

        try setup.answerLatestCard(.allowForRun)

        try await waitUntil { Self.userTexts(setup.builders[0]).contains { $0.contains("any `java` command for the rest of this run") } }
        #expect(try setup.cards().first?.permissionStatus == .allowedForRun)
        #expect(Self.decision(await setup.hook("java -version", from: setup.builders[0])) == "allow")
        #expect(Self.decision(await setup.hook("java -jar build/app.jar", from: setup.builders[1])) == "allow")
        #expect(Self.decision(await setup.hook("java -version", from: setup.builders[0])) == "allow")
        #expect(try setup.cards().count == 1)

        let other = try await makeRun(in: setup.harness, builderNames: ["Dev 3"])
        let elsewhere = await other.hook("java -version", from: other.builders[0])
        #expect(Self.decision(elsewhere) == "deny")
        #expect(Self.reason(elsewhere) == AgentRuntime.leadChatReason)
        #expect(try other.cards().count == 1)
    }

    @Test func denyStaysDeniedForTheRestOfTheRun() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]
        _ = await setup.hook("java -version", from: builder)

        try setup.answerLatestCard(.deny)

        try await waitUntil { Self.userTexts(builder).contains("The user said no to: run `java -version`. Find another way, or explain in your summary why it’s needed.") }
        #expect(try setup.cards().first?.permissionStatus == .denied)
        for _ in 0..<2 {
            let reply = await setup.hook("java -version", from: builder)
            #expect(Self.decision(reply) == "deny")
            #expect(Self.reason(reply)?.hasPrefix("The user said no to this") == true)
        }
        #expect(try setup.cards().count == 1)
    }

    @Test func theLeadGetsANoteWithEachDecision() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let cases: [(String, PermissionDecision, String)] = [
            ("java -version", .allowOnce, "allowed once"),
            ("kotlinc -version", .allowForRun, "allowed `kotlinc` for every agent for the rest of this run"),
            ("ruby -v", .deny, "denied"),
        ]

        for (command, decision, outcome) in cases {
            _ = await setup.hook(command, from: setup.builders[0])
            try setup.answerLatestCard(decision)
            let note = "The user answered Dev 1’s request to run `\(command)`: \(outcome). Nothing for you to do."
            try await waitUntil { Self.userTexts(setup.lead).contains { $0.contains(note) } }
        }
    }

    @Test func anAgentOutsideALeadChatRunAsksInTheInbox() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let projectId = try #require(harness.project.id)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let reply = await harness.runtime.handleHook(Self.bash("java -version"), agentID: session.id)

        #expect(Self.reason(reply) == AgentRuntime.inboxReason)
        let item = try #require(try harness.database.openInboxItems(projectId: projectId).first { $0.kind == .permission })
        #expect(item.title == "Dev 1 asks to run `java -version`")
        try harness.runtime.answerPermission(inboxItemId: try #require(item.id), allow: true)
        try await waitUntil { Self.userTexts(session).contains { $0.hasPrefix("The user allowed you to run `java -version`") } }
        #expect(Self.decision(await harness.runtime.handleHook(Self.bash("java -version"), agentID: session.id)) == "allow")
        #expect(try harness.database.openInboxItems(projectId: projectId).allSatisfy { $0.kind != .permission })

        _ = await harness.runtime.handleHook(Self.bash("ruby -v"), agentID: session.id)
        let denied = try #require(try harness.database.openInboxItems(projectId: projectId).first { $0.kind == .permission })
        try harness.runtime.answerPermission(inboxItemId: try #require(denied.id), allow: false)
        #expect(Self.reason(await harness.runtime.handleHook(Self.bash("ruby -v"), agentID: session.id))?.hasPrefix("The user said no to this") == true)
    }

    @Test func allowListedCommandsAndNeverCapabilitiesBehaveAsBefore() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]

        #expect(await setup.hook("swift test", from: builder) == .object([:]))
        #expect(await setup.hook("git status --short", from: builder) == .object([:]))
        #expect(await setup.hook("echo hi > notes.txt", from: builder) == .object([:]))
        let push = await setup.hook("git push origin HEAD", from: builder)
        #expect(Self.decision(push) == "deny")
        #expect(Self.reason(push)?.hasPrefix("Developer agents may never push") == true)
        #expect(try setup.requests().isEmpty)
        #expect(try setup.cards().isEmpty)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func chainedCommandsAreDeniedWithTheShellRulesAndAskNoOne() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        for command in ["java -version && ls", "ls; java -version", "java -version | head", "java -version > out.txt", "echo $(java -version)", "echo `java -version`", "cat <<EOF\nhi\nEOF"] {
            let reply = await setup.hook(command, from: setup.builders[0])
            #expect(Self.decision(reply) == "deny", "\(command)")
            #expect(Self.reason(reply) == AgentRuntime.chainedCommandReason, "\(command)")
            #expect(Self.reason(reply)?.hasPrefix(ClaudeLaunch.oneCommandRule) == true)
        }
        #expect(try setup.requests().isEmpty)
        #expect(try setup.cards().isEmpty)
        #expect(try setup.permissionItems().isEmpty)
    }

    @Test func operatorsInsideQuotesDontMakeAnAllowListedCommandChained() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }

        for command in [
            #"rg "foo|bar" src"#,
            "grep -E 'a|b' notes.txt",
            #"git commit -m "Fix A; B""#,
            "git commit -m \"Fix the parser\n\nIt now handles && and > in arguments.\"",
            #"git commit -m "Add \"quoted\" | piped text""#,
            "swift test 2>&1",
        ] {
            #expect(await setup.hook(command, from: setup.builders[0]) == .object([:]), "\(command)")
        }
        let quotedUnlisted = await setup.hook(#"java -cp "a;b" Main"#, from: setup.builders[0])
        #expect(Self.reason(quotedUnlisted) == AgentRuntime.leadChatReason)
        #expect(try setup.cards().count == 1)
        #expect(Self.reason(await setup.hook(#"rg "foo" src | java -version"#, from: setup.builders[0])) == AgentRuntime.chainedCommandReason)
        #expect(Self.reason(await setup.hook("echo 'quoted' && java -version", from: setup.builders[0])) == AgentRuntime.chainedCommandReason)
    }

    @Test func answeringAnAnsweredCardDoesNothing() async throws {
        let setup = try await makeRun()
        defer { setup.harness.cleanUp() }
        let builder = setup.builders[0]
        _ = await setup.hook("java -version", from: builder)

        try setup.answerLatestCard(.allowOnce)
        try setup.answerLatestCard(.deny)
        try setup.answerLatestCard(.allowForRun)

        try await waitUntil { Self.occurrences(of: "The user answered", in: setup.lead) == 1 }
        try await Task.sleep(for: .milliseconds(300))
        let request = try #require(try setup.requests().first)
        #expect(request.status == .allowed && request.scope == .once)
        #expect(try setup.cards().first?.permissionStatus == .allowedOnce)
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
