import Foundation

public struct SetupFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var contents: String
    public var overwrites: Bool

    public var id: String { path }

    public init(path: String, contents: String, overwrites: Bool) {
        self.path = path
        self.contents = contents
        self.overwrites = overwrites
    }
}

public struct SetupProposal: Sendable, Hashable, Codable {
    public static let specFolders = [SpecsConfig.defaultFolder, "\(ProjectConfig.directoryName)/specs"]
    public static let missionFileName = "mission.md"

    public var mission: String
    public var specFolder: String
    public var agents: [AgentProfile]
    public var workflow: WorkflowDefinition
    public var makeDefault: Bool

    public init(mission: String, specFolder: String, agents: [AgentProfile], workflow: WorkflowDefinition, makeDefault: Bool) {
        self.mission = mission
        self.specFolder = specFolder
        self.agents = agents
        self.workflow = workflow
        self.makeDefault = makeDefault
    }

    enum CodingKeys: String, CodingKey {
        case mission, agents, workflow
        case specFolder = "spec_folder"
        case makeDefault = "make_default"
    }

    private struct WorkflowID: Decodable {
        var id: String?
    }

    private struct Identified<Value: Encodable>: Encodable {
        enum Key: String, CodingKey { case id }
        var id: String
        var value: Value

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(id, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mission = try container.decode(String.self, forKey: .mission).trimmingCharacters(in: .whitespacesAndNewlines)
        self.specFolder = try container.decode(String.self, forKey: .specFolder).trimmingCharacters(in: .whitespaces)
        self.agents = try container.decodeIfPresent([AgentProfile].self, forKey: .agents) ?? []
        var workflow = try container.decode(WorkflowDefinition.self, forKey: .workflow)
        workflow.id = try container.decode(WorkflowID.self, forKey: .workflow).id?.trimmingCharacters(in: .whitespaces) ?? ""
        self.workflow = workflow
        self.makeDefault = try container.decodeIfPresent(Bool.self, forKey: .makeDefault) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mission, forKey: .mission)
        try container.encode(specFolder, forKey: .specFolder)
        try container.encode(agents.map { Identified(id: $0.id, value: $0) }, forKey: .agents)
        try container.encode(Identified(id: workflow.id, value: workflow), forKey: .workflow)
        try container.encode(makeDefault, forKey: .makeDefault)
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func decode(json: String) -> SetupProposal? {
        try? JSONDecoder().decode(SetupProposal.self, from: Data(json.utf8))
    }

    public var workflowPath: String {
        "\(ProjectConfig.directoryName)/workflows/\(workflow.id).yaml"
    }

    public func validate(against config: ProjectConfig) -> [String] {
        var errors: [String] = []
        if !Self.specFolders.contains(specFolder) {
            errors.append("spec_folder must be “spec” or “.saturn/specs”, not “\(specFolder)”")
        }
        if mission.isEmpty { errors.append("mission can’t be empty") }
        var seen = Set<String>()
        for agent in agents {
            let label = agent.id.isEmpty ? "agents" : "agent “\(agent.id)”"
            if !agent.id.isEmpty, !seen.insert(agent.id).inserted { errors.append("agent id “\(agent.id)” is used more than once") }
            errors += agent.problems().map { "\(label): \($0)" }
            if agent.instructions.isEmpty { errors.append("\(label): needs instructions") }
        }
        if !AgentProfile.isKebabCase(workflow.id) {
            errors.append("workflow: needs an id in lowercase kebab-case, like django-delivery")
        }
        var proposed = config
        proposed.agents = config.agents.filter { profile in !agents.contains { $0.id == profile.id } } + agents
        proposed.workflows = config.workflows.filter { $0.id != workflow.id } + [workflow]
        if makeDefault { proposed.preferences.defaultWorkflow = workflow.id }
        errors += ConfigValidator.validate(proposed).filter { $0.file == workflowPath }.map { "workflow: \($0.message)" }
        return errors
    }

    public func files(in repository: URL, onboardingVersion: Int = OnboardingDefinition.bundled.version, now: Date = .now) -> [SetupFile] {
        func yaml<T: Encodable>(_ value: T) -> String { (try? ProjectConfigLoader.encodeYAML(value)) ?? "" }
        var entries: [(String, String)] = [
            ("\(specFolder)/\(Self.missionFileName)", mission + "\n"),
            ("\(ProjectConfig.directoryName)/\(SpecsConfig.fileName)", yaml(SpecsConfig(folder: specFolder))),
        ]
        entries += agents.map { (AgentProfile.relativePath(id: $0.id), yaml($0)) }
        entries.append((workflowPath, yaml(workflow)))
        if makeDefault {
            var preferences = ProjectPreferences.load(repository: repository)
            preferences.defaultWorkflow = workflow.id
            entries.append(("\(ProjectConfig.directoryName)/\(ProjectPreferences.fileName)", yaml(preferences)))
        }
        entries.append((OnboardingRecord.relativePath, yaml(OnboardingRecord(version: onboardingVersion, completedAt: now))))
        return entries.map { path, contents in
            SetupFile(path: path, contents: contents, overwrites: FileManager.default.fileExists(atPath: repository.appending(path: path).path))
        }
    }

    @discardableResult
    public func apply(to repository: URL, onboardingVersion: Int = OnboardingDefinition.bundled.version, now: Date = .now) throws -> [SetupFile] {
        let files = files(in: repository, onboardingVersion: onboardingVersion, now: now)
        for file in files {
            let url = repository.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return files
    }
}
