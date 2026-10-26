import Foundation

public enum ToolKind: Sendable, Hashable {
    case shell
    case read
    case search
    case edit
    case webFetch
    case webSearch
    case subagent
    case todo
    case other(String)

    public init(name: String) {
        switch name {
        case "Bash", "BashOutput": self = .shell
        case "Read", "NotebookRead": self = .read
        case "Grep", "Glob", "LS": self = .search
        case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .edit
        case "WebFetch": self = .webFetch
        case "WebSearch": self = .webSearch
        case "Task", "Agent": self = .subagent
        case "TodoWrite": self = .todo
        default: self = .other(name)
        }
    }

    public var isGroupable: Bool {
        switch self {
        case .subagent, .todo: false
        default: true
        }
    }
}

public struct ToolGroup: Sendable, Hashable, Identifiable {
    public let kind: ToolKind
    public let tools: [ToolActivity]
    public let id: Int

    public var failureCount: Int { tools.filter(\.isError).count }

    public var summary: String {
        let count = tools.count
        let files = Set(tools.compactMap(\.filePath)).count
        switch kind {
        case .shell: return "Ran \(count) command\(count == 1 ? "" : "s")"
        case .read: return "Read \(files) file\(files == 1 ? "" : "s")"
        case .search: return "Searched \(count) time\(count == 1 ? "" : "s")"
        case .edit: return "Edited \(files) file\(files == 1 ? "" : "s")"
        case .webFetch: return "Fetched \(count) page\(count == 1 ? "" : "s")"
        case .webSearch: return "Searched the web \(count) time\(count == 1 ? "" : "s")"
        case .subagent: return "Ran \(count) subagent\(count == 1 ? "" : "s")"
        case .todo: return "Updated the todo list \(count) time\(count == 1 ? "" : "s")"
        case .other(let name): return "Called \(name) \(count) time\(count == 1 ? "" : "s")"
        }
    }
}

public enum TranscriptItem: Sendable, Hashable, Identifiable {
    case entry(TranscriptEntry)
    case group(ToolGroup)
    case subagent(TranscriptEntry, children: [TranscriptItem])

    public var id: String {
        switch self {
        case .entry(let entry), .subagent(let entry, _): "entry-\(entry.id)"
        case .group(let group): "group-\(group.id)"
        }
    }
}

public enum TranscriptLayout {
    public static func items(_ entries: [TranscriptEntry], live: TranscriptEntry? = nil) -> [TranscriptItem] {
        var all = entries
        if let live, !entries.contains(where: { $0.id == live.id }) { all.append(live) }
        let subagentIDs = Set(all.compactMap { entry -> String? in
            guard case .tool(let tool) = entry.content, ToolKind(name: tool.name) == .subagent else { return nil }
            return tool.id
        })
        var children: [String: [TranscriptEntry]] = [:]
        var topLevel: [TranscriptEntry] = []
        for entry in all {
            if case .tool(let tool) = entry.content, let parent = tool.parentToolUseID, subagentIDs.contains(parent), parent != tool.id {
                children[parent, default: []].append(entry)
            } else {
                topLevel.append(entry)
            }
        }
        var visited: Set<String> = []
        return layout(topLevel, children: children, visited: &visited)
    }

    private static func layout(_ entries: [TranscriptEntry], children: [String: [TranscriptEntry]], visited: inout Set<String>) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var pending: [(entry: TranscriptEntry, tool: ToolActivity)] = []

        func flush() {
            if pending.count >= 2, let first = pending.first {
                items.append(.group(ToolGroup(kind: ToolKind(name: first.tool.name), tools: pending.map(\.tool), id: first.entry.id)))
            } else {
                items += pending.map { .entry($0.entry) }
            }
            pending = []
        }

        for entry in entries {
            switch entry.content {
            case .tool(let tool) where ToolKind(name: tool.name) == .subagent && visited.insert(tool.id).inserted:
                flush()
                let nested = layout(children[tool.id] ?? [], children: children, visited: &visited)
                items.append(nested.isEmpty ? .entry(entry) : .subagent(entry, children: nested))
            case .tool(let tool) where tool.isFinished && ToolKind(name: tool.name).isGroupable:
                if let first = pending.first, ToolKind(name: first.tool.name) != ToolKind(name: tool.name) { flush() }
                pending.append((entry, tool))
            case .thinking(let block) where block.isFinished && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                continue
            case .assistant(let text) where !entry.isStreaming && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                continue
            default:
                flush()
                items.append(.entry(entry))
            }
        }
        flush()
        return items
    }

    public static func activity(_ entries: [TranscriptEntry], live: TranscriptEntry? = nil) -> SessionActivity {
        var all = entries
        if let live, !entries.contains(where: { $0.id == live.id }) { all.append(live) }
        guard let last = all.last else { return .working }
        switch last.content {
        case .assistant(let text) where last.isStreaming: return .replying(text)
        case .thinking(let block) where !block.isFinished: return .thinking(block)
        case .tool(let tool) where !tool.isFinished: return .tool(tool)
        default:
            for entry in all.reversed() {
                switch entry.content {
                case .tool(let tool) where !tool.isFinished: return .tool(tool)
                case .user, .turnFinished, .notice, .interrupted: return .working
                default: continue
                }
            }
            return .working
        }
    }

    public static func latestTodos(in entries: [TranscriptEntry]) -> [TodoItem] {
        for entry in entries.reversed() {
            if case .tool(let tool) = entry.content, ToolKind(name: tool.name) == .todo, tool.parentToolUseID == nil {
                return TodoItem.parse(tool.input)
            }
        }
        return []
    }
}

