import Foundation
import Testing
@testable import EnsembleCore

@Suite struct ClaudeStreamTests {
    static let recorded = [
        #"{"type":"system","subtype":"init","cwd":"/repo/.crew/dev","session_id":"s-1","tools":["Bash"],"model":"claude-haiku-5-5","permissionMode":"dontAsk","claude_code_version":"2.1.309"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#,
        #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls","description":"List files"},"caller":{"type":"direct"}}]}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        #"{"type":"user","message":{"content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"a.txt","is_error":false}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"rm a.txt"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"Permission to use Bash has been denied","is_error":true,"tool_use_id":"toolu_2"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_3","name":"Edit","input":{"file_path":"/repo/.crew/dev/a.txt","old_string":"hi","new_string":"hi\nbye"}}]}}"#,
        #"{"type":"user","message":{"content":[{"tool_use_id":"toolu_3","type":"tool_result","content":[{"type":"text","text":"The file has been updated."}]}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1045,"num_turns":4,"result":"Done.","stop_reason":"end_turn","session_id":"s-1","total_cost_usd":0.0058,"usage":{"input_tokens":8,"cache_creation_input_tokens":21565,"cache_read_input_tokens":101388,"output_tokens":1362},"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_2","tool_input":{"command":"rm a.txt"}}]}"#,
        #"{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"total_cost_usd":0.0071,"usage":{"input_tokens":2,"output_tokens":99}}"#,
        "not json",
    ]

    @Test func parsesRecordedStream() {
        let events = Self.recorded.flatMap(ClaudeEvent.parse(line:))

        #expect(events.first == .sessionStarted(SessionInfo(sessionID: "s-1", model: "claude-haiku-5-5", cwd: "/repo/.crew/dev", version: "2.1.309")))
        #expect(events.contains(.toolResult(ToolResult(toolUseID: "toolu_2", content: "Permission to use Bash has been denied", isError: true))))
        #expect(events.contains(.toolResult(ToolResult(toolUseID: "toolu_3", content: "The file has been updated.", isError: false))))

        let results = events.compactMap { event -> TurnResult? in
            if case .turnCompleted(let result) = event { return result }
            return nil
        }
        #expect(results.count == 2)
        #expect(results[0].usage == TokenUsage(input: 8, output: 1362, cacheRead: 101_388, cacheWrite: 21_565))
        #expect(results[0].permissionDenials == ["Bash"])
        #expect(results[0].totalCostUSD == 0.0058)
        #expect(!results[0].wasInterrupted)
        #expect(results[1].wasInterrupted)
        #expect(results[1].text == nil)
    }

