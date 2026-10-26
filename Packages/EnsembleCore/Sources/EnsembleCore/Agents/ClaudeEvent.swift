import Foundation

public struct TokenUsage: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
}

public struct ToolCall: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public var parentToolUseID: String?
}

public struct ToolResult: Sendable, Hashable {
    public let toolUseID: String
    public let content: String
    public let isError: Bool
}

public struct TurnResult: Sendable, Hashable {
    public let subtype: String
    public let isError: Bool
    public let text: String?
    public let totalCostUSD: Double
    public let usage: TokenUsage
    public let permissionDenials: [String]
    public let durationMS: Int

    public var wasInterrupted: Bool { subtype == "error_during_execution" }
}

public struct SessionInfo: Sendable, Hashable {
    public let sessionID: String
    public let model: String
    public let cwd: String
    public let version: String?
    public let apiKeySource: String?

    public init(sessionID: String, model: String, cwd: String, version: String?, apiKeySource: String? = nil) {
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
        self.version = version
        self.apiKeySource = apiKeySource
    }
}

public enum EnsembleNotice: String, Sendable, Hashable, Codable {
    case started
    case paused
    case resumed
    case stopped
    case restarted
    case interrupted
    case takenOver
    case handedBack
    case failed
}

public enum ClaudeEvent: Sendable, Hashable {
    case sessionStarted(SessionInfo)
    case userMessage(String)
    case assistantText(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case turnCompleted(TurnResult)
    case notice(EnsembleNotice, detail: String?)
    case thinking(String)
    case thinkingTokens(Int)
    case messageStarted
    case thinkingStarted(index: Int)
    case assistantTextDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case blockStopped(index: Int)
    case messageStopped

    public var isPartial: Bool {
        switch self {
        case .messageStarted, .thinkingStarted, .assistantTextDelta, .thinkingDelta, .blockStopped, .messageStopped: true
        default: false
        }
    }

    public static func parse(line: String) -> [ClaudeEvent] {
        guard let json = JSONValue.parse(line), let type = json["type"]?.string else { return [] }
        switch type {
        case "stream_event":
            return streamEvent(json["event"]).map { [$0] } ?? []
        case "system":
            if json["subtype"]?.string == "thinking_tokens" {
                return json["estimated_tokens"]?.int.map { [.thinkingTokens($0)] } ?? []
            }
            guard json["subtype"]?.string == "init", let sessionID = json["session_id"]?.string else { return [] }
            return [.sessionStarted(SessionInfo(
                sessionID: sessionID,
                model: json["model"]?.string ?? "",
                cwd: json["cwd"]?.string ?? "",
                version: json["claude_code_version"]?.string,
                apiKeySource: json["apiKeySource"]?.string
            ))]
        case "assistant":
            return contentBlocks(json).compactMap { block in
                switch block["type"]?.string {
                case "text":
                    return block["text"]?.string.flatMap { $0.isEmpty ? nil : .assistantText($0) }
                case "thinking":
                    return .thinking(block["thinking"]?.string ?? "")
                case "tool_use":
                    guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
                    return .toolCall(ToolCall(id: id, name: name, input: block["input"] ?? .null, parentToolUseID: json["parent_tool_use_id"]?.string))
                default:
                    return nil
                }
            }
        case "user":
            if let text = json["message"]?["content"]?.string {
                return [.userMessage(text)]
            }
            let blocks = contentBlocks(json)
            if blocks.contains(where: { $0["type"]?.string == "image" }) {
                let parts = blocks.compactMap { block -> String? in
                    switch block["type"]?.string {
                    case "text": block["text"]?.string
                    case "image": ChatAttachment.imagePlaceholder
                    default: nil
                    }
                }
                return [.userMessage(parts.joined(separator: "\n"))]
            }
            return blocks.compactMap { block in
                switch block["type"]?.string {
                case "text":
                    return block["text"]?.string.map(ClaudeEvent.userMessage)
                case "tool_result":
                    guard let id = block["tool_use_id"]?.string else { return nil }
                    return .toolResult(ToolResult(
                        toolUseID: id,
                        content: text(of: block["content"]),
                        isError: block["is_error"]?.bool ?? false
                    ))
                default:
                    return nil
                }
            }
        case "result":
            let usage = json["usage"]
            return [.turnCompleted(TurnResult(
                subtype: json["subtype"]?.string ?? "",
                isError: json["is_error"]?.bool ?? false,
                text: json["result"]?.string,
                totalCostUSD: json["total_cost_usd"]?.double ?? 0,
                usage: TokenUsage(
                    input: usage?["input_tokens"]?.int ?? 0,
                    output: usage?["output_tokens"]?.int ?? 0,
                    cacheRead: usage?["cache_read_input_tokens"]?.int ?? 0,
                    cacheWrite: usage?["cache_creation_input_tokens"]?.int ?? 0
                ),
                permissionDenials: (json["permission_denials"]?.array ?? []).compactMap { $0["tool_name"]?.string },
                durationMS: json["duration_ms"]?.int ?? 0
            ))]
        case "ensemble":
            guard let notice = json["event"]?.string.flatMap(EnsembleNotice.init(rawValue:)) else { return [] }
            return [.notice(notice, detail: json["detail"]?.string)]
        default:
            return []
        }
    }

    public static func userLine(_ text: String) -> String {
        JSONValue.object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(text)]),
        ]).compactJSON
    }

    public static let omittedImageData = "omitted"

    public static func userLine(_ text: String, images: [ChatAttachment], includingImageData: Bool = true) -> String {
        let imageBlocks = images.compactMap { attachment -> JSONValue? in
            guard case .image(_, let mediaType, _, let data) = attachment else { return nil }
            return .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(mediaType),
                    "data": .string(includingImageData ? data.base64EncodedString() : omittedImageData),
                ]),
            ])
        }
        guard !imageBlocks.isEmpty else { return userLine(text) }
        let textBlocks: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        return JSONValue.object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array(textBlocks + imageBlocks)]),
        ]).compactJSON
    }

    public static func interruptLine(requestID: String) -> String {
        JSONValue.object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(["subtype": .string("interrupt")]),
        ]).compactJSON
    }

    public static func noticeLine(_ notice: EnsembleNotice, detail: String? = nil, at date: Date = .now) -> String {
        var object: [String: JSONValue] = [
            "type": .string("ensemble"),
            "event": .string(notice.rawValue),
            "at": .number(date.timeIntervalSince1970),
        ]
        if let detail { object["detail"] = .string(detail) }
        return JSONValue.object(object).compactJSON
    }

    private static func streamEvent(_ event: JSONValue?) -> ClaudeEvent? {
        guard let event, let type = event["type"]?.string else { return nil }
        switch type {
        case "message_start":
            return .messageStarted
        case "message_stop":
            return .messageStopped
        case "content_block_start":
            guard let index = event["index"]?.int, event["content_block"]?["type"]?.string == "thinking" else { return nil }
            return .thinkingStarted(index: index)
        case "content_block_delta":
            guard let index = event["index"]?.int, let delta = event["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                return delta["text"]?.string.map { .assistantTextDelta(index: index, text: $0) }
            case "thinking_delta":
                return delta["thinking"]?.string.map { .thinkingDelta(index: index, text: $0) }
            default:
                return nil
            }
        case "content_block_stop":
            return event["index"]?.int.map { .blockStopped(index: $0) }
        default:
            return nil
        }
    }

    private static func contentBlocks(_ json: JSONValue) -> [JSONValue] {
        json["message"]?["content"]?.array ?? []
    }

    private static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text): text
        case .array(let blocks): blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: ""
        }
    }
}
