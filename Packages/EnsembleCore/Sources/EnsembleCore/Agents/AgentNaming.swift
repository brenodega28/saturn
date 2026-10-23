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

    public static func displayName(of name: String, role: RoleDefinition?) -> String {
        guard let role, role.canSpawn, number(of: name, base: role.name) != nil else { return name }
        return role.name
    }

    static func number(of name: String, base: String) -> Int? {
        if name.caseInsensitiveCompare(base) == .orderedSame { return 1 }
        let prefix = base + " "
        guard name.count > prefix.count,
              name.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}
