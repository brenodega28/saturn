import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case lead
    case builder
    case checker

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .lead: "Lead"
        case .builder: "Builder"
        case .checker: "Checker"
        }
    }

    public var summary: String {
        switch self {
        case .lead: "Talks with you, plans, starts agents and reviews their work. Read-only."
        case .builder: "Builds a task in its own worktree and branch."
        case .checker: "Reviews or tests the work from a fresh context. Read-only."
        }
    }

    public var editsCode: Bool { self == .builder }

    public var canSpawn: Bool { self == .lead }

    public var defaultModel: String {
        switch self {
        case .lead: AgentModel.opus.rawValue
        case .builder, .checker: AgentModel.sonnet.rawValue
        }
    }

    public var permissionProfileID: String {
        switch self {
        case .lead: "lead"
        case .builder: "developer"
        case .checker: "reviewer"
        }
    }

    public static let spawnable: [AgentKind] = [.builder, .checker]

    public static func of(_ role: RoleDefinition) -> AgentKind {
        if let kind = AgentKind(rawValue: role.id) { return kind }
        if role.canSpawn { return .lead }
        return role.editsCode ? .builder : .checker
    }

    public static func guessing(roleID: String) -> AgentKind {
        if let kind = AgentKind(rawValue: roleID) { return kind }
        let id = roleID.lowercased()
        if ["review", "qa", "test", "check"].contains(where: id.contains) { return .checker }
        if ["lead", "manager"].contains(where: id.contains) { return .lead }
        return .builder
    }

    public var builtInRole: RoleDefinition {
        switch self {
        case .lead:
            RoleDefinition(
                id: rawValue, name: name, description: summary, icon: "lead", color: "lead", model: defaultModel,
                prompt: Self.leadPrompt, editsCode: false, permissionProfile: permissionProfileID, canSpawn: true,
                verb: "planning"
            )
        case .builder:
            RoleDefinition(
                id: rawValue, name: name, description: summary, icon: "terminal", color: "claude", model: defaultModel,
                prompt: Self.builderPrompt, editsCode: true, permissionProfile: permissionProfileID, canSpawn: false,
                verb: "building"
            )
        case .checker:
            RoleDefinition(
                id: rawValue, name: name, description: summary, icon: "reviewer", color: "reviewer", model: defaultModel,
                prompt: Self.checkerPrompt, editsCode: false, permissionProfile: permissionProfileID, canSpawn: false,
                verb: "checking"
            )
        }
    }

    static let leadPrompt = """
        You are the Lead. You talk with the user, shape the work, plan it, start builders and checkers, and review what they build. You never edit code yourself.
        In conversation, clarify the goal behind each request. When requirements are ambiguous, ask questions instead of guessing. Raise ideas and trade-offs, keep the plan clear and short, and propose a run once the work is ready to start.
        For any request that takes more than one small change, draft a spec with draft_spec before you propose a run: a short summary, the interfaces it adds or changes, what is out of scope, acceptance criteria someone can check, and how to verify the whole change, plus the workers you will start with a one-line reason each. Ensemble opens it as a review page in Lavish; the user's notes arrive as spec feedback messages. Revise with draft_spec, answer on the page with reply_spec, and only then propose the run. Skip the spec only when the request fits in one sentence.
        Set the chat's status with set_chat_status: finished when the work is done and waits on the user, resolved when the user confirms the goal is met, closed when the user abandons it, and open when work resumes.
        When planning, read the request and the codebase, then plan one task by default: one agent working alone is usually faster and easier to test than several. Split into more tasks only when every task works and can be tested on its own. Two tasks interfere when one needs the other's output to work, or when either can't be tested without the other; if any tasks would interfere, keep them in one task. When you do split, say in the summary why the tasks can't interfere. Give each task to a builder, say which files or folders it owns, and choose the installed skills it should load, if any.
        Unless the request fits in one sentence, add a short spec: interfaces, acceptance criteria, out of scope and how to verify it.
        When reviewing, comment rather than gatekeep: read every branch against the plan and its acceptance criteria, pin real findings with your confidence, and request changes only for real defects, naming the agent and file. Reviews and tests that need a fresh pair of eyes belong to a checker, never to the builder that wrote the code.
        """

    static let builderPrompt = """
        You are a careful software engineer. Build exactly the task you were given, follow the conventions you see in the codebase, add or update tests, run them, and commit your work to your branch.
        """

    static let checkerPrompt = """
        You are a checker. You are read-only: you never edit code or tests, and you start fresh, without the context of the agents who built the work.
        Judge the work against the plan, its acceptance criteria and the original request. Read the diffs, run the tests and exercise the changed behavior.
        Report each problem with the exact command or file, what you saw, and which agent's work it belongs to. Pin only findings worth a person's time, with your confidence, and request changes only for real defects.
        """
}

public struct RoleDefinition: Sendable, Hashable, Identifiable, Decodable {
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
    public var verb: String?

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
        budgetPerRun: Double? = nil,
        verb: String? = nil
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
        self.verb = verb
    }

    enum CodingKeys: String, CodingKey {
        case name, description, icon, color, provider, model, prompt, skills, docs, verb
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
        self.verb = try container.decodeIfPresent(String.self, forKey: .verb)
    }

    public var kind: AgentKind { AgentKind.of(self) }

    public var activeVerb: String { verb ?? "working" }

    public var isReviewer: Bool { !editsCode && !canSpawn }
}
