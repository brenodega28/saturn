import Foundation

public enum ProjectPageSection: String, Codable, CaseIterable, Sendable {
    case overview
    case chats
    case agents
    case workflows
    case changes
    case source
    case settings

    public init?(legacyTool: String) {
        switch legacyTool {
        case "changes": self = .changes
        case "agents": self = .agents
        case "workflows": self = .workflows
        case "code": self = .source
        case "settings": self = .settings
        default: return nil
        }
    }
}

public enum ProjectSearch {
    public static func matches(_ name: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
    }
}

public enum WeekSpend {
    public static func byDay(_ costs: [(date: Date, cost: Double)], weekOf date: Date, calendar: Calendar = .current) -> [Double] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        var days = Array(repeating: 0.0, count: 7)
        for entry in costs where week.contains(entry.date) {
            let index = calendar.dateComponents([.day], from: week.start, to: entry.date).day ?? 0
            if days.indices.contains(index) { days[index] += entry.cost }
        }
        return days
    }
}

public enum GitRemote {
    public static func origin(inConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, let equals = line.firstIndex(of: "="), line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    public static func displayName(_ url: String) -> String {
        var name = url
        for prefix in ["https://", "http://", "ssh://", "git://"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let at = name.firstIndex(of: "@"), !name[..<at].contains("/") {
            name = String(name[name.index(after: at)...])
        }
        if let colon = name.firstIndex(of: ":"), !name[..<colon].contains("/") {
            name.replaceSubrange(colon...colon, with: "/")
        }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }
}
