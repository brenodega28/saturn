import Foundation

public enum CheckKind: String, Sendable, Hashable, Codable, CaseIterable {
    case format
    case lint
    case typecheck
    case test
    case scan
}

public struct CheckDefinition: Sendable, Hashable, Codable, Identifiable {
    public static let defaultTimeoutMinutes = 10

    public var name: String
    public var kind: CheckKind
    public var command: String
    public var timeoutMinutes: Int
    public var onEdit: Bool

    public var id: String { name }

    public init(name: String, kind: CheckKind, command: String, timeoutMinutes: Int = defaultTimeoutMinutes, onEdit: Bool = false) {
        self.name = name
        self.kind = kind
        self.command = command
        self.timeoutMinutes = timeoutMinutes
        self.onEdit = onEdit
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, command
        case timeoutMinutes = "timeout_minutes"
        case onEdit = "on_edit"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(CheckKind.self, forKey: .kind)
        self.command = try container.decode(String.self, forKey: .command)
        self.timeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .timeoutMinutes) ?? Self.defaultTimeoutMinutes
        self.onEdit = try container.decodeIfPresent(Bool.self, forKey: .onEdit) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(command, forKey: .command)
        if timeoutMinutes != Self.defaultTimeoutMinutes { try container.encode(timeoutMinutes, forKey: .timeoutMinutes) }
        if onEdit { try container.encode(onEdit, forKey: .onEdit) }
    }
}

public struct ChecksConfig: Sendable, Hashable, Codable {
    public static let fileName = "checks.yaml"
    public static let defaultMaxRounds = 2

    public var checks: [CheckDefinition]
    public var protectedPaths: [String]
    public var maxRounds: Int

    public init(checks: [CheckDefinition] = [], protectedPaths: [String] = [], maxRounds: Int = defaultMaxRounds) {
        self.checks = checks
        self.protectedPaths = protectedPaths
        self.maxRounds = maxRounds
    }

    enum CodingKeys: String, CodingKey {
        case checks
        case protectedPaths = "protected_paths"
        case maxRounds = "max_rounds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.checks = try container.decodeIfPresent([CheckDefinition].self, forKey: .checks) ?? []
        self.protectedPaths = try container.decodeIfPresent([String].self, forKey: .protectedPaths) ?? []
        self.maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? Self.defaultMaxRounds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checks, forKey: .checks)
        if !protectedPaths.isEmpty { try container.encode(protectedPaths, forKey: .protectedPaths) }
        if maxRounds != Self.defaultMaxRounds { try container.encode(maxRounds, forKey: .maxRounds) }
    }

    public func check(named name: String) -> CheckDefinition? {
        checks.first { $0.name == name }
    }

    public func checks(named names: [String]?) -> [CheckDefinition] {
        guard let names, !names.isEmpty else { return checks }
        return names.compactMap(check(named:))
    }

    public var hasTestCheck: Bool {
        checks.contains { $0.kind == .test }
    }

    public var editChecks: [CheckDefinition] {
        checks.filter(\.onEdit)
    }

    public func isProtected(_ relativePath: String) -> Bool {
        protectedPaths.contains { PathGlob($0).matches(relativePath) }
    }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }

    static func validate(_ config: ChecksConfig) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []
        for (index, check) in config.checks.enumerated() {
            let prefix = "checks[\(index)]: "
            if check.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(prefix + "needs a name")
            } else if !seen.insert(check.name).inserted {
                problems.append(prefix + "the name “\(check.name)” is used twice")
            }
            if check.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(prefix + "needs a command")
            }
            if check.timeoutMinutes < 1 {
                problems.append(prefix + "timeout_minutes must be at least 1")
            }
        }
        if config.maxRounds < 1 {
            problems.append("max_rounds must be at least 1")
        }
        for pattern in config.protectedPaths where pattern.trimmingCharacters(in: .whitespaces).isEmpty || pattern.hasPrefix("/") {
            problems.append("protected_paths: “\(pattern)” must be a relative glob such as tests/**")
        }
        return problems
    }
}
