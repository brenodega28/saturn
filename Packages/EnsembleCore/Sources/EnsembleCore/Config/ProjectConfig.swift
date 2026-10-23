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

    public func includes(_ role: RoleDefinition) -> Bool {
        switch self {
        case .all: true
        case .leads: role.canSpawn
        case .coding: role.editsCode
        case .reviewers: !role.editsCode && !role.canSpawn
        case .roles(let ids): ids.contains(role.id)
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
    public static let directoryName = ".ensemble"

    public var roles: [RoleDefinition]
    public var workflows: [WorkflowDefinition]
    public var docs: DocsIndex
    public var issues: [ConfigIssue]

    public init(roles: [RoleDefinition] = [], workflows: [WorkflowDefinition] = [], docs: DocsIndex = DocsIndex(), issues: [ConfigIssue] = []) {
        self.roles = roles
        self.workflows = workflows
        self.docs = docs
        self.issues = issues
    }

    public func role(_ id: String) -> RoleDefinition? {
        roles.first { $0.id == id }
    }

    public static let defaultLeadID = "tech-lead"

    public var leadRoles: [RoleDefinition] {
        let leads = roles.filter(\.canSpawn)
        return leads.filter { $0.id == Self.defaultLeadID } + leads.filter { $0.id != Self.defaultLeadID }
    }

    public func workflow(_ id: String) -> WorkflowDefinition? {
        workflows.first { $0.id == id }
    }

    public func docs(for role: RoleDefinition) -> [DocEntry] {
        let indexed = docs.docs.filter { $0.enabled && $0.readers.includes(role) }
        let extra = role.docs
            .filter { path in !indexed.contains { $0.path == path } }
            .map { DocEntry(title: ($0 as NSString).lastPathComponent, path: $0, readers: .roles([role.id])) }
        return indexed + extra
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

        let roles: [RoleDefinition] = yamlFiles(in: root.appending(path: "roles")).compactMap { file in
            decode(RoleDefinition.self, file: file, relativeTo: repository, issues: &issues).map { role in
                var role = role
                role.id = file.deletingPathExtension().lastPathComponent
                return role
            }
        }

        let workflows: [WorkflowDefinition] = yamlFiles(in: root.appending(path: "workflows")).compactMap { file in
            decode(WorkflowDefinition.self, file: file, relativeTo: repository, issues: &issues).map { workflow in
                var workflow = workflow
                workflow.id = file.deletingPathExtension().lastPathComponent
                return workflow
            }
        }

        let docsFile = root.appending(path: "docs.yaml")
        let docs = FileManager.default.fileExists(atPath: docsFile.path)
            ? decode(DocsIndex.self, file: docsFile, relativeTo: repository, issues: &issues) ?? DocsIndex()
            : DocsIndex()

        var config = ProjectConfig(roles: roles, workflows: workflows, docs: docs, issues: issues)
        config.issues += ConfigValidator.validate(config)
        return config
    }

    public static func write(_ role: RoleDefinition, repository: URL) throws {
        try writeYAML(role, to: ProjectConfig.directory(in: repository).appending(path: "roles/\(role.id).yaml"))
    }

    public static func write(_ workflow: WorkflowDefinition, repository: URL) throws {
        try writeYAML(workflow, to: ProjectConfig.directory(in: repository).appending(path: "workflows/\(workflow.id).yaml"))
    }

    public static func write(_ docs: DocsIndex, repository: URL) throws {
        try writeYAML(docs, to: ProjectConfig.directory(in: repository).appending(path: "docs.yaml"))
    }

    public static func deleteRole(_ id: String, repository: URL) throws {
        try FileManager.default.removeItem(at: ProjectConfig.directory(in: repository).appending(path: "roles/\(id).yaml"))
    }

    public static func installDefaults(repository: URL) throws {
        guard let defaults = Bundle.module.url(forResource: "Defaults", withExtension: nil) else { return }
        try install(from: defaults, repository: repository)
    }

    static func install(from bundle: URL, repository: URL) throws {
        let root = ProjectConfig.directory(in: repository)
        for folder in ["roles", "workflows"] {
            let source = bundle.appending(path: folder)
            let destination = root.appending(path: folder)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                let target = destination.appending(path: file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.copyItem(at: file, to: target)
                }
            }
        }
        let ignore = root.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "memory/\nlocal.yaml\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    public static func encodeYAML<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.width = -1
        return try encoder.encode(value)
    }

    private static func writeYAML<T: Encodable>(_ value: T, to file: URL) throws {
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
        let roleIDs = Set(config.roles.map(\.id))

        for role in config.roles {
            let file = "\(ProjectConfig.directoryName)/roles/\(role.id).yaml"
            if !ModelCatalog.isValid(role.model) {
                issues.append(ConfigIssue(file: file, message: "model “\(role.model)” isn’t a known model"))
            }
            if role.provider != "claude-code" {
                issues.append(ConfigIssue(file: file, message: "provider “\(role.provider)” isn’t supported yet; only claude-code"))
            }
            if role.canSpawn && role.editsCode {
                issues.append(ConfigIssue(file: file, message: "a role can’t both spawn agents and edit code"))
            }
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
                    guard let role = step.role else {
                        issues.append(ConfigIssue(file: file, message: prefix + "needs a role"))
                        continue
                    }
                    if !roleIDs.contains(role) {
                        issues.append(ConfigIssue(file: file, message: prefix + "role “\(role)” doesn’t exist"))
                    }
                case .condition:
                    if step.condition == nil {
                        issues.append(ConfigIssue(file: file, message: prefix + "needs a condition"))
                    }
                case .approval, .notify:
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
