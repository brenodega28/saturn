import Foundation

public enum ChatCommand: String, CaseIterable, Sendable, Identifiable {
    case spec
    case status
    case stop
    case retry
    case budget
    case compact

    public var id: Self { self }
    public var name: String { "/" + rawValue }

    public var summary: String {
        switch self {
        case .spec: "Ask the Lead to write or update the spec"
        case .status: "Where the work stands right now"
        case .stop: "Stop the Lead and this chat’s workers"
        case .retry: "Retry the step that failed"
        case .budget: "What this chat has spent so far"
        case .compact: "Shorten the Lead’s context to save tokens"
        }
    }

    public var runsLocally: Bool { self == .stop || self == .retry }

    public static func parse(_ text: String) -> ChatCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.dropFirst().prefix { !$0.isWhitespace }
        return ChatCommand(rawValue: String(word).lowercased())
    }
}

public enum ComposerCompletion: Equatable, Sendable {
    case command(String)
    case file(String)

    public static func token(in text: String) -> ComposerCompletion? {
        if text.hasPrefix("/"), !text.contains(where: \.isWhitespace) {
            return .command(String(text.dropFirst()))
        }
        guard let last = text.split(whereSeparator: \.isWhitespace).last, !text.last!.isWhitespace, last.hasPrefix("@") else { return nil }
        return .file(String(last.dropFirst()))
    }

    public static func commands(matching query: String) -> [ChatCommand] {
        let needle = query.lowercased()
        return ChatCommand.allCases.filter { needle.isEmpty || $0.rawValue.hasPrefix(needle) }
    }

    public static func files(_ paths: [String], matching query: String, limit: Int = 8) -> [String] {
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        var scored: [(path: String, score: Double)] = []
        for path in paths {
            guard let match = FuzzyMatch.match(query, in: path) else { continue }
            scored.append((path, match.score))
        }
        scored.sort { lhs, rhs in lhs.score == rhs.score ? lhs.path.count < rhs.path.count : lhs.score > rhs.score }
        return scored.prefix(limit).map(\.path)
    }

    public static func completing(_ text: String, with completion: String) -> String {
        switch token(in: text) {
        case .command:
            return completion + " "
        case .file(let query):
            return String(text.dropLast(query.count + 1)) + "@" + completion + " "
        case nil:
            return text
        }
    }
}
