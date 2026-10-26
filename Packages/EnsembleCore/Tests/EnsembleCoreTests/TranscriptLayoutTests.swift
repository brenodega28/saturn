import Foundation
import Testing
@testable import EnsembleCore

@Suite struct TranscriptLayoutTests {
    private func tool(_ name: String, _ input: [String: JSONValue] = [:], result: String? = "ok", isError: Bool = false) -> TranscriptEntry.Content {
        .tool(ToolActivity(id: UUID().uuidString, name: name, input: .object(input), result: result, isError: isError))
    }

    private func entries(_ contents: [TranscriptEntry.Content]) -> [TranscriptEntry] {
        contents.enumerated().map { TranscriptEntry(id: $0.offset, content: $0.element) }
    }

    private func shape(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case .entry(let entry):
                switch entry.content {
                case .tool(let tool): "tool:\(tool.name)"
                case .assistant: "assistant"
                case .thinking: "thinking"
                default: "other"
                }
            case .group(let group): "group:\(group.summary)"
            }
        }
    }

    @Test func groupsConsecutiveFinishedToolsOfTheSameKind() {
        let items = TranscriptLayout.items(entries([
            tool("Read", ["file_path": .string("/a")]),
            tool("Read", ["file_path": .string("/b")]),
            tool("Read", ["file_path": .string("/a")]),
            tool("Bash"),
            tool("Bash"),
            tool("Bash"),
            .assistant("Done"),
            tool("Grep"),
            tool("Glob"),
        ]))

        #expect(shape(items) == ["group:Read 2 files", "group:Ran 3 commands", "assistant", "group:Searched 2 times"])
        if case .group(let group) = items[0] { #expect(group.id == 0) }
        if case .group(let group) = items[1] { #expect(group.id == 3) }
    }

    @Test func leavesSinglesRunningToolsAndSubagentsUngrouped() {
        let items = TranscriptLayout.items(entries([
            tool("Read", ["file_path": .string("/a")]),
            tool("Edit"),
            tool("Edit", result: nil),
            tool("Task"),
            tool("Task"),
        ]))

        #expect(shape(items) == ["tool:Read", "tool:Edit", "tool:Edit", "tool:Task", "tool:Task"])
    }

    @Test func emptyFinishedThinkingDoesNotBreakAGroup() {
        let items = TranscriptLayout.items(entries([
            tool("Bash"),
            .thinking(ThinkingBlock(text: "", isFinished: true)),
            tool("Bash"),
            .thinking(ThinkingBlock(text: "Hmm", isFinished: true)),
            tool("Bash"),
        ]))

        #expect(shape(items) == ["group:Ran 2 commands", "thinking", "tool:Bash"])
    }

    @Test func countsFailuresInAGroup() {
        let items = TranscriptLayout.items(entries([tool("Bash"), tool("Bash", result: "Exit code 1", isError: true)]))

        guard case .group(let group) = items.first else { Issue.record("expected a group"); return }
        #expect(group.failureCount == 1)
    }

    @Test func appendsALiveEntryNotYetInTheList() {
        let list = entries([.user("hi")])
        let live = TranscriptEntry(id: 1, content: .assistant("Partial"), isStreaming: true)

        #expect(shape(TranscriptLayout.items(list, live: live)) == ["other", "assistant"])
        #expect(shape(TranscriptLayout.items(list + [live], live: live)) == ["other", "assistant"])
    }

    @Test func reportsWhatTheSessionIsDoingNow() {
        let running = tool("Bash", ["command": .string("make")], result: nil)
        #expect(TranscriptLayout.activity(entries([.user("go")])) == .working)
        #expect(TranscriptLayout.activity(entries([.user("go"), .assistant("Wri")]).map {
            var entry = $0
            entry.isStreaming = $0.id == 1
            return entry
        }) == .replying("Wri"))
        let thinking = ThinkingBlock(text: "plan", isFinished: false)
        #expect(TranscriptLayout.activity(entries([.user("go"), .thinking(thinking)])) == .thinking(thinking))
        guard case .tool(let active) = TranscriptLayout.activity(entries([.user("go"), running, .assistant("meanwhile")])) else {
            Issue.record("expected the running tool")
            return
        }
        #expect(active.name == "Bash")
    }

    @Test func readsTheLatestTodoList() {
        let first: JSONValue = .object(["todos": .array([.object(["content": .string("Old"), "status": .string("pending")])])])
        let second: JSONValue = .object(["todos": .array([
            .object(["content": .string("Build"), "status": .string("completed"), "activeForm": .string("Building")]),
            .object(["content": .string("Test"), "status": .string("in_progress")]),
            .object(["content": .string("Ship"), "status": .string("weird")]),
        ])])
        let list = entries([
            .tool(ToolActivity(id: "1", name: "TodoWrite", input: first, result: "ok", isError: false)),
            .tool(ToolActivity(id: "2", name: "TodoWrite", input: second, result: nil, isError: false)),
        ])

        #expect(TranscriptLayout.latestTodos(in: list) == [
            TodoItem(content: "Build", activeForm: "Building", status: .completed),
            TodoItem(content: "Test", status: .inProgress),
            TodoItem(content: "Ship", status: .pending),
        ])
        #expect(TranscriptLayout.latestTodos(in: entries([.user("x")])).isEmpty)
    }

    @Test func summarizesShellResults() {
        let failed = ToolActivity(id: "1", name: "Bash", input: .null, result: "Exit code 2\nboom", isError: true)
        let passed = ToolActivity(id: "2", name: "Bash", input: .null, result: "fine", isError: false)
        let denied = ToolActivity(id: "3", name: "Bash", input: .null, result: "Permission denied", isError: true)

        #expect(ToolResultSummary.exitCode(of: failed) == 2)
        #expect(ToolResultSummary.shellOutput(of: failed) == "boom")
        #expect(ToolResultSummary.exitCode(of: passed) == 0)
        #expect(ToolResultSummary.exitCode(of: denied) == nil)
    }

    @Test func extractsPathsAndCountsFromSearchResults() {
        let files = ToolActivity(id: "1", name: "Grep", input: .object(["pattern": .string("x")]), result: "Found 2 files\n/repo/a.swift\n/repo/b.swift", isError: false)
        let content = ToolActivity(id: "2", name: "Grep", input: .object(["output_mode": .string("content")]), result: "/repo/a.swift:3:let x\n/repo/a.swift:9:x()\nsrc/b.swift:1:x", isError: false)
        let glob = ToolActivity(id: "3", name: "Glob", input: .null, result: "/repo/one.md\n/repo/two md.md", isError: false)
        let none = ToolActivity(id: "4", name: "Glob", input: .null, result: "No files found", isError: false)
        let count = ToolActivity(id: "5", name: "Grep", input: .object(["output_mode": .string("count")]), result: "/a:3\n/b:4", isError: false)

        #expect(ToolResultSummary.paths(in: files) == ["/repo/a.swift", "/repo/b.swift"])
        #expect(ToolResultSummary.countLabel(for: files) == "2 files")
        #expect(ToolResultSummary.paths(in: content) == ["/repo/a.swift", "src/b.swift"])
        #expect(ToolResultSummary.countLabel(for: content) == "3 lines")
        #expect(ToolResultSummary.paths(in: glob) == ["/repo/one.md", "/repo/two md.md"])
        #expect(ToolResultSummary.countLabel(for: glob) == "2 files")
        #expect(ToolResultSummary.countLabel(for: none) == "No files")
        #expect(ToolResultSummary.countLabel(for: count) == "7 matches")
    }

    @Test func countsLinesRead() {
        let read = ToolActivity(id: "1", name: "Read", input: .null, result: "     1→import A\n     2→\n     3→let b", isError: false)

        #expect(ToolResultSummary.countLabel(for: read) == "3 lines")
    }

    @Test func formatsElapsedTimeAndTokens() {
        #expect(LiveFormat.elapsed(4.7) == "4s")
        #expect(LiveFormat.elapsed(65) == "1m 05s")
        #expect(LiveFormat.elapsed(3725) == "1h 02m")
        #expect(LiveFormat.tokens(1) == "1 token")
        #expect(LiveFormat.tokens(950) == "950 tokens")
        #expect(LiveFormat.tokens(1000) == "1k tokens")
        #expect(LiveFormat.tokens(1250) == "1.2k tokens")
        #expect(LiveFormat.tokens(12_600) == "13k tokens")
    }

    @Test func locatesFilesInTheMostSpecificRoot() {
        let roots = ["/repo", "/repo/.crew/dev", "/other"]

        #expect(CodeFileLocator.locate("/repo/.crew/dev/src/a.swift", cwd: nil, roots: roots) == CodeFileLocation(rootIndex: 1, relativePath: "src/a.swift"))
        #expect(CodeFileLocator.locate("/private/repo/README.md", cwd: nil, roots: roots) == CodeFileLocation(rootIndex: 0, relativePath: "README.md"))
        #expect(CodeFileLocator.locate("src/b.swift", cwd: "/repo/.crew/dev", roots: roots) == CodeFileLocation(rootIndex: 1, relativePath: "src/b.swift"))
        #expect(CodeFileLocator.locate("../x/y", cwd: "/other/sub", roots: roots) == CodeFileLocation(rootIndex: 2, relativePath: "x/y"))
        #expect(CodeFileLocator.locate("/elsewhere/a", cwd: nil, roots: roots) == nil)
        #expect(CodeFileLocator.locate("rel", cwd: nil, roots: roots) == nil)
        #expect(CodeFileLocator.locate("/repo", cwd: nil, roots: roots) == nil)
    }

    @Test func showsPathsRelativeToTheWorkingDirectory() {
        #expect(CodeFileLocator.displayPath("/private/repo/src/a.swift", root: "/repo") == "src/a.swift")
        #expect(CodeFileLocator.displayPath("/elsewhere/a", root: "/repo") == "/elsewhere/a")
        #expect(CodeFileLocator.displayPath("src/a", root: "/repo") == "src/a")
        #expect(CodeFileLocator.displayPath("/repo/a", root: nil) == "/repo/a")
    }
}
