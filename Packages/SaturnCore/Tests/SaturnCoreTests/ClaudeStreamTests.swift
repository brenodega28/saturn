import Foundation
import Testing
@testable import SaturnCore

extension TranscriptEntry {
    var withoutTimes: TranscriptEntry {
        var entry = self
        entry.isStreaming = false
        switch content {
        case .thinking(var block):
            block.startedAt = nil
            block.finishedAt = nil
            entry.content = .thinking(block)
        case .tool(var tool):
            tool.startedAt = nil
            tool.finishedAt = nil
            entry.content = .tool(tool)
        default:
            break
        }
        return entry
    }
}

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

    static let streamed = [
        #"{"type":"system","subtype":"init","cwd":"/repo/.crew/dev","session_id":"s-1","tools":["Bash"],"model":"claude-haiku-5-5","permissionMode":"dontAsk","claude_code_version":"2.1.309"}"#,
        #"{"type":"user","message":{"role":"user","content":"Say hi, then list files"}}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":1}}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e2"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants "}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e3"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a greeting."}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e4"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e5"}"#,
        #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":6,"session_id":"s-1"}"#,
        #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"The user wants a greeting.","signature":"EqQB"}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e6"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e7"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e8"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there!"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e9"}"#,
        #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello there!"}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":1},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e10"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e11"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e12"}"#,
        #"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":2},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e13"}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e14"}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e15"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"a.txt","is_error":false}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[]}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e16"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e17"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Only a"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e18"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":".txt"}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e19"}"#,
        #"{"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"text","text":"Only a.txt."}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e20"}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e21"}"#,
        #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s-1","parent_tool_use_id":null,"uuid":"e22"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":900,"result":"Only a.txt.","session_id":"s-1","total_cost_usd":0.002,"usage":{"input_tokens":3,"output_tokens":47}}"#,
    ]

    static func applyLive(_ lines: [String], to transcript: inout Transcript, from start: Date = Date(timeIntervalSince1970: 1_000)) {
        for (offset, line) in lines.enumerated() {
            for event in ClaudeEvent.parse(line: line) {
                transcript.apply(event, now: start.addingTimeInterval(TimeInterval(offset)))
            }
        }
    }

    @Test func parsesStreamEvents() {
        #expect(ClaudeEvent.parse(line: Self.streamed[2]) == [.messageStarted])
        #expect(ClaudeEvent.parse(line: Self.streamed[3]) == [.thinkingStarted(index: 0)])
        #expect(ClaudeEvent.parse(line: Self.streamed[4]) == [.thinkingDelta(index: 0, text: "The user wants ")])
        #expect(ClaudeEvent.parse(line: Self.streamed[6]).isEmpty)
        #expect(ClaudeEvent.parse(line: Self.streamed[7]) == [.thinkingTokens(6)])
        #expect(ClaudeEvent.parse(line: Self.streamed[8]) == [.thinking("The user wants a greeting.")])
        #expect(ClaudeEvent.parse(line: Self.streamed[9]) == [.blockStopped(index: 0)])
        #expect(ClaudeEvent.parse(line: Self.streamed[10]).isEmpty)
        #expect(ClaudeEvent.parse(line: Self.streamed[11]) == [.assistantTextDelta(index: 1, text: "Hello")])
        #expect(ClaudeEvent.parse(line: Self.streamed[15]).isEmpty)
        #expect(ClaudeEvent.parse(line: Self.streamed[16]).isEmpty)
        #expect(ClaudeEvent.parse(line: Self.streamed[19]).isEmpty)
        #expect(ClaudeEvent.parse(line: Self.streamed[20]) == [.messageStopped])
        #expect(ClaudeEvent.parse(line: Self.recorded[1]) == [.thinkingTokens(50)])
        #expect(ClaudeEvent.parse(line: Self.recorded[2]).first == .thinking(""))

        let partial = Self.streamed.flatMap(ClaudeEvent.parse(line:)).filter(\.isPartial)
        #expect(partial.count == 15)
        #expect(!ClaudeEvent.thinkingTokens(1).isPartial)
        #expect(!ClaudeEvent.thinking("x").isPartial)
    }

    @Test func streamedBlocksReconcileWithTheirFinalMessages() {
        var transcript = Transcript()
        Self.applyLive(Array(Self.streamed.prefix(13)), to: &transcript)

        let live = transcript.liveEntry
        #expect(live?.content == .assistant("Hello there!"))
        #expect(live?.isStreaming == true)
        let streamingID = live?.id
        let countWhileStreaming = transcript.entries.count

        Self.applyLive(Array(Self.streamed.dropFirst(13)), to: &transcript, from: Date(timeIntervalSince1970: 2_000))

        #expect(transcript.liveEntry == nil)
        #expect(transcript.entries.allSatisfy { !$0.isStreaming })
        #expect(transcript.entries[countWhileStreaming - 1].id == streamingID)
        #expect(transcript.entries[countWhileStreaming - 1].content == .assistant("Hello there!"))
        #expect(transcript.entries.map(\.withoutTimes.content) == [
            .user("Say hi, then list files"),
            .thinking(ThinkingBlock(text: "The user wants a greeting.", isFinished: true, estimatedTokens: 6)),
            .assistant("Hello there!"),
            .tool(ToolActivity(id: "toolu_1", name: "Bash", input: .object(["command": .string("ls")]), result: "a.txt", isError: false)),
            .assistant("Only a.txt."),
            .turnFinished(TurnResult(subtype: "success", isError: false, text: "Only a.txt.", totalCostUSD: 0.002, usage: TokenUsage(input: 3, output: 47), permissionDenials: [], durationMS: 900)),
        ])
        #expect(transcript.entries.map(\.id) == Array(0..<6))
    }

    @Test func finalTextReplacesStreamedText() {
        var transcript = Transcript()
        transcript.apply(.messageStarted)
        transcript.apply(.assistantTextDelta(index: 0, text: "Partial"))
        transcript.apply(.assistantTextDelta(index: 0, text: " guess"))
        #expect(transcript.liveEntry?.content == .assistant("Partial guess"))

        transcript.apply(.assistantText("Final answer"))
        transcript.apply(.blockStopped(index: 0))

        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].content == .assistant("Final answer"))
        #expect(!transcript.entries[0].isStreaming)
    }

    @Test func thinkingStreamsThenFinishesWithTiming() throws {
        var transcript = Transcript()
        let start = Date(timeIntervalSince1970: 100)
        transcript.apply(.messageStarted, now: start)
        transcript.apply(.thinkingStarted(index: 0), now: start)
        transcript.apply(.thinkingDelta(index: 0, text: "Hmm"), now: start.addingTimeInterval(1))
        transcript.apply(.thinkingTokens(12), now: start.addingTimeInterval(2))

        guard case .thinking(let streaming) = try #require(transcript.liveEntry).content else {
            Issue.record("expected a live thinking entry")
            return
        }
        #expect(streaming == ThinkingBlock(text: "Hmm", isFinished: false, estimatedTokens: 12, startedAt: start))

        transcript.apply(.blockStopped(index: 0), now: start.addingTimeInterval(3))

        #expect(transcript.liveEntry == nil)
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].content == .thinking(ThinkingBlock(
            text: "Hmm", isFinished: true, estimatedTokens: 12, startedAt: start, finishedAt: start.addingTimeInterval(3)
        )))
    }

    @Test func replayWithoutStreamLinesMatchesTheLiveTranscript() {
        var live = Transcript()
        Self.applyLive(Self.streamed, to: &live)
        let logged = Self.streamed.filter { !ClaudeEvent.parse(line: $0).allSatisfy(\.isPartial) }
        let replayed = Transcript(lines: logged)

        #expect(logged.count == 9)
        #expect(replayed.entries.map(\.withoutTimes) == live.entries.map(\.withoutTimes))
        #expect(Transcript(lines: Self.streamed).entries.map(\.withoutTimes) == live.entries.map(\.withoutTimes))
    }

    @Test func recordedThinkingTokensBecomeOneFinishedThinkingEntry() {
        let transcript = Transcript(lines: Self.recorded)
        let thinking = transcript.entries.compactMap { entry -> ThinkingBlock? in
            if case .thinking(let block) = entry.content { return block }
            return nil
        }
        #expect(thinking == [ThinkingBlock(text: "", isFinished: true, estimatedTokens: 50)])
        #expect(transcript.entries.allSatisfy { !$0.isStreaming })
    }

    @Test func interruptingMidStreamClosesTheStreamingEntry() {
        var transcript = Transcript()
        let start = Date(timeIntervalSince1970: 500)
        transcript.apply(.messageStarted, now: start)
        transcript.apply(.thinkingStarted(index: 0), now: start)
        transcript.apply(.thinkingDelta(index: 0, text: "Let me"), now: start)
        transcript.apply(.thinking("Let me"), now: start)
        transcript.apply(.blockStopped(index: 0), now: start)
        transcript.apply(.assistantTextDelta(index: 1, text: "Half a"), now: start)
        #expect(transcript.liveEntry?.content == .assistant("Half a"))

        transcript.apply(.userMessage("[Request interrupted by user]"), now: start.addingTimeInterval(1))

        #expect(transcript.liveEntry == nil)
        #expect(transcript.entries.allSatisfy { !$0.isStreaming })
        #expect(transcript.entries.map(\.content).suffix(2) == [.assistant("Half a"), .interrupted])
    }

    @Test func turnEndClosesOpenThinking() {
        var transcript = Transcript()
        let start = Date(timeIntervalSince1970: 700)
        transcript.apply(.thinkingStarted(index: 0), now: start)
        transcript.apply(.turnCompleted(TurnResult(subtype: "error_during_execution", isError: true, text: nil, totalCostUSD: 0, usage: TokenUsage(), permissionDenials: [], durationMS: 0)), now: start.addingTimeInterval(4))

        #expect(transcript.liveEntry == nil)
        #expect(transcript.entries[0].content == .thinking(ThinkingBlock(isFinished: true, startedAt: start, finishedAt: start.addingTimeInterval(4))))
    }

    @Test func toolsCarryTimingLiveButNotOnReplay() throws {
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt","is_error":false}]}}"#
        let started = Date(timeIntervalSince1970: 10)
        let finished = Date(timeIntervalSince1970: 13)

        var live = Transcript()
        ClaudeEvent.parse(line: call).forEach { live.apply($0, now: started) }
        #expect(live.activeTool?.startedAt == started)
        #expect(live.activeTool?.finishedAt == nil)
        ClaudeEvent.parse(line: result).forEach { live.apply($0, now: finished) }

        guard case .tool(let tool) = try #require(live.entries.first).content else {
            Issue.record("expected a tool entry")
            return
        }
        #expect(tool.startedAt == started)
        #expect(tool.finishedAt == finished)
        #expect(live.activeTool == nil)

        guard case .tool(let replayed) = try #require(Transcript(lines: [call, result]).entries.first).content else {
            Issue.record("expected a replayed tool entry")
            return
        }
        #expect(replayed.startedAt == nil)
        #expect(replayed.finishedAt == nil)
        #expect(replayed.result == "a.txt")
    }

    @Test func toolsClosedAtTurnEndGetAFinishTime() throws {
        var transcript = Transcript(lines: [Self.recorded[0], Self.recorded[5]])
        let paused = Date(timeIntervalSince1970: 50)
        transcript.apply(.notice(.paused, detail: nil), now: paused)

        guard case .tool(let tool) = try #require(transcript.entries.first).content else {
            Issue.record("expected a tool entry")
            return
        }
        #expect(tool.startedAt == nil)
        #expect(tool.finishedAt == paused)
    }

    static let subagent = [
        #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_task","name":"Task","input":{"description":"Find the config","prompt":"Find where the config is loaded","subagent_type":"Explore"}}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Find where the config is loaded"}]},"parent_tool_use_id":"toolu_task","session_id":"s-1"}"#,
        #"{"type":"assistant","message":{"id":"msg_sub","content":[{"type":"tool_use","id":"toolu_sub_1","name":"Grep","input":{"pattern":"loadConfig"}}]},"parent_tool_use_id":"toolu_task","session_id":"s-1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_sub_1","type":"tool_result","content":"Sources/Config.swift"}]},"parent_tool_use_id":"toolu_task","session_id":"s-1"}"#,
        #"{"type":"assistant","message":{"id":"msg_sub2","content":[{"type":"tool_use","id":"toolu_sub_2","name":"Read","input":{"file_path":"/repo/Sources/Config.swift"}}]},"parent_tool_use_id":"toolu_task","session_id":"s-1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_sub_2","type":"tool_result","content":"struct Config {}"}]},"parent_tool_use_id":"toolu_task","session_id":"s-1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_task","type":"tool_result","content":[{"type":"text","text":"Config is loaded in Sources/Config.swift"}]}]},"parent_tool_use_id":null,"session_id":"s-1"}"#,
    ]

    @Test func subagentToolCallsCarryTheirTaskAsParent() {
        let calls = Self.subagent.flatMap(ClaudeEvent.parse(line:)).compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        #expect(calls.map(\.id) == ["toolu_task", "toolu_sub_1", "toolu_sub_2"])
        #expect(calls.map(\.parentToolUseID) == [nil, "toolu_task", "toolu_task"])

        var live = Transcript()
        Self.applyLive(Self.subagent, to: &live)
        let tools = live.entries.compactMap { entry -> ToolActivity? in
            if case .tool(let tool) = entry.content { return tool }
            return nil
        }
        #expect(tools.map(\.parentToolUseID) == [nil, "toolu_task", "toolu_task"])
        #expect(tools.map(\.isFinished) == [true, true, true])
        #expect(tools[0].result == "Config is loaded in Sources/Config.swift")
        #expect(Transcript(lines: Self.subagent).entries.map(\.withoutTimes) == live.entries.map(\.withoutTimes))
    }

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

        #expect(arguments.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]))
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
        #expect(try value(of: "--tools", in: launch(readOnly: true, extraAllowedTools: ["WebFetch", "WebSearch", "mcp__saturn__ask_human"])) == "Bash,Skill,Read,Glob,Grep,WebFetch,WebSearch")
        #expect(try value(of: "--tools", in: launch(readOnly: true, extraAllowedTools: AgentPermissions.artifactTools)) == "Bash,Skill,Read,Glob,Grep,Artifact,ArtifactData,ArtifactComments,ArtifactCheck")

        let settings = try value(of: "--settings", in: launch(readOnly: false))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        #expect(decoded["disableBundledSkills"] as? Bool == true)
        #expect(try value(of: "--setting-sources", in: launch(readOnly: false)) == "project")
    }

    @Test func onlyLaunchesThatMayReadArtifactsTurnOnClaudeArtifacts() {
        func environment(extraAllowedTools: [String]) -> [String: String] {
            ClaudeLaunch(
                executable: URL(fileURLWithPath: "/bin/claude"),
                worktree: URL(fileURLWithPath: "/repo"),
                session: .new("s-1"),
                model: "sonnet",
                systemPrompt: "prompt",
                environment: ["PATH": "/usr/bin"],
                readOnly: true,
                extraAllowedTools: extraAllowedTools
            ).processEnvironment
        }

        #expect(environment(extraAllowedTools: AgentPermissions.artifactTools) == ["PATH": "/usr/bin", "CLAUDE_CODE_ARTIFACT": "1"])
        #expect(environment(extraAllowedTools: AgentPermissions.webTools) == ["PATH": "/usr/bin"])
    }
}
