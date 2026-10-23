import Foundation

public struct ConditionFacts: Sendable, Hashable {
    public var labels: [String]
    public var diff: DiffInfo?
    public var outcomes: [String: String]

    public init(labels: [String], diff: DiffInfo? = nil, outcomes: [String: String] = [:]) {
        self.labels = labels
        self.diff = diff
        self.outcomes = outcomes
    }
}

extension StepCondition {
    public var needsDiff: Bool { pathsAny != nil || diffLinesOver != nil }

    public func evaluate(_ facts: ConditionFacts) -> Bool {
        var checks: [Bool] = []
        if let labelsAny {
            let taskLabels = Set(facts.labels.map { $0.lowercased() })
            checks.append(labelsAny.contains { taskLabels.contains($0.lowercased()) })
        }
        if let pathsAny {
            let paths = facts.diff?.paths ?? []
            let globs = pathsAny.map(PathGlob.init)
            checks.append(paths.contains { path in globs.contains { $0.matches(path) } })
        }
        if let diffLinesOver {
            checks.append((facts.diff?.lines ?? 0) > diffLinesOver)
        }
        if let outcomeOf {
            let actual = facts.outcomes[outcomeOf]
            checks.append(equals.map { actual == $0 } ?? (actual != nil))
        }
        return !checks.isEmpty && checks.allSatisfy(\.self)
    }
}

public struct PathGlob: Sendable, Hashable {
    public let pattern: String
    private let expression: String
    private let matchesBasename: Bool

    public init(_ pattern: String) {
        let trimmed = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        let directoryPattern = trimmed.hasSuffix("/") ? trimmed + "**" : trimmed
        self.pattern = pattern
        self.matchesBasename = !directoryPattern.contains("/")
        self.expression = "^" + Self.translate(directoryPattern) + "$"
    }

    public func matches(_ path: String) -> Bool {
        let normalized = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        if test(normalized) { return true }
        if matchesBasename, let name = normalized.split(separator: "/").last { return test(String(name)) }
        return false
    }

    private func test(_ candidate: String) -> Bool {
        candidate.range(of: expression, options: .regularExpression) != nil
    }

    private static func translate(_ glob: String) -> String {
        var result = ""
        var characters = Array(glob)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    if characters.first == "/" {
                        characters.removeFirst()
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return result
    }
}