public enum SessionActivity: Sendable, Hashable {
    case working
    case replying(String)
    case thinking(ThinkingBlock)
    case tool(ToolActivity)
}

public struct TodoItem: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var content: String
    public var activeForm: String?
    public var status: Status

    public init(content: String, activeForm: String? = nil, status: Status) {
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }

    public static func parse(_ input: JSONValue) -> [TodoItem] {
        (input["todos"]?.array ?? []).compactMap { todo in
            guard let content = todo["content"]?.string, !content.isEmpty else { return nil }
            let status = todo["status"]?.string.flatMap(Status.init(rawValue:)) ?? .pending
            return TodoItem(content: content, activeForm: todo["activeForm"]?.string, status: status)
        }
    }
}

public enum ToolResultSummary {
    public static func exitCode(of tool: ToolActivity) -> Int? {
        guard let result = tool.result, let match = result.prefixMatch(of: /Exit code (\d+)/) else {
            return tool.isFinished && !tool.isError ? 0 : nil
        }
        return Int(match.1)
    }

    public static func shellOutput(of tool: ToolActivity) -> String {
        guard let result = tool.result else { return "" }
        guard let match = result.prefixMatch(of: /Exit code \d+\n?/) else { return result }
        return String(result[match.range.upperBound...])
    }

    public static func paths(in tool: ToolActivity) -> [String] {
        guard ToolKind(name: tool.name) == .search, !tool.isError, let result = tool.result else { return [] }
        var seen: Set<String> = []
        var paths: [String] = []
        for raw in result.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard !line.hasPrefix("Found "), !line.hasPrefix("No ") else { continue }
            let candidate: String
            if let match = line.firstMatch(of: /^(.+?):\d+(?::|$)/) {
                candidate = String(match.1)
            } else {
                candidate = line.trimmingCharacters(in: .whitespaces)
            }
            let looksLikePath = candidate.hasPrefix("/") || (!candidate.contains(" ") && (candidate.contains("/") || candidate.contains(".")))
            guard looksLikePath, !line.hasPrefix(" "), seen.insert(candidate).inserted else { continue }
            paths.append(candidate)
        }
        return paths
    }

    public static func countLabel(for tool: ToolActivity) -> String? {
        guard tool.isFinished, !tool.isError, let result = tool.result else { return nil }
        switch tool.name {
        case "Read":
            let lines = result.split(separator: "\n").filter { $0.firstMatch(of: /^\s*\d+(→|\t)/) != nil }.count
            return lines > 0 ? plural(lines, "line") : nil
        case "Glob":
            if result.hasPrefix("No files") { return "No files" }
            return plural(paths(in: tool).count, "file")
        case "Grep":
            if result.hasPrefix("No ") { return "No matches" }
            if let match = result.prefixMatch(of: /Found (\d+) (file|line|match|occurrence)/), let count = Int(match.1) {
                return plural(count, String(match.2) == "match" ? "match" : String(match.2))
            }
            let mode = tool.input["output_mode"]?.string
            if mode == "count" {
                let total = result.split(separator: "\n").compactMap { $0.split(separator: ":").last.flatMap { Int($0) } }.reduce(0, +)
                return plural(total, "match")
            }
            if mode == "content" {
                return plural(result.split(separator: "\n").filter { !$0.hasPrefix("--") }.count, "line")
            }
            return plural(paths(in: tool).count, "file")
        default:
            return nil
        }
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        let suffix = noun.hasSuffix("ch") ? "es" : "s"
        return "\(count) \(noun)\(count == 1 ? "" : suffix)"
    }
}

public enum LiveFormat {
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", total % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count) token\(count == 1 ? "" : "s")" }
        let thousands = Double(count) / 1000
        let formatted = thousands < 10 ? String(format: "%.1f", thousands) : String(Int(thousands.rounded()))
        return "\(formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted)k tokens"
    }
}

public struct CodeFileLocation: Sendable, Hashable {
    public let rootIndex: Int
    public let relativePath: String
}

public enum CodeFileLocator {
    public static func locate(_ path: String, cwd: String?, roots: [String]) -> CodeFileLocation? {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if let cwd, !cwd.isEmpty {
            absolute = (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
        } else {
            return nil
        }
        let target = normalized(absolute)
        var best: CodeFileLocation?
        var bestLength = -1
        for (index, root) in roots.enumerated() {
            let base = normalized(root)
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard target.hasPrefix(prefix), prefix.count > bestLength else { continue }
            let relative = String(target.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            best = CodeFileLocation(rootIndex: index, relativePath: relative)
            bestLength = prefix.count
        }
        return best
    }

    public static func displayPath(_ path: String, root: String?) -> String {
        guard path.hasPrefix("/"), let root, !root.isEmpty else { return path }
        let base = normalized(root)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let target = normalized(path)
        return target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : path
    }

    static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix("/private/") ? String(standardized.dropFirst("/private".count)) : standardized
    }
}
