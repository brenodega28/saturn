import Foundation

enum JSONRPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
}

struct MCPRequestHandler: Sendable {
    static let pathPrefix = "/mcp/"
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverVersion = "1.0.0"

    let registry: MCPTokenRegistry
    let sink: any HandoffSink

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard Self.isLoopbackHost(request.headers["host"]) else {
            return .text(403, "Forbidden.")
        }
        let path = request.path
        guard path.hasPrefix(Self.pathPrefix) else { return .text(404, "Not found.") }
        let token = String(path.dropFirst(Self.pathPrefix.count))
        guard !token.isEmpty, !token.contains("/"), let grant = registry.grant(for: token) else {
            return .text(404, "Not found.")
        }
        guard request.method == "POST" else {
            return .text(405, "Use POST.", headers: [("Allow", "POST")])
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return .json(Self.error(id: .null, code: .parseError, message: "Parse error: the body is not valid JSON."), status: 400)
        }

        if case .array(let batch) = message {
            guard !batch.isEmpty else {
                return .json(Self.error(id: .null, code: .invalidRequest, message: "Empty batch."), status: 400)
            }
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await reply(to: item, grant: grant) { replies.append(reply) }
            }
            return replies.isEmpty ? HTTPResponse(status: 202) : .json(.array(replies))
        }

        guard let reply = await reply(to: message, grant: grant) else { return HTTPResponse(status: 202) }
        return .json(reply)
    }

    func reply(to message: JSONValue, grant: MCPGrant) async -> JSONValue? {
        guard case .object(let fields) = message else {
            return Self.error(id: .null, code: .invalidRequest, message: "Invalid request.")
        }
        let id = fields["id"]
        guard let method = fields["method"]?.string else {
            if id != nil, fields["result"] != nil || fields["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: .invalidRequest, message: "Invalid request: missing method.")
        }
        guard let id else { return nil }
        let params = fields["params"] ?? .object([:])

        switch method {
        case "initialize":
            return Self.success(id: id, result: initializeResult(params: params))
        case "ping":
            return Self.success(id: id, result: .object([:]))
        case "tools/list":
            return Self.success(id: id, result: .object(["tools": .array(grant.orderedTools.map(Self.describe))]))
        case "tools/call":
            return await callTool(id: id, params: params, grant: grant)
        default:
            return Self.error(id: id, code: .methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.string
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string(HandoffTool.serverName), "version": .string(Self.serverVersion)]),
        ])
    }

    private func callTool(id: JSONValue, params: JSONValue, grant: MCPGrant) async -> JSONValue {
        guard let name = params["name"]?.string else {
            return Self.error(id: id, code: .invalidParams, message: "Missing tool name.")
        }
        guard let tool = HandoffTool(rawValue: name), grant.tools.contains(tool) else {
            return Self.error(id: id, code: .invalidParams, message: "Unknown tool: \(name)")
        }
        let arguments = params["arguments"] ?? .object([:])
        guard case .object = arguments else {
            return Self.success(id: id, result: Self.toolResult("Arguments must be a JSON object.", isError: true))
        }
        let message: HandoffMessage
        do {
            message = try tool.decode(arguments)
        } catch {
            return Self.success(id: id, result: Self.toolResult("Invalid arguments for \(name): \(Self.describe(error))", isError: true))
        }
        do {
            let text = try await sink.receive(message, from: grant.agentID)
            return Self.success(id: id, result: Self.toolResult(text, isError: false))
        } catch {
            return Self.success(id: id, result: Self.toolResult(error.localizedDescription, isError: true))
        }
    }

    static func describe(_ tool: HandoffTool) -> JSONValue {
        .object([
            "name": .string(tool.rawValue),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ])
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: JSONRPCErrorCode, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code.rawValue)), "message": .string(message)]),
        ])
    }

    static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        func location(_ path: [any CodingKey]) -> String {
            let joined = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "the arguments" : "“\(joined)”"
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "Missing required field “\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))”."
        case .typeMismatch(let type, let context):
            return "Expected \(type) at \(location(context.codingPath))."
        case .valueNotFound(let type, let context):
            return "Expected \(type) at \(location(context.codingPath)) but found null."
        case .dataCorrupted(let context):
            return "Invalid value at \(location(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
