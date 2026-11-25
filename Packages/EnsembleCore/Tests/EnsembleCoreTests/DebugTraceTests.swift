#if DEBUG
import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct DebugTraceTests {
    @Test func writesTheDocumentedLayoutAndReadme() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))
        let chatAgent = Self.agent(id: 7, name: "Tech Lead 1")
        let runAgent = Self.agent(id: 9, name: "Dev 1", runId: 3)

        trace.runEvent("run_started", runId: 3, title: "Refunds v2", fields: ["workflow": JSONValue("small-task")])
        trace.lifecycle("started", agent: chatAgent)
        trace.lifecycle("started", agent: runAgent)
        trace.chatMessage("Hi", direction: "user_to_agent", chat: "lead", agent: chatAgent)
        trace.flush()

        let logs = root.appending(path: "debug-logs")
        #expect(FileManager.default.fileExists(atPath: logs.appending(path: "README.md").path))
        let readme = try String(contentsOf: logs.appending(path: "README.md"), encoding: .utf8)
        for type in ["launch", "session_init", "raw", "turn_summary", "lifecycle", "chat_message", "run_started", "step_started", "step_finished", "condition_evaluated", "routed", "hold", "hold_resolved", "question_relayed", "question_answered", "step_failed", "failure_action", "run_finished"] {
            #expect(readme.contains("`\(type)`"), "README misses \(type)")
        }

        let traceEvents = try Self.events(logs.appending(path: "runs/3-refunds-v2/trace.jsonl"))
        #expect(traceEvents.map { $0["type"]?.string } == ["run_started"])
        #expect(traceEvents.first?["runId"]?.int == 3)
        #expect(traceEvents.first?["at"]?.string?.contains("T") == true)

        let runAgentEvents = try Self.events(logs.appending(path: "runs/3-refunds-v2/agents/9-dev-1.jsonl"))
        #expect(runAgentEvents.first?["type"]?.string == "lifecycle")
        #expect(runAgentEvents.first?["agentId"]?.int == 9)
        #expect(runAgentEvents.first?["runId"]?.int == 3)

        let chatEvents = try Self.events(logs.appending(path: "chats/7-tech-lead-1/agent.jsonl"))
        #expect(chatEvents.map { $0["type"]?.string } == ["lifecycle", "chat_message"])
        #expect(chatEvents.last?["direction"]?.string == "user_to_agent")
    }

    @Test func storesEachPromptOnce() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))

        let first = trace.storePrompt("You are Dev 1.")
        let again = trace.storePrompt("You are Dev 1.")
        let other = trace.storePrompt("You are Dev 2.")
        trace.flush()

        #expect(first == again)
        #expect(first != other)
        #expect(first.count == DebugTrace.hashLength)
        let prompts = try FileManager.default.contentsOfDirectory(atPath: trace.promptsDirectory.path).sorted()
        #expect(prompts == ["\(first).md", "\(other).md"].sorted())
        #expect(try String(contentsOf: trace.promptsDirectory.appending(path: "\(first).md"), encoding: .utf8) == "You are Dev 1.")
    }

    @Test func truncatesLargeToolResults() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))
        let agent = Self.agent(id: 4, name: "Dev 1")
        let output = String(repeating: "x", count: 5000)

        trace.received(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(output)","is_error":false}]}}"#, agent: agent)
        trace.flush()

        let raw = try #require(try Self.events(trace.chatsDirectory.appending(path: "4-dev-1/agent.jsonl")).first)
        #expect(raw["type"]?.string == "raw")
        #expect(raw["direction"]?.string == "stdout")
        let content = raw["line"]?["message"]?["content"]?.array?.first?["content"]
        #expect(content?["originalLength"]?.int == 5000)
        #expect(content?["preview"]?.string?.count == DebugTrace.toolResultLimit)
    }

    @Test func linesTheTranscriptIgnoresStillReachTheRawLog() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }
        session.pause()
        try await waitUntil { session.agent.status == .paused }
        let trace = try #require(harness.runtime.debugTrace)
        trace.flush()

        let file = trace.chatsDirectory.appending(path: "\(session.id)-dev-1/agent.jsonl")
        let events = try Self.events(file)
        let control = try #require(events.first { $0["type"]?.string == "raw" && $0["line"]?["type"]?.string == "control_response" })
        #expect(control["transcribed"]?.bool == false)
        let transcript = try String(contentsOf: harness.runtime.paths.transcript(session.id), encoding: .utf8)
        #expect(!transcript.contains("control_response"))

        let launch = try #require(events.first { $0["type"]?.string == "launch" })
        let arguments = launch["arguments"]?.array?.compactMap(\.string) ?? []
        let systemPromptHash = try #require(launch["systemPromptHash"]?.string)
        #expect(arguments.contains("prompt:\(systemPromptHash)"))
        #expect(!arguments.contains { $0.contains("You are Dev 1") })
        let names = launch["envVarNames"]?.array?.compactMap(\.string) ?? []
        #expect(names.contains("FAKE_DIR"))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("sk-ant-from-shell"))
        #expect(FileManager.default.fileExists(atPath: trace.promptsDirectory.appending(path: "\(systemPromptHash).md").path))
        #expect(events.contains { $0["type"]?.string == "session_init" && $0["claudeCodeVersion"]?.string == "9.9.9" })
        #expect(events.contains { $0["type"]?.string == "raw" && $0["direction"]?.string == "stdin" })
        let lifecycle = events.filter { $0["type"]?.string == "lifecycle" }.compactMap { $0["event"]?.string }
        #expect(lifecycle == ["started", "paused"])
        #expect(events.contains { $0["type"]?.string == "turn_summary" && $0["interrupted"]?.bool == true })
    }

    @Test func turnSummaryCountsTokensToolsAndDenials() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))
        let agent = Self.agent(id: 5, name: "Dev 1")
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.5,"duration_ms":1200,"num_turns":3,"usage":{"input_tokens":30,"output_tokens":12,"cache_read_input_tokens":400,"cache_creation_input_tokens":50},"permission_denials":[{"tool_name":"Bash","tool_use_id":"t3","tool_input":{"command":"rm -rf build && make"}}]}"#
        let lines = [
            #"{"type":"system","subtype":"rate_limit_event"}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-fake-1","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-fake-1","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5},"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"a.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"error: build failed","is_error":true}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok","is_error":false}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","model":"claude-fake-1","usage":{"input_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":45},"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"rm -rf build && make"}}]}}"#,
            result,
        ]
        for line in lines { trace.received(line, agent: agent) }
        guard case .turnCompleted(let turn)? = ClaudeEvent.parse(line: result).first else {
            Issue.record("The result line didn’t parse")
            return
        }
        trace.turnCompleted(turn, costUSD: 0.25, agent: agent)
        trace.flush()

        let events = try Self.events(trace.chatsDirectory.appending(path: "5-dev-1/agent.jsonl"))
        #expect(events.first?["transcribed"]?.bool == false)
        let summary = try #require(events.last)
        #expect(summary["type"]?.string == "turn_summary")
        #expect(summary["inputTokens"]?.int == 30)
        #expect(summary["outputTokens"]?.int == 12)
        #expect(summary["cacheReadTokens"]?.int == 400)
        #expect(summary["cacheWriteTokens"]?.int == 50)
        #expect(summary["costUSD"]?.double == 0.25)
        #expect(summary["durationMS"]?.int == 1200)
        #expect(summary["apiCalls"]?.int == 2)
        #expect(summary["toolCalls"]?["Bash"]?.int == 2)
        #expect(summary["toolCalls"]?["Read"]?.int == 1)
        #expect(summary["toolCallTotal"]?.int == 3)
        #expect(summary["contextTokens"]?.int == 365)
        #expect(summary["numTurns"]?.int == 3)
        #expect(summary["interrupted"]?.bool == false)
        let failed = try #require(summary["failedToolCalls"]?.array?.first)
        #expect(failed["tool"]?.string == "Bash")
        #expect(failed["error"]?.string == "error: build failed")
        let denial = try #require(summary["permissionDenials"]?.array?.first)
        #expect(denial["tool"]?.string == "Bash")
        #expect(denial["input"]?["command"]?.string == "rm -rf build && make")
    }

    @Test func sizeCapDeletesTheOldestFoldersFirst() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = AppPaths(root: root).debugLogsDirectory
        let now = Date()
        try Self.folder(logs.appending(path: "runs/1-old-run"), bytes: 1000, modified: now.addingTimeInterval(-3000))
        try Self.folder(logs.appending(path: "chats/2-old-chat"), bytes: 1000, modified: now.addingTimeInterval(-2000))
        try Self.folder(logs.appending(path: "runs/3-new-run"), bytes: 1000, modified: now.addingTimeInterval(-10))
        let stale = logs.appending(path: "prompts/stale.md")
        let fresh = logs.appending(path: "prompts/fresh.md")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale)
        try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: stale.path)

        let readmeSize = Int64(DebugTraceReadme.text.utf8.count)
        let trace = DebugTrace(paths: AppPaths(root: root), sizeLimit: readmeSize + 2500)
        trace.flush()

        #expect(!FileManager.default.fileExists(atPath: logs.appending(path: "runs/1-old-run").path))
        #expect(FileManager.default.fileExists(atPath: logs.appending(path: "chats/2-old-chat").path))
        #expect(FileManager.default.fileExists(atPath: logs.appending(path: "runs/3-new-run").path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        let retention = DebugRetention(root: logs, limit: readmeSize + 1500, promptTouchInterval: 0)
        let deleted = retention.enforce(protecting: [logs.appending(path: "chats/2-old-chat")])
        #expect(deleted.map(\.lastPathComponent) == ["3-new-run"])
        #expect(FileManager.default.fileExists(atPath: logs.appending(path: "chats/2-old-chat").path))
    }

    @Test func runTraceRecordsStepsRoutesAndTheFinish() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))
        h.engine.debugTrace = trace
        let workflow = WorkflowDefinition(id: "loop", name: "Loop", steps: [
            WorkflowStep(id: "build", type: .agent, agent: .builder, next: "review"),
            WorkflowStep(id: "review", type: .agent, agent: .checker, routes: [
                StepOutcome.approved: WorkflowRoute(to: "end"),
                StepOutcome.changesRequested: WorkflowRoute(to: "build", maxLoops: 3),
            ]),
        ])
        h.driver.script("build", WorkflowHarness.done(cost: 1), WorkflowHarness.done(cost: 0.5))
        h.driver.script("review", WorkflowHarness.verdict(StepOutcome.changesRequested, "Use cents"), WorkflowHarness.verdict(StepOutcome.approved))

        let id = try await h.start(workflow)
        trace.flush()

        #expect(try h.run(id).status == .succeeded)
        let events = try Self.events(trace.runsDirectory.appending(path: "\(id)-refunds-v2/trace.jsonl"))
        let types = events.compactMap { $0["type"]?.string }
        #expect(types.first == "run_started")
        #expect(types.last == "run_finished")
        #expect(types.filter { $0 == "step_started" }.count == 5)
        #expect(types.filter { $0 == "step_finished" }.count == 5)
        let loopBack = try #require(events.first { $0["type"]?.string == "routed" && $0["isLoopBack"]?.bool == true })
        #expect(loopBack["from"]?.string == "review")
        #expect(loopBack["to"]?.string == "build")
        #expect(loopBack["outcome"]?.string == StepOutcome.changesRequested)
        #expect(loopBack["feedback"]?["summary"]?.string == "Use cents")
        let secondBuild = events.last { $0["type"]?.string == "step_started" && $0["stepId"]?.string == "build" }
        #expect(secondBuild?["iteration"]?.int == 2)
        #expect(secondBuild?["input"]?["feedback"]?["summary"]?.string == "Use cents")
        let finished = try #require(events.last)
        #expect(finished["status"]?.string == "succeeded")
        #expect(finished["totalCostUSD"]?.double == 1.5)
        #expect(finished["iterationsPerStep"]?["build"]?.int == 2)
    }

    @Test func runTraceRecordsHoldsAndTheHumanDecision() async throws {
        let h = try WorkflowHarness.make()
        defer { h.cleanUp() }
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = DebugTrace(paths: AppPaths(root: root))
        h.engine.debugTrace = trace
        h.driver.script("plan", .result(.plan(WorkflowHarness.plan)), .result(.plan(WorkflowHarness.plan)))
        h.driver.script("build", .hang)

        let id = try await h.start(try h.workflow("feature-delivery"))
        try h.engine.rejectPlan(try h.run(id), note: "Split the UI out")
        await h.settle(id)
        try await h.engine.cancel(try h.run(id))
        trace.flush()

        let events = try Self.events(trace.runsDirectory.appending(path: "\(id)-refunds-v2/trace.jsonl"))
        let hold = try #require(events.first { $0["type"]?.string == "hold" })
        #expect(hold["reason"]?.string == HoldReason.planApproval.rawValue)
        #expect(hold["requestId"]?.int != nil)
        let resolved = try #require(events.first { $0["type"]?.string == "hold_resolved" })
        #expect(resolved["decision"]?.string == "rejected")
        #expect(resolved["response"]?.string == "Split the UI out")
        #expect(resolved["waitMS"]?.int != nil)
        #expect(events.contains { $0["type"]?.string == "run_finished" && $0["status"]?.string == "cancelled" })
    }

    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-debug-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func agent(id: Int64, name: String, runId: Int64? = nil) -> Agent {
        Agent(id: id, projectId: 1, runId: runId, role: "claude-code", name: name, status: .idle, createdAt: .now, updatedAt: .now)
    }

    static func events(_ file: URL) throws -> [JSONValue] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
    }

    static func folder(_ url: URL, bytes: Int, modified: Date) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appending(path: "trace.jsonl")
        try Data(repeating: 65, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
#endif
