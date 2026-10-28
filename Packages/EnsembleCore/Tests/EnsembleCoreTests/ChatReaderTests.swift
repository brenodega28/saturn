import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct ChatReaderTests {
    @MainActor
    struct Fixture {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let otherProjectFolder: URL
        let task: ProjectTask
        let messages: [LeadMessage]
        let lead: Agent
        let run: Run
        let builder: Agent
        let outsider: Agent

        var reader: ChatReader { ChatReader(database: harness.database, paths: harness.runtime.paths) }
        var taskID: Int64 { task.id! }

        func cleanUp() {
            harness.runtime.mcpServer?.stop()
            harness.cleanUp()
            try? FileManager.default.removeItem(at: otherProjectFolder)
        }
    }

    static let snapshot = """
        name: Small task
        steps:
          - id: build
            type: agent
            title: Build
            role: claude-code
            next: review
          - id: review
            type: agent
            title: AI review
            role: pr-reviewer
            routes:
              approved: end
              changes_requested: build
        """

    func makeFixture(messageCount: Int = 4) async throws -> Fixture {
        let harness = try await AgentHarness.make()
        let database = harness.database
        let projectA = try #require(harness.project.id)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let task = try database.insert(ProjectTask(
            projectId: projectA, title: "Fix the login loop", body: "Login redirects forever.", source: .chat,
            status: .running, createdAt: base, updatedAt: base
        ))
        let taskID = try #require(task.id)
        var messages: [LeadMessage] = []
        for index in 0..<messageCount {
            let kind: LeadMessageKind = index % 2 == 0 ? .user : .lead
            let attachments: [StoredChatAttachment]? = index == 0 ? [.pastedText(id: UUID(), index: 1, text: "line 1\nline 2")] : nil
            messages.append(try database.insert(LeadMessage(
                projectId: projectA, taskId: taskID, kind: kind, text: "Message number \(index)",
                createdAt: base.addingTimeInterval(Double(index)), attachments: attachments
            )))
        }
        messages.append(try database.insert(LeadMessage(
            projectId: projectA, taskId: taskID, kind: .proposal, text: "Fix the redirect check",
            workflow: "small-task", title: "Stop the loop", status: .started, createdAt: base.addingTimeInterval(Double(messageCount))
        )))
        let lead = try database.insert(Agent(
            projectId: projectA, role: "tech-lead", name: "Lead", status: .idle, readOnly: true, taskId: taskID, createdAt: base, updatedAt: base
        ))
        let run = try database.insert(Run(
            projectId: projectA, taskId: taskID, workflow: "small-task", workflowVersion: "2", currentStep: "review",
            status: .succeeded, costUSD: 1.5, startedAt: base, endedAt: base.addingTimeInterval(600), title: "Stop the loop",
            workflowSnapshot: Self.snapshot, pullRequestURL: "https://github.com/acme/app/pull/42"
        ), state: RunEngineState())
        let runID = try #require(run.id)
        let encoder = JSONEncoder()
        let build = try database.insert(RunStep(
            runId: runID, stepId: "build", status: .succeeded, outcome: "next",
            output: String(decoding: try encoder.encode(StepOutput(summary: "Fixed the redirect check")), as: UTF8.self),
            costUSD: 1, startedAt: base, endedAt: base.addingTimeInterval(300)
        ))
        _ = try database.insert(RunStep(
            runId: runID, stepId: "review", status: .succeeded, outcome: StepOutcome.approved,
            output: String(decoding: try encoder.encode(StepOutput(verdict: Verdict(outcome: StepOutcome.approved, summary: "Looks right", issues: [ReviewIssue(description: "Add a test", file: "login.swift")]))), as: UTF8.self),
            costUSD: 0.5, startedAt: base.addingTimeInterval(300), endedAt: base.addingTimeInterval(600)
        ))
        let builder = try database.insert(Agent(
            projectId: projectA, runId: runID, role: "claude-code", name: "Dev 1", status: .idle, runStepId: build.id, createdAt: base, updatedAt: base
        ))

        let otherProjectFolder = FileManager.default.temporaryDirectory.appending(path: "ensemble-project-b-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherProjectFolder, withIntermediateDirectories: true)
        let projectB = try #require(try database.openProject(at: otherProjectFolder).id)
        let outsider = try database.insert(Agent(
            projectId: projectB, role: "claude-code", name: "Outsider", worktreePath: otherProjectFolder.path, status: .idle, createdAt: base, updatedAt: base
        ))
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        return Fixture(
            harness: harness, driver: driver, otherProjectFolder: otherProjectFolder, task: task, messages: messages,
            lead: lead, run: run, builder: builder, outsider: outsider
        )
    }

    func writeTranscript(for agent: Agent, lines: [String], paths: AppPaths) throws {
        let url = paths.transcript(try #require(agent.id))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func anAgentInAnotherProjectReadsTheOverview() async throws {
        let f = try await makeFixture()
        defer { f.cleanUp() }
        #expect(f.outsider.projectId != f.task.projectId)

        let text = try await f.driver.receive(.readChat(ChatReadRequest(requestID: f.taskID)), from: try #require(f.outsider.id))

        #expect(text.hasPrefix("Request chat \(f.taskID): Fix the login loop"))
        #expect(text.contains("Project: \(f.harness.project.name) (\(f.harness.project.path))"))
        #expect(text.contains("Login redirects forever."))
        #expect(text.contains("Lead: Lead (tech-lead, id \(f.lead.id!))"))
        #expect(text.contains("- run \(f.run.id!) · workflow small-task · status succeeded · step review"))
        #expect(text.contains("PR https://github.com/acme/app/pull/42"))
        #expect(text.contains("Agents: Dev 1 (claude-code, id \(f.builder.id!))"))
        #expect(text.contains("Message number 0\nAttachments: Pasted text #1 · 2 lines"))
        #expect(text.contains("[message \(f.messages.last!.id!)] proposal"))
        #expect(text.contains("Title: Stop the loop"))
        #expect(text.contains("section=transcript"))
        #expect(!text.contains("More: call again"))
    }

    @Test func readChatDecodesFromToolArguments() throws {
        let message = try HandoffTool.readChat.decode(.object([
            "request_id": .number(12), "message_id": .number(40), "section": .string("transcript"),
            "agent": .string("Dev 1"), "offset": .number(5), "limit": .number(10),
        ]))
        #expect(message == .readChat(ChatReadRequest(requestID: 12, messageID: 40, section: .transcript, agent: "Dev 1", offset: 5, limit: 10)))
        #expect(try HandoffTool.readChat.decode(.object(["request_id": .number(3)])) == .readChat(ChatReadRequest(requestID: 3)))
        #expect(throws: HandoffError.missing("request_id")) { try HandoffTool.readChat.decode(.object([:])) }
        #expect(throws: HandoffError.missing("run_id")) { try HandoffTool.readChat.decode(.object(["request_id": .number(3), "section": .string("run")])) }
        #expect(throws: HandoffError.missing("agent")) { try HandoffTool.readChat.decode(.object(["request_id": .number(3), "section": .string("transcript")])) }
        #expect(throws: HandoffError.self) { try HandoffTool.readChat.decode(.object(["request_id": .number(3), "section": .string("logs")])) }
        #expect(HandoffTool.readChat.description.contains("ensemble://chat/<request_id>?message=<message_id>"))
    }

    @Test func theReferencedMessageIsMarkedAndOnThePage() async throws {
        let f = try await makeFixture(messageCount: 30)
        defer { f.cleanUp() }
        let target = try #require(f.messages[20].id)

        let text = try f.reader.read(ChatReadRequest(requestID: f.taskID, messageID: target, section: .messages, limit: 5))

        #expect(text.contains("\(ChatReader.referenceStart)\n[message \(target)] user"))
        #expect(text.contains("Message number 20\n\(ChatReader.referenceEnd)"))
        #expect(text.contains("Message number 18"))
        #expect(!text.contains("Message number 17"))
        #expect(text.contains("More: call again with offset=23, section=messages, message_id=\(target)."))
        #expect(text.contains("Earlier messages start at offset=0."))

        let early = try f.reader.read(ChatReadRequest(requestID: f.taskID, messageID: f.messages[2].id, section: .messages, limit: 5))
        #expect(early.contains("Message number 0"))
        #expect(early.contains(ChatReader.referenceStart))
    }

    @Test func messagesPageWithOffsetAndLimitAndTheCharacterCap() async throws {
        let f = try await makeFixture(messageCount: 10)
        defer { f.cleanUp() }

        let page = try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .messages, offset: 3, limit: 4))
        #expect(page.contains("Message number 3"))
        #expect(page.contains("Message number 6"))
        #expect(!page.contains("Message number 2\n"))
        #expect(!page.contains("Message number 7"))
        #expect(page.contains("Showing messages 3–6 of 11"))
        #expect(page.contains("More: call again with offset=7, section=messages."))

        let last = try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .messages, offset: 7))
        #expect(last.contains("Stop the loop"))
        #expect(!last.contains("More: call again"))

        let projectID = f.task.projectId
        for index in 0..<6 {
            try f.harness.database.insert(LeadMessage(
                projectId: projectID, taskId: f.taskID, kind: .lead, text: String(repeating: "x", count: 12_000),
                createdAt: Date(timeIntervalSince1970: 1_900_000_000 + Double(index))
            ))
        }
        let capped = try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .messages, offset: 11))
        #expect(capped.count <= ChatReader.maxCharacters)
        #expect(capped.contains("More: call again with offset=14, section=messages."))
    }

    @Test func runSectionShowsTheStepHistory() async throws {
        let f = try await makeFixture()
        defer { f.cleanUp() }
        let runID = try #require(f.run.id)

        let text = try await f.driver.receive(.readChat(ChatReadRequest(requestID: f.taskID, section: .run, runID: runID)), from: try #require(f.outsider.id))

        #expect(text.hasPrefix("Run \(runID) of request \(f.taskID): Stop the loop"))
        #expect(text.contains("Workflow small-task v2 · status succeeded · cost $1.50"))
        #expect(text.contains("PR: https://github.com/acme/app/pull/42"))
        #expect(text.contains("[step 1] Build (build, agent) · iteration 1 · succeeded · outcome next · $1.00"))
        #expect(text.contains("Result: Fixed the redirect check"))
        #expect(text.contains("Agents: Dev 1 (id \(f.builder.id!))"))
        #expect(text.contains("Next: AI review on next"))
        #expect(text.contains("[step 2] AI review (review, agent)"))
        #expect(text.contains("Verdict: approved · Looks right\n  - Add a test (login.swift)"))
    }

    @Test func transcriptSectionReadsAndPagesTheJSONL() async throws {
        let f = try await makeFixture()
        defer { f.cleanUp() }
        let longResult = String(repeating: "r", count: 5_000)
        try writeTranscript(for: f.builder, lines: [
            #"{"type":"user","message":{"role":"user","content":"Fix the redirect"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at login.swift"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"\#(longResult)","is_error":false}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass"}]}}"#,
        ], paths: f.harness.runtime.paths)

        let all = try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .transcript, agent: "dev 1"))
        #expect(all.hasPrefix("Transcript of Dev 1 (claude-code, id \(f.builder.id!)) in request \(f.taskID), run \(f.run.id!)"))
        #expect(all.contains("[entry 0] user:\nFix the redirect"))
        #expect(all.contains("[entry 1] assistant:\nLooking at login.swift"))
        #expect(all.contains(#"[entry 2] tool call Bash {"command":"swift test"}"#))
        #expect(all.contains("tool result: " + String(repeating: "r", count: ChatReader.toolTextLimit) + "… [3000 more characters]"))
        #expect(all.contains("[entry 3] assistant:\nTests pass"))

        let page = try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .transcript, runID: f.run.id, agent: String(f.builder.id!), offset: 1, limit: 2))
        #expect(!page.contains("[entry 0]"))
        #expect(page.contains("[entry 1]") && page.contains("[entry 2]"))
        #expect(!page.contains("[entry 3]"))
        #expect(page.contains("More: call again with offset=3, section=transcript, agent=\(f.builder.id!), run_id=\(f.run.id!)."))
    }

    @Test func missingRequestsMessagesRunsAgentsAndTranscriptsAreToolErrors() async throws {
        let f = try await makeFixture()
        defer { f.cleanUp() }
        let outsiderID = try #require(f.outsider.id)

        await #expect(throws: ChatReaderError.unknownRequest(9_999)) {
            try await f.driver.receive(.readChat(ChatReadRequest(requestID: 9_999)), from: outsiderID)
        }
        #expect(ChatReaderError.unknownRequest(9_999).localizedDescription == "No request chat with id 9999; it may have been deleted.")
        #expect(throws: ChatReaderError.unknownMessage(8_888, requestID: f.taskID)) {
            try f.reader.read(ChatReadRequest(requestID: f.taskID, messageID: 8_888))
        }

        let otherTask = try f.harness.database.insert(ProjectTask(
            projectId: f.task.projectId, title: "Other", body: "", source: .chat, status: .incoming, createdAt: .now, updatedAt: .now
        ))
        let foreignRun = try f.harness.database.insert(Run(
            projectId: f.task.projectId, taskId: try #require(otherTask.id), workflow: "small-task", status: .running, startedAt: .now
        ), state: RunEngineState())
        #expect(throws: ChatReaderError.unknownRun(try #require(foreignRun.id), requestID: f.taskID, runs: [try #require(f.run.id)])) {
            try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .run, runID: foreignRun.id))
        }
        #expect(throws: ChatReaderError.self) {
            try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .transcript, runID: foreignRun.id, agent: "Dev 1"))
        }
        #expect(throws: ChatReaderError.self) {
            try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .transcript, agent: "Outsider"))
        }
        #expect(throws: ChatReaderError.missingTranscript(agent: "Lead", id: try #require(f.lead.id))) {
            try f.reader.read(ChatReadRequest(requestID: f.taskID, section: .transcript, agent: "Lead"))
        }
    }

    @Test func aStandaloneAgentGetsReadChatThroughItsMCPEndpoint() async throws {
        let f = try await makeFixture()
        defer { f.cleanUp() }
        #expect(f.outsider.taskId == nil && f.outsider.runId == nil)
        #expect(f.driver.tools(for: f.outsider) == [.readChat])
        #expect(f.driver.tools(for: f.builder).contains(.readChat))
        #expect(f.driver.tools(for: f.lead).contains(.readChat))

        try await f.driver.ensureServer()
        let setup = try f.harness.runtime.turnSetup(for: f.outsider)
        #expect(setup.extraArguments.contains("--mcp-config"))
        #expect(setup.extraAllowedTools.contains(HandoffTool.readChat.qualifiedName))
        #expect(setup.systemPrompt.contains("- `\(HandoffTool.readChat.qualifiedName)`: Read an Ensemble request chat from any project"))
    }
}
