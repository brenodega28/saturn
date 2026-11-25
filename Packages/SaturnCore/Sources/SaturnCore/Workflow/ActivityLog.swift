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
    public var sourceLimits: [String: Int] = [:]
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
        for source in Set(drafts.map(\.source)) {
            guard let limit = sourceLimits[source] else { continue }
            var excess = entries.count { $0.source == source } - limit
            guard excess > 0 else { continue }
            entries.removeAll { entry in
                guard excess > 0, entry.source == source else { return false }
                excess -= 1
                return true
            }
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
