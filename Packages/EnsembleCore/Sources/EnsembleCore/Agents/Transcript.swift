import Foundation

public struct ToolActivity: Sendable, Hashable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public var result: String?
    public var isError: Bool
    public var startedAt: Date?
    public var finishedAt: Date?

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

    public init(text: String = "", isFinished: Bool = false, estimatedTokens: Int? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
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
    public var isStreaming: Bool

    public init(id: Int, content: Content, isStreaming: Bool = false) {
        self.id = id
        self.content = content
        self.isStreaming = isStreaming
    }

    var isThinking: Bool {
        if case .thinking = content { true } else { false }
    }

    var isAssistant: Bool {
        if case .assistant = content { true } else { false }
    }
}

public struct Transcript: Sendable, Hashable {
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var session: SessionInfo?
    private var toolIndex: [String: Int] = [:]
    private var openBlocks: [Int: Int] = [:]
    private var awaitingFinal: [Int] = []
    private var liveIndex: Int?

    public init() {}

    public init(lines: some Sequence<String>) {
        for line in lines {
            for event in ClaudeEvent.parse(line: line) {
                apply(event, at: nil)
            }
        }
    }

    public var liveEntry: TranscriptEntry? {
        guard let liveIndex, entries[liveIndex].isStreaming else { return nil }
        return entries[liveIndex]
    }

    public var activeTool: ToolActivity? {
        for entry in entries.reversed() {
            if case .tool(let tool) = entry.content, !tool.isFinished { return tool }
            if case .turnFinished = entry.content { return nil }
        }
        return nil
    }

    public mutating func apply(_ event: ClaudeEvent, now: Date = .now) {
        apply(event, at: now)
    }

    private mutating func apply(_ event: ClaudeEvent, at now: Date?) {
        switch event {
        case .sessionStarted(let info):
            session = info
        case .userMessage(let text):
            closeStreaming(at: now)
            if text.hasPrefix("[Request interrupted") {
                append(.interrupted)
            } else {
                append(.user(text))
            }
        case .assistantText(let text):
            finishThinking(at: now)
            if let index = takeAwaitingFinal(where: \.isAssistant) {
                settle(index, text: text, at: now)
            } else {
                append(.assistant(text))
            }
        case .thinking(let text):
            if let index = takeAwaitingFinal(where: \.isThinking) {
                settle(index, text: text, at: now)
            } else {
                append(.thinking(ThinkingBlock(text: text, isFinished: true, finishedAt: now)))
            }
        case .thinkingTokens(let tokens):
            let index = awaitingFinal.last { entries[$0].isThinking }
                ?? (entries.last?.isThinking == true ? entries.count - 1 : nil)
                ?? startThinking(at: now)
            guard case .thinking(var block) = entries[index].content else { return }
            block.estimatedTokens = tokens
            entries[index].content = .thinking(block)
        case .messageStarted:
            settleOpenBlocks(at: now)
        case .thinkingStarted(let index):
            openBlocks[index] = openBlocks[index] ?? unboundThinking() ?? startThinking(at: now)
        case .assistantTextDelta(let index, let text):
            let entryIndex = openBlocks[index] ?? openTextBlock(index)
            extend(entryIndex, with: text)
        case .thinkingDelta(let index, let text):
            let entryIndex = openBlocks[index] ?? unboundThinking() ?? startThinking(at: now)
            openBlocks[index] = entryIndex
            extend(entryIndex, with: text)
        case .blockStopped(let index):
            guard let entryIndex = openBlocks.removeValue(forKey: index) else { return }
            settle(entryIndex, text: nil, at: now)
        case .messageStopped:
            closeStreaming(at: now)
        case .toolCall(let call):
            finishThinking(at: now)
            toolIndex[call.id] = entries.count
            append(.tool(ToolActivity(id: call.id, name: call.name, input: call.input, result: nil, isError: false, startedAt: now)))
        case .toolResult(let result):
            guard let index = toolIndex[result.toolUseID], case .tool(var tool) = entries[index].content else { return }
            tool.result = result.content
            tool.isError = result.isError
            tool.finishedAt = now
            entries[index].content = .tool(tool)
        case .turnCompleted(let result):
            closeStreaming(at: now)
            closeUnfinishedTools(at: now)
            append(.turnFinished(result))
        case .notice(let notice, let detail):
            closeStreaming(at: now)
            closeUnfinishedTools(at: now)
            append(.notice(notice, detail: detail))
        }
    }

    private mutating func startThinking(at now: Date?) -> Int {
        let index = append(.thinking(ThinkingBlock(startedAt: now)), isStreaming: true)
        awaitingFinal.append(index)
        liveIndex = index
        return index
    }

    private mutating func openTextBlock(_ block: Int) -> Int {
        let index = append(.assistant(""), isStreaming: true)
        awaitingFinal.append(index)
        openBlocks[block] = index
        liveIndex = index
        return index
    }

    private func unboundThinking() -> Int? {
        awaitingFinal.first { index in
            guard case .thinking(let block) = entries[index].content else { return false }
            return !block.isFinished && !openBlocks.values.contains(index)
        }
    }

    private mutating func extend(_ index: Int, with delta: String) {
        guard entries[index].isStreaming else { return }
        switch entries[index].content {
        case .assistant(var text):
            entries[index].content = .interrupted
            text += delta
            entries[index].content = .assistant(text)
        case .thinking(var block):
            entries[index].content = .interrupted
            block.text += delta
            entries[index].content = .thinking(block)
        default:
            return
        }
        liveIndex = index
    }

    private mutating func takeAwaitingFinal(where matches: (TranscriptEntry) -> Bool) -> Int? {
        guard let position = awaitingFinal.firstIndex(where: { matches(entries[$0]) }) else { return nil }
        return awaitingFinal.remove(at: position)
    }

    private mutating func finishThinking(at now: Date?) {
        while let index = takeAwaitingFinal(where: \.isThinking) {
            settle(index, text: nil, at: now)
        }
    }

    private mutating func settleOpenBlocks(at now: Date?) {
        for index in openBlocks.values {
            settle(index, text: nil, at: now)
        }
        openBlocks.removeAll()
    }

    private mutating func closeStreaming(at now: Date?) {
        settleOpenBlocks(at: now)
        for index in awaitingFinal {
            settle(index, text: nil, at: now)
        }
        awaitingFinal.removeAll()
        if let liveIndex {
            settle(liveIndex, text: nil, at: now)
        }
    }

    private mutating func settle(_ index: Int, text: String?, at now: Date?) {
        entries[index].isStreaming = false
        switch entries[index].content {
        case .assistant:
            if let text { entries[index].content = .assistant(text) }
        case .thinking(var block):
            if let text { block.text = text }
            if !block.isFinished {
                block.isFinished = true
                block.finishedAt = now
            }
            entries[index].content = .thinking(block)
        default:
            break
        }
        if liveIndex == index { liveIndex = nil }
    }

    private mutating func closeUnfinishedTools(at now: Date?) {
        for (id, index) in toolIndex {
            guard case .tool(var tool) = entries[index].content, !tool.isFinished else { continue }
            tool.result = ""
            tool.isError = true
            tool.finishedAt = now
            entries[index].content = .tool(tool)
            toolIndex[id] = nil
        }
    }

    @discardableResult
    private mutating func append(_ content: TranscriptEntry.Content, isStreaming: Bool = false) -> Int {
        entries.append(TranscriptEntry(id: entries.count, content: content, isStreaming: isStreaming))
        return entries.count - 1
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
