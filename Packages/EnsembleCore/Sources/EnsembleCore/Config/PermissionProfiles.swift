import Foundation

public enum PermissionLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case allow
    case ask
    case never

    public var title: String {
        switch self {
        case .allow: "Allow"
        case .ask: "Ask"
        case .never: "Never"
        }
    }
}

public enum PermissionCapability: String, Sendable, Hashable, Codable, CaseIterable {
    case editFiles = "edit_files"
    case runShell = "run_shell"
    case network
    case installPackages = "install_packages"
    case gitPush = "git_push"

    public var title: String {
        switch self {
        case .editFiles: "Edit files"
        case .runShell: "Run shell"
        case .network: "Network"
        case .installPackages: "Install packages"
        case .gitPush: "Git push"
        }
    }

    public func describe(_ request: String) -> String {
        switch self {
        case .editFiles: "edit \(request)"
        case .runShell: "run `\(request)`"
        case .network: request.hasPrefix("http") ? "fetch \(request)" : "use the network: \(request)"
        case .installPackages: "install packages: `\(request)`"
        case .gitPush: "push: `\(request)`"
        }
    }
}

public struct PermissionProfileDefinition: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var levels: [PermissionCapability: PermissionLevel]
    public var extraCommands: [String]

    public init(id: String, name: String, levels: [PermissionCapability: PermissionLevel], extraCommands: [String] = []) {
        self.id = id
        self.name = name
        self.levels = levels
        self.extraCommands = extraCommands
    }

    public func level(_ capability: PermissionCapability) -> PermissionLevel {
        levels[capability] ?? .never
    }

    public var hasAsk: Bool { levels.values.contains(.ask) }

    enum CodingKeys: String, CodingKey {
        case id, name
        case extraCommands = "extra_commands"
    }

    struct CapabilityKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        self.extraCommands = try container.decodeIfPresent([String].self, forKey: .extraCommands) ?? []
        let levels = try decoder.container(keyedBy: CapabilityKey.self)
        var parsed: [PermissionCapability: PermissionLevel] = [:]
        for capability in PermissionCapability.allCases {
            parsed[capability] = try levels.decodeIfPresent(PermissionLevel.self, forKey: CapabilityKey(stringValue: capability.rawValue)) ?? .never
        }
        self.levels = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        var levels = encoder.container(keyedBy: CapabilityKey.self)
        for capability in PermissionCapability.allCases {
            try levels.encode(level(capability), forKey: CapabilityKey(stringValue: capability.rawValue))
        }
        if !extraCommands.isEmpty { try container.encode(extraCommands, forKey: .extraCommands) }
    }
}

public struct PermissionsConfig: Sendable, Hashable, Codable {
    public static let fileName = "permissions.yaml"
    public static let defaultProfileID = "default"

    public var profiles: [PermissionProfileDefinition]

    public init(profiles: [PermissionProfileDefinition] = PermissionsConfig.builtIn) {
        self.profiles = profiles
    }

    public static let builtIn: [PermissionProfileDefinition] = [
        PermissionProfileDefinition(id: "developer", name: "Developer", levels: [
            .editFiles: .allow, .runShell: .allow, .network: .ask, .installPackages: .ask, .gitPush: .never,
        ]),
        PermissionProfileDefinition(id: "reviewer", name: "Reviewer", levels: [
            .editFiles: .never, .runShell: .allow, .network: .allow, .installPackages: .never, .gitPush: .never,
        ]),
        PermissionProfileDefinition(id: "tester", name: "Tester", levels: [
            .editFiles: .never, .runShell: .allow, .network: .allow, .installPackages: .never, .gitPush: .never,
        ]),
        PermissionProfileDefinition(id: "lead", name: "Lead", levels: [
            .editFiles: .never, .runShell: .allow, .network: .allow, .installPackages: .never, .gitPush: .never,
        ]),
        PermissionProfileDefinition(id: "app_testing", name: "App testing", levels: [
            .editFiles: .allow, .runShell: .allow, .network: .allow, .installPackages: .ask, .gitPush: .never,
        ], extraCommands: ["xcodegen", "open", "screencapture", "pkill", "killall"]),
    ]

    public func profile(_ id: String) -> PermissionProfileDefinition? {
        profiles.first { $0.id == id }
    }

    public func resolve(for kind: AgentKind?, readOnly: Bool = false) -> PermissionProfileDefinition {
        let id = kind == .lead && !readOnly ? AgentKind.builder.permissionProfileID : kind?.permissionProfileID ?? (readOnly ? "reviewer" : "developer")
        return profile(id) ?? Self.builtIn.first { $0.id == id }!
    }

    public var knownIDs: [String] { [Self.defaultProfileID] + profiles.map(\.id) }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }
}

public struct PermissionPolicy: Sendable, Hashable {
    public var profile: PermissionProfileDefinition
    public var readOnly: Bool

    public init(profile: PermissionProfileDefinition, readOnly: Bool) {
        self.profile = profile
        self.readOnly = readOnly
    }

    public func level(_ capability: PermissionCapability) -> PermissionLevel {
        if readOnly, [.editFiles, .installPackages, .gitPush].contains(capability) { return .never }
        return profile.level(capability)
    }

    public var hasAsk: Bool { PermissionCapability.allCases.contains { level($0) == .ask } }

    public var commands: [String] {
        let base = readOnly ? AgentPermissions.readOnlyCommands : AgentPermissions.commands
        var commands: [String]
        switch level(.runShell) {
        case .allow: commands = base.filter { !AgentPermissions.installCommands.contains($0) }
        case .ask: commands = AgentPermissions.inspectionCommands
        case .never: commands = []
        }
        if level(.installPackages) == .allow { commands += AgentPermissions.installCommands }
        if level(.gitPush) == .allow { commands.append("git push") }
        return commands + (level(.runShell) == .never ? [] : profile.extraCommands)
    }

    public func capability(ofTool tool: String, input: JSONValue?) -> (PermissionCapability, String)? {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return (.editFiles, input?["file_path"]?.string ?? input?["notebook_path"]?.string ?? "a file")
        case "WebFetch":
            return (.network, input?["url"]?.string ?? "the web")
        case "WebSearch":
            return (.network, "search “\(input?["query"]?.string ?? "")”")
        case "Bash":
            guard let command = input?["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
            if command.hasPrefix("git push") { return (.gitPush, command) }
            if AgentPermissions.installCommands.contains(where: { command == $0 || command.hasPrefix($0 + " ") }) { return (.installPackages, command) }
            if AgentPermissions.networkCommands.contains(where: { command == $0 || command.hasPrefix($0 + " ") }) { return (.network, command) }
            return (.runShell, command)
        default:
            return nil
        }
    }

    public var askMatcher: String? {
        var tools: [String] = []
        if level(.editFiles) == .ask { tools += AgentPermissions.fileWritingTools }
        if level(.network) == .ask { tools += AgentPermissions.webTools }
        if [.runShell, .installPackages, .gitPush, .network].contains(where: { level($0) == .ask }) { tools.append("Bash") }
        return tools.isEmpty ? nil : tools.joined(separator: "|")
    }
}
