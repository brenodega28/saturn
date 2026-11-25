import Foundation
import Yams

public struct ConfigIssue: Sendable, Hashable, Identifiable {
    public let file: String
    public let message: String

    public var id: String { file + "|" + message }

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public enum DocReaders: Sendable, Hashable, Codable {
    case all
    case leads
    case coding
    case reviewers
    case roles([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let roles = try? container.decode([String].self) {
            self = .roles(roles)
            return
        }
        switch try container.decode(String.self) {
        case "all": self = .all
        case "leads", "lead": self = .leads
        case "coding": self = .coding
        case "reviewers", "review": self = .reviewers
        case let role: self = .roles([role])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .leads: try container.encode("leads")
        case .coding: try container.encode("coding")
        case .reviewers: try container.encode("reviewers")
        case .roles(let roles): try container.encode(roles)
        }
    }

    public func includes(_ kind: AgentKind) -> Bool {
        switch self {
        case .all: true
        case .leads: kind == .lead
        case .coding: kind == .builder
        case .reviewers: kind == .checker
        case .roles(let ids): ids.contains { AgentKind.guessing(roleID: $0) == kind }
        }
    }
}

public struct DocEntry: Sendable, Hashable, Identifiable, Codable {
    public var title: String
    public var path: String?
    public var prompt: String?
    public var description: String
    public var readers: DocReaders
    public var enabled: Bool

    public var id: String { path ?? title }

    public init(title: String, path: String? = nil, prompt: String? = nil, description: String = "", readers: DocReaders = .all, enabled: Bool = true) {
        self.title = title
        self.path = path
        self.prompt = prompt
        self.description = description
        self.readers = readers
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case title, path, prompt, description, readers, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        self.path = path
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? path.map { ($0 as NSString).lastPathComponent } ?? "Untitled"
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.readers = try container.decodeIfPresent(DocReaders.self, forKey: .readers) ?? .all
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct DocsIndex: Sendable, Hashable, Codable {
    public var docs: [DocEntry]

    public init(docs: [DocEntry] = []) {
        self.docs = docs
    }
}

public struct ProjectConfig: Sendable, Hashable {
    public static let directoryName = ".saturn"

    public var workflows: [WorkflowDefinition]
    public var agents: [AgentProfile]
    public var docs: DocsIndex
    public var checks: ChecksConfig?
    public var review: ReviewPolicy
    public var permissions: PermissionsConfig
    public var preferences: ProjectPreferences
    public var specs: SpecsConfig
    public var issues: [ConfigIssue]
    public var migrationNotices: [MigrationNotice]

    public init(
        workflows: [WorkflowDefinition] = [], agents: [AgentProfile] = [], docs: DocsIndex = DocsIndex(), checks: ChecksConfig? = nil,
        review: ReviewPolicy = ReviewPolicy(), permissions: PermissionsConfig = PermissionsConfig(),
        preferences: ProjectPreferences = ProjectPreferences(), specs: SpecsConfig = SpecsConfig(), issues: [ConfigIssue] = [],
        migrationNotices: [MigrationNotice] = []
    ) {
        self.permissions = permissions
        self.preferences = preferences
        self.specs = specs
        self.workflows = workflows
        self.agents = agents
        self.docs = docs
        self.checks = checks
        self.review = review
        self.issues = issues
        self.migrationNotices = migrationNotices
    }

    public var roles: [RoleDefinition] { AgentKind.allCases.map(\.builtInRole) }

    public var lead: RoleDefinition { AgentKind.lead.builtInRole }

    public func role(_ id: String) -> RoleDefinition? {
        AgentKind(rawValue: id)?.builtInRole
    }

    public func workflow(_ id: String) -> WorkflowDefinition? {
        workflows.first { $0.id == id }
    }

    public func docs(for kind: AgentKind) -> [DocEntry] {
        docs.docs.filter { $0.enabled && $0.readers.includes(kind) }
    }

    public static func directory(in repository: URL) -> URL {
        repository.appending(path: directoryName, directoryHint: .isDirectory)
    }
}

public enum ProjectConfigLoader {
    public static func hasConfig(repository: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: ProjectConfig.directory(in: repository).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func load(repository: URL) -> ProjectConfig {
        let root = ProjectConfig.directory(in: repository)
        var issues: [ConfigIssue] = []
        var notices: [MigrationNotice] = []
        if hasConfig(repository: repository) {
            do {
                notices = try RoleMigration.migrate(repository: repository)
                RoleMigration.keep(notices, for: repository)
            } catch {
                issues.append(ConfigIssue(file: ProjectConfig.directoryName, message: "Couldn’t migrate roles to agent kinds: \(error.localizedDescription)"))
            }
        }

        let workflows: [WorkflowDefinition] = yamlFiles(in: root.appending(path: "workflows")).compactMap { file in
            decode(WorkflowDefinition.self, file: file, relativeTo: repository, issues: &issues).map { workflow in
                var workflow = workflow
                workflow.id = file.deletingPathExtension().lastPathComponent
                return workflow
            }
        }

        let agents: [AgentProfile] = yamlFiles(in: root.appending(path: AgentProfile.directoryName)).compactMap { file in
            decode(AgentProfile.self, file: file, relativeTo: repository, issues: &issues).map { profile in
                var profile = profile
                profile.id = file.deletingPathExtension().lastPathComponent
                return profile
            }
        }

        let docsFile = root.appending(path: "docs.yaml")
        let docs = FileManager.default.fileExists(atPath: docsFile.path)
            ? decode(DocsIndex.self, file: docsFile, relativeTo: repository, issues: &issues) ?? DocsIndex()
            : DocsIndex()

        let checksFile = ChecksConfig.file(in: repository)
        let checks = FileManager.default.fileExists(atPath: checksFile.path)
            ? decode(ChecksConfig.self, file: checksFile, relativeTo: repository, issues: &issues)
            : nil

        let reviewFile = ReviewPolicy.file(in: repository)
        let review = FileManager.default.fileExists(atPath: reviewFile.path)
            ? decode(ReviewPolicy.self, file: reviewFile, relativeTo: repository, issues: &issues) ?? ReviewPolicy()
            : ReviewPolicy()

        let permissionsFile = PermissionsConfig.file(in: repository)
        let permissions = FileManager.default.fileExists(atPath: permissionsFile.path)
            ? decode(PermissionsConfig.self, file: permissionsFile, relativeTo: repository, issues: &issues) ?? PermissionsConfig()
            : PermissionsConfig()

        let specs = loadSpecs(repository: repository, issues: &issues)
        var config = ProjectConfig(
            workflows: workflows, agents: agents, docs: docs, checks: checks, review: review, permissions: permissions,
            preferences: ProjectPreferences.load(repository: repository), specs: specs, issues: issues, migrationNotices: notices
        )
        config.issues += ConfigValidator.validate(config)
        return config
    }

    public static func write(_ workflow: WorkflowDefinition, repository: URL) throws {
        try writeYAML(workflow, to: ProjectConfig.directory(in: repository).appending(path: "workflows/\(workflow.id).yaml"))
    }

    public static func write(_ profile: AgentProfile, repository: URL) throws {
        try writeYAML(profile, to: AgentProfile.file(id: profile.id, in: repository))
    }

    public static func write(_ docs: DocsIndex, repository: URL) throws {
        try writeYAML(docs, to: ProjectConfig.directory(in: repository).appending(path: "docs.yaml"))
    }

    public static func write(_ checks: ChecksConfig, repository: URL) throws {
        try writeYAML(checks, to: ChecksConfig.file(in: repository))
    }

    public static func write(_ permissions: PermissionsConfig, repository: URL) throws {
        try writeYAML(permissions, to: PermissionsConfig.file(in: repository))
    }

    public static func write(_ review: ReviewPolicy, repository: URL) throws {
        try writeYAML(review, to: ReviewPolicy.file(in: repository))
    }

    public static func write(_ specs: SpecsConfig, repository: URL) throws {
        try writeYAML(specs, to: SpecsConfig.file(in: repository))
    }

    public static func loadSpecs(repository: URL) -> SpecsConfig {
        var issues: [ConfigIssue] = []
        return loadSpecs(repository: repository, issues: &issues)
    }

    private static func loadSpecs(repository: URL, issues: inout [ConfigIssue]) -> SpecsConfig {
        let file = SpecsConfig.file(in: repository)
        guard FileManager.default.fileExists(atPath: file.path) else { return SpecsConfig() }
        return decode(SpecsConfig.self, file: file, relativeTo: repository, issues: &issues) ?? SpecsConfig()
    }

    public static func installDefaults(repository: URL) throws {
        guard let defaults = Bundle.module.url(forResource: "Defaults", withExtension: nil) else { return }
        try install(from: defaults, repository: repository)
    }

    static func install(from bundle: URL, repository: URL) throws {
        let root = ProjectConfig.directory(in: repository)
        try copyMissing(from: bundle.appending(path: "workflows"), to: root.appending(path: "workflows"))
        let skills = bundle.appending(path: "skills")
        if FileManager.default.fileExists(atPath: skills.path) {
            try copyMissing(from: skills, to: SkillLibrary.directory(in: repository))
        }
        let ignore = root.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "memory/\nlocal.yaml\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    private static func copyMissing(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = destination.appending(path: file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    public static func encodeYAML<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.width = -1
        return try encoder.encode(value)
    }

    static func writeYAML<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeYAML(value).write(to: file, atomically: true, encoding: .utf8)
    }

    private static func yamlFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func decode<T: Decodable>(_ type: T.Type, file: URL, relativeTo repository: URL, issues: inout [ConfigIssue]) -> T? {
        let name = realPath(of: file).replacingOccurrences(of: realPath(of: repository) + "/", with: "")
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            return try YAMLDecoder().decode(T.self, from: text)
        } catch let error as DecodingError {
            issues.append(ConfigIssue(file: name, message: describe(error)))
        } catch {
            issues.append(ConfigIssue(file: name, message: String(describing: error)))
        }
        return nil
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : keys.joined(separator: ".") + ": "
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context))missing “\(key.stringValue)”"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context))\(context.debugDescription)"
        case .dataCorrupted(let context): return "\(path(context))\(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}

public enum ConfigValidator {
    public static func validate(_ config: ProjectConfig) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let preferencesFile = "\(ProjectConfig.directoryName)/\(ProjectPreferences.fileName)"
        if let workflow = config.preferences.defaultWorkflow, config.workflow(workflow) == nil {
            issues.append(ConfigIssue(file: preferencesFile, message: "default workflow “\(workflow)” doesn’t exist"))
        }

        issues += ReviewPolicy.validate(config.review).map { ConfigIssue(file: "\(ProjectConfig.directoryName)/\(ReviewPolicy.fileName)", message: $0) }
        if let checks = config.checks {
            let file = "\(ProjectConfig.directoryName)/\(ChecksConfig.fileName)"
            issues += ChecksConfig.validate(checks).map { ConfigIssue(file: file, message: $0) }
        }

        for profile in config.agents {
            issues += profile.problems().map { ConfigIssue(file: AgentProfile.relativePath(id: profile.id), message: $0) }
        }

        for workflow in config.workflows {
            let file = "\(ProjectConfig.directoryName)/workflows/\(workflow.id).yaml"
            let stepIDs = Set(workflow.steps.map(\.id))
            if workflow.steps.isEmpty {
                issues.append(ConfigIssue(file: file, message: "a workflow needs at least one step"))
            }
            if stepIDs.count != workflow.steps.count {
                issues.append(ConfigIssue(file: file, message: "step ids must be unique"))
            }
            if stepIDs.contains(WorkflowDefinition.endStepID) {
                issues.append(ConfigIssue(file: file, message: "“end” is reserved and can’t be a step id"))
            }
            for step in workflow.steps {
                let prefix = "steps.\(step.id): "
                switch step.type {
                case .agent, .spawn:
                    if let model = step.model, !ModelCatalog.isValid(model) {
                        issues.append(ConfigIssue(file: file, message: prefix + "model “\(model)” isn’t a known model"))
                    }
                    if let profile = step.profile, config.agentProfile(profile) == nil {
                        issues.append(ConfigIssue(file: file, message: prefix + "agent “\(profile)” isn’t lead, builder, checker or an agent profile in \(ProjectConfig.directoryName)/\(AgentProfile.directoryName)"))
                        continue
                    }
                    guard let agent = config.resolve(step)?.kind else {
                        let kinds = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
                        issues.append(ConfigIssue(file: file, message: prefix + "needs an agent: one of \(kinds)"))
                        continue
                    }
                    if step.type == .spawn, agent != .builder {
                        issues.append(ConfigIssue(file: file, message: prefix + "spawn steps start builders; use agent: builder"))
                    }
                case .condition:
                    if step.condition == nil {
                        issues.append(ConfigIssue(file: file, message: prefix + "needs a condition"))
                    }
                case .check:
                    guard let checks = config.checks, !checks.checks.isEmpty else {
                        if step.checks?.isEmpty == false || step.testFirst {
                            issues.append(ConfigIssue(file: file, message: prefix + "needs checks in \(ProjectConfig.directoryName)/\(ChecksConfig.fileName)"))
                        }
                        continue
                    }
                    for name in step.checks ?? [] where checks.check(named: name) == nil {
                        issues.append(ConfigIssue(file: file, message: prefix + "check “\(name)” doesn’t exist"))
                    }
                    if step.testFirst, !checks.checks(named: step.checks).contains(where: { $0.kind == .test }) {
                        issues.append(ConfigIssue(file: file, message: prefix + "test_first needs a check of kind test"))
                    }
                case .approval, .notify, .gates:
                    break
                }
                for target in step.targets where target != WorkflowDefinition.endStepID && !stepIDs.contains(target) {
                    issues.append(ConfigIssue(file: file, message: prefix + "routes to unknown step “\(target)”"))
                }
            }
        }
        return issues
    }
}
