import Foundation
import Network
import Testing
@testable import EnsembleCore

@MainActor
final class RecordingSink: HandoffSink {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Ensemble rejected the hand-off." }
    }

    private(set) var received: [(agentID: Int64, message: HandoffMessage)] = []
    var failing = false

    func receive(_ message: HandoffMessage, from agentID: Int64) async throws -> String {
        if failing { throw Failure() }
        received.append((agentID, message))
        return "Recorded for agent \(agentID)."
    }
}

struct MCPClient {
    let url: URL
    var session = URLSession(configuration: .ephemeral)

    func post(_ body: String) async throws -> (status: Int, json: JSONValue?, contentType: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        return (http?.statusCode ?? 0, json, http?.value(forHTTPHeaderField: "Content-Type"))
    }

    func call(_ method: String, id: Int = 1, params: JSONValue = .object([:])) async throws -> JSONValue {
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        let reply = try await post(message.compactJSON)
        #expect(reply.status == 200)
        #expect(reply.contentType == "application/json")
        return try #require(reply.json)
    }

    func callTool(_ name: String, _ arguments: JSONValue, id: Int = 1) async throws -> JSONValue {
        try await call("tools/call", id: id, params: .object(["name": .string(name), "arguments": arguments]))
    }

    func get() async throws -> Int {
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

extension JSONValue {
    var toolText: String? { self["result"]?["content"]?.array?.first?["text"]?.string }
    var isToolError: Bool? { self["result"]?["isError"]?.bool }
    var errorCode: Int? { self["error"]?["code"]?.int }
}

@MainActor
@Suite struct MCPServerTests {
    let sink = RecordingSink()

    func startServer() async throws -> EnsembleMCPServer {
        try await EnsembleMCPServer.start(sink: sink)
    }

    @Test func leadRunsTheWholeHandshakeAndEveryTool() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let endpoint = server.register(agent: 7, tools: Set(HandoffTool.allCases))
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:\(server.port)/mcp/\(endpoint.token)")
        let client = MCPClient(url: endpoint.url)

        let initialize = try await client.call("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))
        #expect(initialize["id"] == .number(1))
        #expect(initialize["jsonrpc"] == .string("2.0"))
        #expect(initialize["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("ensemble"))
        #expect(initialize["result"]?["capabilities"]?["tools"] != nil)

        let initialized = try await client.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(initialized.status == 202)
        #expect(initialized.json == nil)

        let list = try await client.call("tools/list", id: 2)
        let names = list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == HandoffTool.allCases.map(\.rawValue))
        let schema = list["result"]?["tools"]?.array?.first?["inputSchema"]
        #expect(schema == HandoffTool.submitPlan.inputSchema)

        let plan = try await client.callTool("submit_plan", .object([
            "summary": .string("Split it"),
            "tasks": .array([.object(["title": .string("API"), "role": .string("builder")])]),
        ]), id: 3)
        #expect(plan.isToolError == false)
        #expect(plan.toolText == "Recorded for agent 7.")

        let verdict = try await client.callTool("submit_verdict", .object([
            "outcome": .string("changes_requested"),
            "summary": .string("One bug"),
            "issues": .array([.object(["description": .string("Off by one"), "file": .string("a.swift")])]),
        ]), id: 4)
        #expect(verdict.isToolError == false)

        _ = try await client.callTool("submit_result", .object(["summary": .string("hello")]), id: 5)
        _ = try await client.callTool("create_pin", .object([
            "file": .string("db.sql"), "start_line": .number(3), "end_line": .number(9),
            "title": .string("Drops a table"), "explanation": .string("Data loss"), "tags": .array([.string("migration")]),
        ]), id: 6)
        _ = try await client.callTool("ask_human", .object(["question": .string("Postgres or SQLite?")]), id: 7)

        #expect(sink.received.map(\.agentID) == [7, 7, 7, 7, 7])
        let messages = sink.received.map(\.message)
        guard case .plan(let receivedPlan) = messages[0] else { Issue.record("expected a plan"); return }
        #expect(receivedPlan.summary == "Split it")
        #expect(receivedPlan.tasks.map(\.role) == ["builder"])
        #expect(messages[1] == .verdict(Verdict(outcome: "changes_requested", summary: "One bug", issues: [ReviewIssue(description: "Off by one", file: "a.swift")])))
        #expect(messages[2] == .result("hello"))
        #expect(messages[3] == .pin(PinDraft(file: "db.sql", startLine: 3, endLine: 9, title: "Drops a table", tags: ["migration"], explanation: "Data loss")))
        #expect(messages[4] == .question("Postgres or SQLite?"))
    }

    @Test func pingAndUnknownMethodsFollowJSONRPC() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)

        let ping = try await client.call("ping", id: 9)
        #expect(ping == .object(["jsonrpc": .string("2.0"), "id": .number(9), "result": .object([:])]))

        let unknown = try await client.call("resources/list", id: 10)
        #expect(unknown.errorCode == -32601)
        #expect(unknown["id"] == .number(10))

