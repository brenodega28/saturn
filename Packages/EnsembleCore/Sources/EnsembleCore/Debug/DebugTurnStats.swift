#if DEBUG
import Foundation

struct DebugTurnStats {
    static let errorPreviewLength = 300

    var startedAt: Date?
    private var messageIDs: Set<String> = []
    private var unnamedMessages = 0
    private var toolNames: [String: String] = [:]
    private var toolCounts: [String: Int] = [:]
    private var failedTools: [JSONValue] = []
    private var lastUsage: JSONValue?
    private var denials: [JSONValue] = []
    private var numTurns: Int?
    private var model: String?

    init(startedAt: Date? = nil) {
        self.startedAt = startedAt
    }

    mutating func ingest(_ json: JSONValue) {
        switch json["type"]?.string {
        case "assistant":
            ingestAssistant(json["message"])
        case "user":
            for block in json["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" && block["is_error"]?.bool == true {
                let id = block["tool_use_id"]?.string ?? ""
                failedTools.append(.object([
                    "tool": .string(toolNames[id] ?? "unknown"),
                    "toolUseId": .string(id),
                    "error": .string(DebugText.preview(Self.text(of: block["content"]), limit: Self.errorPreviewLength)),
                ]))
            }
        case "result":
            denials = (json["permission_denials"]?.array ?? []).map { denial in
                .object([
                    "tool": denial["tool_name"] ?? .null,
                    "toolUseId": denial["tool_use_id"] ?? .null,
                    "input": denial["tool_input"] ?? .null,
                ])
            }
            numTurns = json["num_turns"]?.int
        default:
            break
        }
    }

    func summary(result: TurnResult, costUSD: Double, endedAt: Date) -> DebugFields {
        var fields: DebugFields = [
            "durationMS": JSONValue(result.durationMS),
            "costUSD": JSONValue(costUSD),
            "inputTokens": JSONValue(result.usage.input),
            "outputTokens": JSONValue(result.usage.output),
            "cacheReadTokens": JSONValue(result.usage.cacheRead),
            "cacheWriteTokens": JSONValue(result.usage.cacheWrite),
            "apiCalls": JSONValue(messageIDs.count + unnamedMessages),
            "toolCalls": .object(toolCounts.mapValues { JSONValue($0) }),
            "toolCallTotal": JSONValue(toolCounts.values.reduce(0, +)),
            "failedToolCalls": .array(failedTools),
            "permissionDenials": .array(denials),
            "interrupted": JSONValue(result.wasInterrupted),
            "subtype": JSONValue(result.subtype),
            "isError": JSONValue(result.isError),
            "contextTokens": contextTokens.map { JSONValue($0) } ?? .null,
        ]
        if let startedAt { fields["wallClockMS"] = JSONValue(Int(endedAt.timeIntervalSince(startedAt) * 1000)) }
        if let numTurns { fields["numTurns"] = JSONValue(numTurns) }
        if let model { fields["model"] = JSONValue(model) }
        return fields
    }

    var contextTokens: Int? {
        guard let usage = lastUsage else { return nil }
        return (usage["input_tokens"]?.int ?? 0) + (usage["cache_read_input_tokens"]?.int ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
    }

    private mutating func ingestAssistant(_ message: JSONValue?) {
        guard let message else { return }
        if let id = message["id"]?.string {
            messageIDs.insert(id)
        } else {
            unnamedMessages += 1
        }
        if let usage = message["usage"], usage.object != nil { lastUsage = usage }
        if let name = message["model"]?.string { model = name }
        for block in message["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
            let name = block["name"]?.string ?? "unknown"
            if let id = block["id"]?.string { toolNames[id] = name }
            toolCounts[name, default: 0] += 1
        }
    }

    private static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text): text
        case .array(let blocks): blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: ""
        }
    }
}
#endif
