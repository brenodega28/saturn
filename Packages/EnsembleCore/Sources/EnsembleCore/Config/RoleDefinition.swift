import Foundation

public struct RoleDefinition: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var description: String
    public var icon: String
    public var color: String
    public var provider: String
    public var model: String
    public var prompt: String
    public var skills: [String]
    public var docs: [String]
    public var editsCode: Bool
    public var permissionProfile: String
    public var canSpawn: Bool
    public var budgetPerRun: Double?

    public init(
        id: String,
        name: String,
        description: String = "",
        icon: String = "terminal",
        color: String = "claude",
        provider: String = "claude-code",
        model: String = AgentModel.sonnet.rawValue,
        prompt: String = "",
        skills: [String] = [],
        docs: [String] = [],
        editsCode: Bool = true,
        permissionProfile: String = "default",
        canSpawn: Bool = false,
        budgetPerRun: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.color = color
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.skills = skills
        self.docs = docs
        self.editsCode = editsCode
        self.permissionProfile = permissionProfile
        self.canSpawn = canSpawn
        self.budgetPerRun = budgetPerRun
    }

    enum CodingKeys: String, CodingKey {
        case name, description, icon, color, provider, model, prompt, skills, docs
        case editsCode = "edits_code"
        case permissionProfile = "permission_profile"
        case canSpawn = "can_spawn"
        case budgetPerRun = "budget_per_run"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = ""
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "terminal"
        self.color = try container.decodeIfPresent(String.self, forKey: .color) ?? "claude"
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "claude-code"
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? AgentModel.sonnet.rawValue
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        self.skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        self.docs = try container.decodeIfPresent([String].self, forKey: .docs) ?? []
        self.editsCode = try container.decodeIfPresent(Bool.self, forKey: .editsCode) ?? true
        self.permissionProfile = try container.decodeIfPresent(String.self, forKey: .permissionProfile) ?? "default"
        self.canSpawn = try container.decodeIfPresent(Bool.self, forKey: .canSpawn) ?? false
        self.budgetPerRun = try container.decodeIfPresent(Double.self, forKey: .budgetPerRun)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if !description.isEmpty { try container.encode(description, forKey: .description) }
        try container.encode(icon, forKey: .icon)
        try container.encode(color, forKey: .color)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(editsCode, forKey: .editsCode)
        try container.encode(canSpawn, forKey: .canSpawn)
        try container.encode(permissionProfile, forKey: .permissionProfile)
        try container.encodeIfPresent(budgetPerRun, forKey: .budgetPerRun)
        if !skills.isEmpty { try container.encode(skills, forKey: .skills) }
        if !docs.isEmpty { try container.encode(docs, forKey: .docs) }
        try container.encode(prompt, forKey: .prompt)
    }

    public var isReviewer: Bool { !editsCode && !canSpawn }
}
