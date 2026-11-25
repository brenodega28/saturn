import Foundation

public enum AgentNaming {
    public static func names(base: String, count: Int, existing: [String]) -> [String] {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 0, !base.isEmpty else { return [] }
        let takenSlugs = Set(existing.map(Slug.make))
        let used = existing.compactMap { number(of: $0, base: base) }
        if used.isEmpty, count == 1, !takenSlugs.contains(Slug.make(base)) {
            return [base]
        }
        var names: [String] = []
        var next = (used.max() ?? 0) + 1
        while names.count < count {
            let candidate = "\(base) \(next)"
            if !takenSlugs.contains(Slug.make(candidate)) {
                names.append(candidate)
            }
            next += 1
        }
        return names
    }

    public static func displayName(of name: String, kind: AgentKind?) -> String {
        guard let kind, kind == .lead, number(of: name, base: kind.name) != nil else { return name }
        return kind.name
    }

    public static func displayName(of agent: Agent, config: ProjectConfig? = nil) -> String {
        displayName(of: agent.name, kind: agent.kind)
    }

    static func number(of name: String, base: String) -> Int? {
        if name.caseInsensitiveCompare(base) == .orderedSame { return 1 }
        let prefix = base + " "
        guard name.count > prefix.count,
              name.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}

extension AppDatabase {
    public func displayName(of agent: Agent) -> String {
        AgentNaming.displayName(of: agent)
    }
}
