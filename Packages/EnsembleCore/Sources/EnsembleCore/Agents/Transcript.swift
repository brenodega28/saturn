import Foundation

public struct ToolActivity: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public var result: String?
    public var isError: Bool
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil

    public var isFinished: Bool { result != nil }

    public var filePath: String? {
        input["file_path"]?.string ?? input["notebook_path"]?.string
    }

    public func target(relativeTo root: String?) -> String {
        if let path = filePath {
            return Self.relative(path, to: root)
        }
        switch name {
        case "Bash": return input["command"]?.string ?? ""
        case "Grep", "Glob": return input["pattern"]?.string ?? ""
        case "WebFetch": return input["url"]?.string ?? ""
        case "WebSearch": return input["query"]?.string ?? ""
        case "Task", "Agent": return input["description"]?.string ?? ""
        default: return input == .null ? "" : input.compactJSON
        }
    }

    public var diff: [DiffLine]? {
        switch name {
        case "Edit":
            guard let old = input["old_string"]?.string, let new = input["new_string"]?.string else { return nil }
            return LineDiff.compute(old: old, new: new)
        case "MultiEdit":
            guard let edits = input["edits"]?.array else { return nil }
            return edits.flatMap { edit in
                LineDiff.compute(old: edit["old_string"]?.string ?? "", new: edit["new_string"]?.string ?? "")
            }
        case "Write":
            guard let content = input["content"]?.string else { return nil }
            return LineDiff.compute(old: "", new: content)
        default:
            return nil
        }
    }

    static func relative(_ path: String, to root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for candidate in [prefix, "/private" + prefix] where path.hasPrefix(candidate) {
            return String(path.dropFirst(candidate.count))
        }
        return path
    }
}

public struct ThinkingBlock: Sendable, Hashable {
    public var text: String
    public var isFinished: Bool
    public var estimatedTokens: Int?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(text: String, isFinished: Bool, estimatedTokens: Int? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.text = text
        self.isFinished = isFinished
        self.estimatedTokens = estimatedTokens
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct TranscriptEntry: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case user(String)
        case assistant(String)
        case thinking(ThinkingBlock)
        case tool(ToolActivity)
        case notice(EnsembleNotice, detail: String?)
        case interrupted
        case turnFinished(TurnResult)
    }

    public let id: Int
    public var content: Content
    public var isStreaming: Bool = false
}

public struct Transcript: Sendable, Hashable {
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var session: SessionInfo?
    private var toolIndex: [String: Int] = [:]

    public var liveEntry: TranscriptEntry? { nil }

    public init() {}

    public init(lines: some Sequence<String>) {
        for line in lines {
            for event in ClaudeEvent.parse(line: line) {
                apply(event)
            }
        }
    }

    public var activeTool: ToolActivity? {
        for entry in entries.reversed() {
            if case .tool(let tool) = entry.content, !tool.isFinished { return tool }
            if case .turnFinished = entry.content { return nil }
        }
        return nil
    }

    public mutating func apply(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let info):
            session = info
        case .userMessage(let text):
            if text.hasPrefix("[Request interrupted") {
                append(.interrupted)
            } else {
                append(.user(text))
            }
        case .assistantText(let text):
            append(.assistant(text))
        case .toolCall(let call):
            toolIndex[call.id] = entries.count
            append(.tool(ToolActivity(id: call.id, name: call.name, input: call.input, result: nil, isError: false)))
        case .toolResult(let result):
            guard let index = toolIndex[result.toolUseID], case .tool(var tool) = entries[index].content else { return }
            tool.result = result.content
            tool.isError = result.isError
            entries[index].content = .tool(tool)
        case .turnCompleted(let result):
            closeUnfinishedTools()
            append(.turnFinished(result))
        case .notice(let notice, let detail):
            closeUnfinishedTools()
            append(.notice(notice, detail: detail))
        }
    }

    private mutating func closeUnfinishedTools() {
        for (id, index) in toolIndex {
            guard case .tool(var tool) = entries[index].content, !tool.isFinished else { continue }
            tool.result = ""
            tool.isError = true
            entries[index].content = .tool(tool)
            toolIndex[id] = nil
        }
    }

    private mutating func append(_ content: TranscriptEntry.Content) {
        entries.append(TranscriptEntry(id: entries.count, content: content))
    }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let text: String
}

public enum LineDiff {
    static let maximumCells = 250_000

    public static func compute(old: String, new: String) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard oldLines.count * newLines.count <= maximumCells else {
            return oldLines.map { DiffLine(kind: .removed, text: $0) } + newLines.map { DiffLine(kind: .added, text: $0) }
        }

        let rows = oldLines.count
        let columns = newLines.count
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                lengths[i][j] = oldLines[i] == newLines[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var lines: [DiffLine] = []
        var i = 0
        var j = 0
        while i < rows || j < columns {
            if i < rows, j < columns, oldLines[i] == newLines[j] {
                lines.append(DiffLine(kind: .context, text: oldLines[i]))
                i += 1
                j += 1
            } else if i < rows, j == columns || lengths[i + 1][j] >= lengths[i][j + 1] {
                lines.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                lines.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            }
        }
        return lines
    }
}
