import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SATURN_REAL_CLAUDE"] == "1"), .serialized)
struct RealClaudeHookTests {
    static let scriptedModel = #"""
    import http.server, json, re, sys
    log = sys.argv[2]
    def events(blocks, stop):
        out = [("message_start", {"type": "message_start", "message": {"id": "msg_stub", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5", "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})]
        for index, block in enumerate(blocks):
            if block["type"] == "tool_use":
                out.append(("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}}))
                out.append(("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}))
            else:
                out.append(("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}))
                out.append(("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": block["text"]}}))
            out.append(("content_block_stop", {"type": "content_block_stop", "index": index}))
        out.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}}))
        out.append(("message_stop", {"type": "message_stop"}))
        return "".join("event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in out).encode()
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            if "/count_tokens" in self.path:
                return self.reply(b'{"input_tokens": 10}', "application/json")
            if not body.get("tools"):
                return self.reply(events([{"type": "text", "text": "ok"}], "end_turn"), "text/event-stream")
            text = json.dumps(body)
            with open(log, "a") as handle:
                handle.write(text + "\n")
            system = json.dumps(body.get("system", ""))
            worktree = re.search(r"git worktree at (/\S+?) on branch", system).group(1)
            if "toolu_edit" in text:
                return self.reply(events([{"type": "text", "text": "Done."}], "end_turn"), "text/event-stream")
            if "toolu_read" not in text:
                read = {"type": "tool_use", "id": "toolu_read", "name": "Read", "input": {"file_path": worktree + "/README.md"}}
                return self.reply(events([read], "tool_use"), "text/event-stream")
            edit = {"type": "tool_use", "id": "toolu_edit", "name": "Edit", "input": {"file_path": worktree + "/README.md", "old_string": "hello", "new_string": "goodbye"}}
            return self.reply(events([edit], "tool_use"), "text/event-stream")
        def reply(self, data, kind):
            self.send_response(200)
            self.send_header("content-type", kind)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *args):
            pass
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
    """#

    @Test(.timeLimit(.minutes(3))) func realClaudeHonorsSaturnHooks() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "scripted-model-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let port = Int.random(in: 30000...39999)
        let model = Process()
        model.executableURL = URL(filePath: "/usr/bin/python3")
        model.arguments = ["-I", "-c", Self.scriptedModel, String(port), log.path]
        try model.run()
        defer { model.terminate() }
        try await Task.sleep(for: .milliseconds(800))

        let api = RealClaudeAPIErrorTests()
        let harness = try await api.makeHarness(stubURL: "http://127.0.0.1:\(port)")
        defer { harness.cleanUp() }
        harness.runtime.gitProvider = { harness.repo.git }
        try ProjectConfigLoader.write(ChecksConfig(
            checks: [CheckDefinition(name: "unit", kind: .test, command: "echo 'FAILED test_refund_cap'; exit 1")],
            protectedPaths: ["README.md"]
        ), repository: harness.repo.root)
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        try await driver.ensureServer()

        let session = try await harness.spawn()
        try "hello\nchanged\n".write(to: try #require(session.agent.worktreeURL).appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try await waitUntil(timeout: .seconds(120)) { session.agent.status == .idle || session.agent.status == .failed }

        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let readme = try String(contentsOf: try #require(session.agent.worktreeURL).appending(path: "README.md"), encoding: .utf8)
        #expect(!readme.contains("goodbye"))
        #expect(requests.contains { $0.contains("README.md is a protected file") })
        #expect(requests.contains { $0.contains("Don’t finish yet") || $0.contains("Don\\u2019t finish yet") })
        #expect(requests.count == 5)
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SATURN_REAL_CLAUDE"] == "1"), .serialized)
struct RealClaudePermissionTests {
    static let scriptedModel = #"""
    import http.server, json, sys
    log = sys.argv[2]
    command = sys.argv[3] if len(sys.argv) > 3 else "git push --dry-run origin HEAD"
    def events(blocks, stop):
        out = [("message_start", {"type": "message_start", "message": {"id": "msg", "type": "message", "role": "assistant", "model": "claude-sonnet-4-5", "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}})]
        for index, block in enumerate(blocks):
            if block["type"] == "tool_use":
                out.append(("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}}))
                out.append(("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}))
            else:
                out.append(("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}))
                out.append(("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": block["text"]}}))
            out.append(("content_block_stop", {"type": "content_block_stop", "index": index}))
        out.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}))
        out.append(("message_stop", {"type": "message_stop"}))
        return "".join("event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in out).encode()
    def push(tool_id):
        return {"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": command}}
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            if "/count_tokens" in self.path:
                return self.reply(b'{"input_tokens": 1}', "application/json")
            if not body.get("tools"):
                return self.reply(events([{"type": "text", "text": "ok"}], "end_turn"), "text/event-stream")
            text = json.dumps(body)
            with open(log, "a") as handle:
                handle.write(text + "\n")
            if "The user allowed you" in text and "toolu_second" not in text:
                return self.reply(events([push("toolu_second")], "tool_use"), "text/event-stream")
            if "toolu_first" not in text:
                return self.reply(events([push("toolu_first")], "tool_use"), "text/event-stream")
            return self.reply(events([{"type": "text", "text": "Done."}], "end_turn"), "text/event-stream")
        def reply(self, data, kind):
            self.send_response(200)
            self.send_header("content-type", kind)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *args):
            pass
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
    """#

    func startModel(log: URL, command: String? = nil) async throws -> (Process, Int) {
        let port = Int.random(in: 40000...49999)
        let model = Process()
        model.executableURL = URL(filePath: "/usr/bin/python3")
        model.arguments = ["-I", "-c", Self.scriptedModel, String(port), log.path] + (command.map { [$0] } ?? [])
        try model.run()
        try await Task.sleep(for: .milliseconds(800))
        return (model, port)
    }

    @Test(.timeLimit(.minutes(3))) func aChainedEverydayCommandOffTheAllowListRunsWithoutAsking() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "permission-model-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let (model, port) = try await startModel(log: log, command: "uname -s | tr a-z A-Z && printf saturn-%s ran")
        defer { model.terminate() }

        let harness = try await RealClaudeAPIErrorTests().makeHarness(stubURL: "http://127.0.0.1:\(port)")
        defer { harness.cleanUp() }
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        try await driver.ensureServer()

        let session = try await harness.spawn()
        try await waitUntil(timeout: .seconds(60)) { (try? String(contentsOf: log, encoding: .utf8))?.contains("toolu_first") == true && session.agent.status == .idle }

        let requests = try String(contentsOf: log, encoding: .utf8)
        let result = try #require(requests.components(separatedBy: "toolu_first").last)
        #expect(result.contains("saturn-ran"))
        #expect(!result.contains("Permission to use Bash"))
        #expect(try harness.database.openChatRequests(projectId: try #require(harness.project.id)).isEmpty)
    }

    @Test(.timeLimit(.minutes(3))) func askHoldsAPushUntilTheUserAllowsIt() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "permission-model-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let (model, port) = try await startModel(log: log)
        defer { model.terminate() }

        let harness = try await RealClaudeAPIErrorTests().makeHarness(stubURL: "http://127.0.0.1:\(port)")
        defer { harness.cleanUp() }
        var profiles = PermissionsConfig()
        if let index = profiles.profiles.firstIndex(where: { $0.id == "developer" }) { profiles.profiles[index].levels[.gitPush] = .ask }
        try ProjectConfigLoader.write(profiles, repository: harness.repo.root)
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        try await driver.ensureServer()

        let session = try await harness.spawn()
        try await waitUntil(timeout: .seconds(60)) { session.agent.status == .idle || session.agent.status == .failed }
        let projectId = try #require(harness.project.id)
        let item = try #require(try harness.database.openChatRequests(projectId: projectId).first { $0.kind == .permission })
        #expect(item.title.contains("git push --dry-run origin HEAD"))

        try harness.runtime.answerPermission(requestId: try #require(item.id), allow: true)
        try await waitUntil(timeout: .seconds(60)) { (try? String(contentsOf: log, encoding: .utf8))?.contains("toolu_second") == true && session.agent.status == .idle }

        let requests = try String(contentsOf: log, encoding: .utf8)
        #expect(requests.contains("so Saturn asked them in the chat"))
        let second = try #require(requests.components(separatedBy: "toolu_second").last)
        #expect(!second.contains("Permission to use Bash has been denied"))
    }
}
