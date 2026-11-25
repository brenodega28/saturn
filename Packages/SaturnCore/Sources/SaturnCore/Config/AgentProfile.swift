import Foundation

public struct AgentProfile: Sendable, Hashable, Identifiable, Codable {
    public static let directoryName = "agents"
    public static let reservedIDs: Set<String> = Set(AgentKind.allCases.map(\.rawValue))

    public var id: String
    public var name: String
    public var kind: AgentKind
    public var model: String?
    public var description: String
    public var instructions: String
    public var skills: [String]

    public init(id: String, name: String, kind: AgentKind, model: String? = nil, description: String = "", instructions: String = "", skills: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.model = model
        self.description = description
        self.instructions = instructions
        self.skills = skills
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, model, description, instructions, skills
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)?.trimmingCharacters(in: .whitespaces) ?? ""
        self.name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = try container.decode(String.self, forKey: .kind).trimmingCharacters(in: .whitespaces).lowercased()
        guard let parsed = AgentKind(rawValue: kind), AgentKind.spawnable.contains(parsed) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind must be builder or checker, not “\(kind)”")
        }
        self.kind = parsed
        self.model = try container.decodeIfPresent(String.self, forKey: .model)?.nilIfBlank
        self.description = try container.decodeIfPresent(String.self, forKey: .description)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(description, forKey: .description)
        try container.encode(instructions, forKey: .instructions)
        if !skills.isEmpty { try container.encode(skills, forKey: .skills) }
    }

    public static func file(id: String, in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: "\(directoryName)/\(id).yaml")
    }

    public static func relativePath(id: String) -> String {
        "\(ProjectConfig.directoryName)/\(directoryName)/\(id).yaml"
    }

    public static func idProblem(_ id: String) -> String? {
        if id.isEmpty { return "an agent id can’t be empty" }
        if reservedIDs.contains(id) { return "“\(id)” is reserved for the built-in agent kinds" }
        if !isKebabCase(id) { return "“\(id)” must be lowercase kebab-case, like django-builder" }
        return nil
    }

    public func problems() -> [String] {
        var problems = [Self.idProblem(id)].compactMap(\.self)
        if name.isEmpty { problems.append("needs a name") }
        if let model, !ModelCatalog.isValid(model) { problems.append("model “\(model)” isn’t a known model") }
        return problems
    }

    static func isKebabCase(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }
}

public struct ResolvedAgent: Sendable, Hashable {
    public var kind: AgentKind
    public var model: String?
    public var instructions: String
    public var skills: [String]
    public var name: String?

    public static func resolve(
        profile: AgentProfile?, kind: AgentKind?, model: String?, instructions: String = "", skills: [String] = [], name: String? = nil
    ) -> ResolvedAgent? {
        guard let kind = kind ?? profile?.kind else { return nil }
        let joined = [profile?.instructions ?? "", instructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return ResolvedAgent(
            kind: kind,
            model: model?.nilIfBlank ?? profile?.model,
            instructions: joined,
            skills: skills.isEmpty ? profile?.skills ?? [] : skills,
            name: name?.nilIfBlank ?? profile?.name
        )
    }
}

extension ProjectConfig {
    public func agentProfile(_ id: String?) -> AgentProfile? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    public func resolve(_ step: WorkflowStep) -> ResolvedAgent? {
        ResolvedAgent.resolve(profile: agentProfile(step.profile), kind: step.agent, model: step.model, instructions: step.instructions)
    }
}

extension StepContext {
    public func resolvingProfile(in config: ProjectConfig) -> StepContext {
        guard step.profile != nil, let resolved = config.resolve(step) else { return self }
        var context = self
        context.kind = resolved.kind
        context.step.model = resolved.model
        context.step.instructions = resolved.instructions
        return context
    }
}
