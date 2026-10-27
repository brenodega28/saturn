import Foundation
import Observation

public struct LogEntry: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable, Hashable, CaseIterable, Comparable {
        case debug = "D"
        case info = "I"
        case warning = "W"
        case error = "E"

        public static func < (lhs: Level, rhs: Level) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public var id: Int
    public var date: Date
    public var level: Level
    public var source: String
    public var projectId: Int64?
    public var agentId: Int64?
    public var runId: Int64?
    public var step: String
    public var message: String

    public init(id: Int = 0, date: Date, level: Level, source: String, projectId: Int64? = nil, agentId: Int64? = nil, runId: Int64? = nil, step: String = "", message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.source = source
        self.projectId = projectId
        self.agentId = agentId
        self.runId = runId
        self.step = step
        self.message = message
    }
}

public struct ActivitySnapshot: Sendable, Hashable {
    public struct RunState: Sendable, Hashable {
        public var projectId: Int64
        public var title: String
        public var status: RunStatus
        public var step: String?
        public var hold: String?
        public var error: String?

        public init(projectId: Int64, title: String, status: RunStatus, step: String? = nil, hold: String? = nil, error: String? = nil) {
            self.projectId = projectId
            self.title = title
            self.status = status
            self.step = step
            self.hold = hold
            self.error = error
        }
    }

    public struct ToolState: Sendable, Hashable {
        public var id: String
        public var name: String
        public var target: String
        public var isError: Bool

        public init(id: String, name: String, target: String, isError: Bool = false) {
            self.id = id
            self.name = name
            self.target = target
            self.isError = isError
        }
    }

    public struct AgentState: Sendable, Hashable {
        public var projectId: Int64
        public var name: String
        public var status: AgentStatus
        public var runId: Int64?
        public var step: String?
        public var finishedTools: [ToolState]
        public var error: String?

        public init(projectId: Int64, name: String, status: AgentStatus, runId: Int64? = nil, step: String? = nil, finishedTools: [ToolState] = [], error: String? = nil) {
            self.projectId = projectId
            self.name = name
            self.status = status
            self.runId = runId
            self.step = step
            self.finishedTools = finishedTools
            self.error = error
        }
    }

    public var runs: [Int64: RunState]
    public var agents: [Int64: AgentState]

    public init(runs: [Int64: RunState] = [:], agents: [Int64: AgentState] = [:]) {
        self.runs = runs
        self.agents = agents
    }
}

public enum ActivityDiff {
    public static func events(from old: ActivitySnapshot, to new: ActivitySnapshot, at date: Date) -> [LogEntry] {
        var events: [LogEntry] = []
        for (id, run) in new.runs.sorted(by: { $0.key < $1.key }) {
            let previous = old.runs[id]
            func entry(_ level: LogEntry.Level, _ message: String) -> LogEntry {
                LogEntry(date: date, level: level, source: "engine", projectId: run.projectId, runId: id, step: run.step ?? "", message: message)
            }
            if previous == nil {
                events.append(entry(.info, "\(run.title): run started"))
            }
            if let step = run.step, step != previous?.step {
                events.append(entry(.info, "\(run.title): \(step) started"))
            }
            if let hold = run.hold, hold != previous?.hold {
                events.append(entry(.warning, "\(run.title): waiting on you · \(firstLine(hold))"))
            }
            if run.status != previous?.status, previous != nil {
                switch run.status {
                case .succeeded: events.append(entry(.info, "\(run.title): run finished"))
                case .failed: events.append(entry(.error, "\(run.title): run failed\(run.error.map { " · \(firstLine($0))" } ?? "")"))
                case .cancelled: events.append(entry(.warning, "\(run.title): run cancelled"))
                case .paused: events.append(entry(.warning, "\(run.title): run paused"))
                default: break
                }
            }
        }
        for (id, agent) in new.agents.sorted(by: { $0.key < $1.key }) {
            let previous = old.agents[id]
            func entry(_ level: LogEntry.Level, _ message: String) -> LogEntry {
                LogEntry(date: date, level: level, source: agent.name, projectId: agent.projectId, agentId: id, runId: agent.runId, step: agent.step ?? "", message: message)
            }
            let seen = Set(previous?.finishedTools.map(\.id) ?? [])
            for tool in agent.finishedTools where !seen.contains(tool.id) && previous != nil {
                let text = tool.target.isEmpty ? tool.name.lowercased() : "\(tool.name.lowercased()) \(firstLine(tool.target))"
                events.append(entry(tool.isError ? .warning : .debug, tool.isError ? "\(text) failed" : text))
            }
            guard let previous, previous.status != agent.status else { continue }
            switch agent.status {
            case .needsInput: events.append(entry(.warning, "needs you"))
            case .failed: events.append(entry(.error, "failed\(agent.error.map { " · \(firstLine($0))" } ?? "")"))
            case .working: events.append(entry(.debug, "working"))
            case .idle, .waiting: events.append(entry(.info, "finished its turn"))
            case .paused: events.append(entry(.info, "paused"))
            case .interrupted: events.append(entry(.warning, "interrupted"))
            case .stopped: events.append(entry(.info, "stopped"))
            case .reviewing: events.append(entry(.info, "reviewing"))
            case .takenOver: events.append(entry(.info, "taken over by you"))
            }
        }
        return events
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(157)) + "…" : line
    }
}

public struct LogFilter: Sendable, Hashable {
    public var agentId: Int64?
    public var step: String?
    public var levels: Set<LogEntry.Level>
    public var text: String

    public init(agentId: Int64? = nil, step: String? = nil, levels: Set<LogEntry.Level> = Set(LogEntry.Level.allCases), text: String = "") {
        self.agentId = agentId
        self.step = step
        self.levels = levels
        self.text = text
    }

    public func matches(_ entry: LogEntry) -> Bool {
        if let agentId, entry.agentId != agentId { return false }
        if let step, entry.step != step { return false }
        guard levels.contains(entry.level) else { return false }
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        if needle.hasPrefix("/"), needle.count > 1, let regex = try? Regex(String(needle.dropFirst())).ignoresCase() {
            return entry.message.contains(regex) || entry.source.contains(regex)
        }
        return [entry.message, entry.source, entry.step].contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

@MainActor
@Observable
public final class ActivityLog {
    public private(set) var entries: [LogEntry] = []
    public let capacity: Int
    private var nextID = 1

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public func append(_ drafts: [LogEntry]) {
        guard !drafts.isEmpty else { return }
        for var draft in drafts {
            draft.id = nextID
            nextID += 1
            entries.append(draft)
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func entries(matching filter: LogFilter, projectIds: Set<Int64>? = nil) -> [LogEntry] {
        entries.filter { entry in
            if let projectIds, let project = entry.projectId, !projectIds.contains(project) { return false }
            return filter.matches(entry)
        }
    }

    public func clear() {
        entries = []
    }
}