    @Test func buildsTranscriptWithToolResultsAttached() throws {
        let transcript = Transcript(lines: Self.recorded)

        #expect(transcript.session?.sessionID == "s-1")
        let tools = transcript.entries.compactMap { entry -> ToolActivity? in
            if case .tool(let tool) = entry.content { return tool }
            return nil
        }
        #expect(tools.map(\.name) == ["Bash", "Bash", "Edit"])
        #expect(tools.map(\.isError) == [false, true, false])
        #expect(tools[0].target(relativeTo: transcript.session?.cwd) == "ls")
        #expect(tools[2].target(relativeTo: transcript.session?.cwd) == "a.txt")
        #expect(tools[2].diff == [
            DiffLine(kind: .context, text: "hi"),
            DiffLine(kind: .added, text: "bye"),
        ])
        #expect(transcript.activeTool == nil)
        if case .interrupted = transcript.entries[transcript.entries.count - 2].content {} else {
            Issue.record("expected an interrupted entry before the last result")
        }
    }

    @Test func unfinishedToolsCloseWhenTheTurnEnds() {
        var transcript = Transcript(lines: [Self.recorded[0], Self.recorded[5]])
        #expect(transcript.activeTool?.id == "toolu_2")

        transcript.apply(.notice(.paused, detail: nil))

        #expect(transcript.activeTool == nil)
    }

    @Test func encodesInputLines() throws {
        let user = try #require(JSONValue.parse(ClaudeEvent.userLine("Fix \"it\"\nnow")))
        #expect(user["type"]?.string == "user")
        #expect(user["message"]?["content"]?.string == "Fix \"it\"\nnow")

        let interrupt = try #require(JSONValue.parse(ClaudeEvent.interruptLine(requestID: "r9")))
        #expect(interrupt["request"]?["subtype"]?.string == "interrupt")
        #expect(interrupt["request_id"]?.string == "r9")

        #expect(ClaudeEvent.parse(line: ClaudeEvent.noticeLine(.paused, detail: "by you")) == [.notice(.paused, detail: "by you")])
    }

    @Test func userLinesWithImagesRoundTripThroughParse() throws {
        let image = ChatAttachment.image(id: UUID(), mediaType: "image/jpeg", fileName: "a.jpg", data: Data("jpeg".utf8))
        let line = ClaudeEvent.userLine("Fix \"it\"\nnow", images: [image])
        let user = try #require(JSONValue.parse(line))
        #expect(user["message"]?["content"]?.array?.compactMap { $0["source"]?["media_type"]?.string } == ["image/jpeg"])
        #expect(ClaudeEvent.parse(line: line) == [.userMessage("Fix \"it\"\nnow\n[image]")])
        #expect(ClaudeEvent.parse(line: ClaudeEvent.userLine("Fix \"it\"\nnow")) == [.userMessage("Fix \"it\"\nnow")])
    }

    @Test func diffsLines() {
        #expect(LineDiff.compute(old: "a\nb\nc", new: "a\nB\nc") == [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
            DiffLine(kind: .context, text: "c"),
        ])
        #expect(LineDiff.compute(old: "", new: "x").map(\.kind) == [.added])
        #expect(LineDiff.compute(old: "x", new: "").map(\.kind) == [.removed])
    }

    @Test func launchArgumentsScopeWritesToTheWorktree() {
        let launch = ClaudeLaunch(
            executable: URL(fileURLWithPath: "/bin/claude"),
            worktree: URL(fileURLWithPath: "/repo/.crew/dev"),
            session: .resume("s-1"),
            model: "sonnet",
            systemPrompt: "prompt",
            environment: [:]
        )
        let arguments = launch.arguments

        #expect(arguments.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]))
        #expect(arguments.contains("--resume"))
        #expect(!arguments.contains("--session-id"))
        #expect(arguments.contains("Edit(//repo/.crew/dev/**)"))
        #expect(arguments.contains("Bash(git commit:*)"))
        #expect(!arguments.contains { $0.hasPrefix("Bash(git push") })
        #expect(!arguments.contains("Bash"))
        #expect(!arguments.contains("Edit"))
    }

    @Test func launchesOfferOnlyTheBuiltInToolsTheAgentNeedsAndProjectSkills() throws {
        func launch(readOnly: Bool, extraAllowedTools: [String] = []) -> [String] {
            ClaudeLaunch(
                executable: URL(fileURLWithPath: "/bin/claude"),
                worktree: URL(fileURLWithPath: "/repo/.crew/dev"),
                session: .new("s-1"),
                model: "sonnet",
                systemPrompt: "prompt",
                environment: [:],
                readOnly: readOnly,
                extraAllowedTools: extraAllowedTools
            ).arguments
        }
        func value(of flag: String, in arguments: [String]) throws -> String {
            arguments[try #require(arguments.firstIndex(of: flag)) + 1]
        }

        #expect(try value(of: "--tools", in: launch(readOnly: false)) == "Bash,Skill,Read,Glob,Grep,Edit,MultiEdit,Write,NotebookEdit")
        #expect(try value(of: "--tools", in: launch(readOnly: true)) == "Bash,Skill,Read,Glob,Grep")
        #expect(try value(of: "--tools", in: launch(readOnly: true, extraAllowedTools: ["WebFetch", "WebSearch", "mcp__ensemble__ask_human"])) == "Bash,Skill,Read,Glob,Grep,WebFetch,WebSearch")

        let settings = try value(of: "--settings", in: launch(readOnly: false))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect(decoded["disableBundledSkills"] as? Bool == true)
        #expect(try value(of: "--setting-sources", in: launch(readOnly: false)) == "project")
    }
}