        let stringID = try await client.post(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        #expect(stringID.json?["id"] == .string("abc"))

        let noMethod = try await client.post(#"{"jsonrpc":"2.0","id":4}"#)
        #expect(noMethod.json?.errorCode == -32600)

        let clientResponse = try await client.post(#"{"jsonrpc":"2.0","id":4,"result":{}}"#)
        #expect(clientResponse.status == 202)
    }

    @Test func unsupportedProtocolVersionGetsTheLatest() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let reply = try await client.call("initialize", params: .object(["protocolVersion": .string("1999-01-01")]))
        #expect(reply["result"]?["protocolVersion"] == .string(MCPRequestHandler.supportedProtocolVersions[0]))
        let older = try await client.call("initialize", params: .object(["protocolVersion": .string("2024-11-05")]))
        #expect(older["result"]?["protocolVersion"] == .string("2024-11-05"))
    }

    @Test func toolsAreScopedToTheAgentsGrant() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let worker = server.register(agent: 2, tools: [.submitResult, .createPin, .askHuman])
        #expect(worker.allowedTools == ["mcp__ensemble__submit_result", "mcp__ensemble__create_pin", "mcp__ensemble__ask_human"])
        let client = MCPClient(url: worker.url)

        let list = try await client.call("tools/list")
        #expect(list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } == ["submit_result", "create_pin", "ask_human"])

        let forbidden = try await client.callTool("submit_plan", .object(["summary": .string("x"), "tasks": .array([])]))
        #expect(forbidden.errorCode == -32602)
        let unknown = try await client.callTool("rm_rf", .object([:]))
        #expect(unknown.errorCode == -32602)
        #expect(sink.received.isEmpty)
    }

    @Test func revokedAndUnknownTokensAreNotFound() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let endpoint = server.register(agent: 3, tools: [.submitResult])
        let other = server.register(agent: 3, tools: [.submitResult])
        let client = MCPClient(url: endpoint.url)
        #expect(try await client.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 200)

        server.revoke(token: endpoint.token)
        #expect(try await client.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 404)
        #expect(try await MCPClient(url: other.url).post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 200)

        server.revokeAll(agent: 3)
        #expect(try await MCPClient(url: other.url).post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 404)

        let guessed = server.baseURL.appending(path: String(repeating: "0", count: 64))
        #expect(try await MCPClient(url: guessed).post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 404)
        let root = try #require(URL(string: "http://127.0.0.1:\(server.port)/"))
        #expect(try await MCPClient(url: root).post("{}").status == 404)
        #expect(endpoint.token.count == 64)
        #expect(endpoint.token != other.token)
    }

    @Test func getIsNotAllowed() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        #expect(try await client.get() == 405)
    }

    @Test func malformedJSONIsAParseError() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let reply = try await client.post(#"{"jsonrpc":"2.0","id":1,"method":"#)
        #expect(reply.status == 400)
        #expect(reply.json?.errorCode == -32700)
        #expect(reply.json?["id"] == .null)
    }

    @Test func malformedArgumentsBecomeToolErrors() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: Set(HandoffTool.allCases)).url)

        let missingTasks = try await client.callTool("submit_plan", .object(["summary": .string("x")]))
        #expect(missingTasks.isToolError == true)
        #expect(missingTasks.toolText == "Invalid arguments for submit_plan: Missing required field “tasks”.")

        let wrongType = try await client.callTool("create_pin", .object([
            "file": .string("a"), "start_line": .string("three"), "title": .string("t"), "explanation": .string("e"),
        ]))
        #expect(wrongType.isToolError == true)
        #expect(wrongType.toolText?.contains("start_line") == true)

        let missingSummary = try await client.callTool("submit_result", .object([:]))
        #expect(missingSummary.toolText == "Invalid arguments for submit_result: Missing required field “summary”.")

        let notAnObject = try await client.callTool("submit_result", .string("hello"))
        #expect(notAnObject.isToolError == true)
        #expect(sink.received.isEmpty)
    }

    @Test func sinkFailuresBecomeToolErrors() async throws {
        let server = try await startServer()
        defer { server.stop() }
        sink.failing = true
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let reply = try await client.callTool("submit_result", .object(["summary": .string("done")]))
        #expect(reply.isToolError == true)
        #expect(reply.toolText == "Ensemble rejected the hand-off.")
    }

    @Test func largeBodiesArriveIntact() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let summary = String(repeating: "ünïcode-", count: 300_000)
        let reply = try await client.callTool("submit_result", .object(["summary": .string(summary)]))
        #expect(reply.isToolError == false)
        #expect(sink.received.map(\.message) == [.result(summary)])
    }

    @Test func bodiesOverTheLimitAreRejected() async throws {
        let server = try await EnsembleMCPServer.start(sink: sink, maximumBodySize: 1024)
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let reply = try await client.post(String(repeating: " ", count: 4096))
        #expect(reply.status == 413)
    }

    @Test func batchesGetOneReplyPerRequest() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let client = MCPClient(url: server.register(agent: 1, tools: [.submitResult]).url)
        let reply = try await client.post(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#)
        #expect(reply.json?.array?.compactMap { $0["id"]?.int } == [1, 2])
    }

    @Test func severalAgentsCallConcurrently() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let endpoints = (1...6).map { server.register(agent: Int64($0), tools: [.submitResult]) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for endpoint in endpoints {
                for call in 1...5 {
                    group.addTask {
                        let client = MCPClient(url: endpoint.url)
                        let reply = try await client.callTool("submit_result", .object(["summary": .string("\(endpoint.agentID)-\(call)")]), id: call)
                        #expect(reply.toolText == "Recorded for agent \(endpoint.agentID).")
                        #expect(reply["id"] == .number(Double(call)))
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(sink.received.count == 30)
        for entry in sink.received {
            guard case .result(let summary) = entry.message else { Issue.record("expected a result"); continue }
            #expect(summary.hasPrefix("\(entry.agentID)-"))
        }
    }

    @Test func oneConnectionServesPipelinedRequestsSentInPieces() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let endpoint = server.register(agent: 4, tools: [.submitResult])
        let path = "/mcp/\(endpoint.token)"
        func request(_ body: String, extra: String = "") -> String {
            "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let first = request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"submit_result","arguments":{"summary":"one"}}}"#)
        let second = request(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let chunkedBody = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_result","arguments":{"summary":"three"}}}"#
        let third = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + "10\r\n" + String(chunkedBody.prefix(16)) + "\r\n"
            + String(chunkedBody.utf8.count - 16, radix: 16) + "\r\n" + String(chunkedBody.dropFirst(16)) + "\r\n0\r\n\r\n"
        let bytes = Data((first + second + third).utf8)
        let pieces = stride(from: 0, to: bytes.count, by: 7).map { bytes[$0..<min($0 + 7, bytes.count)] }

        let raw = try await RawConnection.exchange(port: server.port, pieces: pieces.map { Data($0) })
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.components(separatedBy: "HTTP/1.1 200 OK").count == 4)
        #expect(text.contains(#""id":2"#))
        #expect(text.contains("Connection: close"))
        #expect(sink.received.map(\.message) == [.result("one"), .result("three")])
    }

    @Test func launchArgumentsWriteAPrivateConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mcp-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "http://127.0.0.1:4242/mcp/abc"))
        let endpoint = MCPEndpoint(agentID: 12, token: "abc", url: url, tools: [.askHuman, .submitPlan])

        let arguments = try endpoint.launchArguments(configDirectory: directory)
        let file = directory.appending(path: "mcp-agent-12.json")
        #expect(arguments == ["--mcp-config", file.path, "--strict-mcp-config"])
        let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(written == .object(["mcpServers": .object(["ensemble": .object(["type": .string("http"), "url": .string("http://127.0.0.1:4242/mcp/abc")])])]))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(endpoint.allowedTools == ["mcp__ensemble__submit_plan", "mcp__ensemble__ask_human"])
    }
}

