import Foundation

public enum ProjectOutline {
    public enum Tone: Sendable, Hashable {
        case quiet
        case warning
        case danger
    }

    public struct Badge: Sendable, Hashable {
        public let count: Int
        public let tone: Tone

        public init(count: Int, tone: Tone) {
            self.count = count
            self.tone = tone
        }
    }

    public struct Summary: Sendable, Hashable {
        public let text: String
        public let tone: Tone
    }

    public static let defaultExpanded: Set<String> = ["lead", "tasks", "changes"]

    public static func attention(_ waiting: [InboxItem]) -> Tone {
        if waiting.contains(where: { $0.kind == .failure }) { return .danger }
        return waiting.isEmpty ? .quiet : .warning
    }

    public static func tasksBadge(waiting: [InboxItem]) -> Badge? {
        let items = waiting.filter { $0.kind != .pinReview }
        guard !items.isEmpty else { return nil }
        return Badge(count: items.count, tone: attention(items))
    }

    public static func changesBadge(waiting: [InboxItem]) -> Badge? {
        let pins = waiting.filter { $0.kind == .pinReview }.count
        return pins > 0 ? Badge(count: pins, tone: .warning) : nil
    }

    public static func countBadge(_ count: Int, tone: Tone = .quiet) -> Badge? {
        count > 0 ? Badge(count: count, tone: tone) : nil
    }

    public static func statusSummary(activeRuns: Int, needsYou: Int, failing: Int) -> Summary {
        var parts: [String] = []
        if activeRuns > 0 { parts.append("\(activeRuns) run\(activeRuns == 1 ? "" : "s")") }
        if failing > 0 { parts.append("\(failing) failing") }
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        let tone: Tone = failing > 0 ? .danger : needsYou > 0 ? .warning : .quiet
        return Summary(text: parts.isEmpty ? "idle" : parts.joined(separator: " · "), tone: tone)
    }

    public static func abbreviatedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return path }
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }

    public static func branchLine(branch: String?, worktrees: Int) -> String {
        "\(branch ?? "no branch") · \(worktrees) worktree\(worktrees == 1 ? "" : "s")"
    }

    public static func pinsLabel(_ count: Int) -> String {
        "\(count) pin\(count == 1 ? "" : "s")"
    }

    public static func decodeExpanded(_ stored: String?) -> Set<String> {
        guard let stored else { return defaultExpanded }
        return Set(stored.split(separator: ",").map(String.init))
    }

    public static func encodeExpanded(_ sections: Set<String>) -> String {
        sections.sorted().joined(separator: ",")
    }

    public static func toggling(_ section: String, in stored: String?) -> String {
        var sections = decodeExpanded(stored)
        if sections.contains(section) { sections.remove(section) } else { sections.insert(section) }
        return encodeExpanded(sections)
    }
}