@Suite struct HTTPRequestParserTests {
    @Test func waitsForTheWholeBody() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp/x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8))
        #expect(try parser.nextRequest() == nil)
        parser.append(Data("cdePOST".utf8))
        let request = try #require(try parser.nextRequest())
        #expect(request.body == Data("abcde".utf8))
        #expect(request.headers["content-length"] == "5")
        #expect(request.keepsConnectionAlive)
        #expect(parser.buffer == Data("POST".utf8))
    }

    @Test func rejectsGarbage() {
        var parser = HTTPRequestParser()
        parser.append(Data("NOT HTTP\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.self) { try parser.nextRequest() }
    }

    @Test func rejectsOversizedHeaders() {
        var parser = HTTPRequestParser(maximumHeaderSize: 16)
        parser.append(Data("POST /mcp/x HTTP/1.1\r\nX-Long: aaaaaaaaaaaa".utf8))
        #expect(throws: HTTPParseError.headersTooLarge) { try parser.nextRequest() }
    }

    @Test func honoursConnectionClose() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET / HTTP/1.1\r\nConnection: close\r\n\r\nGET / HTTP/1.0\r\n\r\n".utf8))
        #expect(try parser.nextRequest()?.keepsConnectionAlive == false)
        #expect(try parser.nextRequest()?.keepsConnectionAlive == false)
    }
}

enum RawConnection {
    static func exchange(port: UInt16, pieces: [Data]) async throws -> Data {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
        connection.start(queue: DispatchQueue(label: "raw-client"))
        defer { connection.cancel() }
        for piece in pieces {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: piece, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        var received = Data()
        while true {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(returning: isComplete || error != nil ? nil : Data()) }
                }
            }
            guard let chunk else { return received }
            received.append(chunk)
        }
    }
}

@Suite struct MCPHostCheckTests {
    @Test func acceptsOnlyLoopbackHosts() {
        #expect(MCPRequestHandler.isLoopbackHost("127.0.0.1:5123"))
        #expect(MCPRequestHandler.isLoopbackHost("localhost:80"))
        #expect(MCPRequestHandler.isLoopbackHost("[::1]:5123"))
        #expect(!MCPRequestHandler.isLoopbackHost("evil.example:5123"))
        #expect(!MCPRequestHandler.isLoopbackHost("127.0.0.1.evil.example"))
        #expect(!MCPRequestHandler.isLoopbackHost(nil))
    }
}
