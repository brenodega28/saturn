import Foundation
import Yams

public struct ProjectPreferences: Sendable, Hashable, Codable {
    public static let fileName = "project.yaml"
    public static let defaultBranchPrefix = "crew"

    public var baseBranch: String?
    public var branchPrefix: String
    public var defaultLead: String?
    public var defaultWorkflow: String?
    public var approvePlans: Bool

    public init(
        baseBranch: String? = nil, branchPrefix: String = ProjectPreferences.defaultBranchPrefix,
        defaultLead: String? = nil, defaultWorkflow: String? = nil, approvePlans: Bool = true
    ) {
        self.baseBranch = baseBranch
        self.branchPrefix = branchPrefix
        self.defaultLead = defaultLead
        self.defaultWorkflow = defaultWorkflow
        self.approvePlans = approvePlans
    }

    enum CodingKeys: String, CodingKey {
        case baseBranch = "base_branch"
        case branchPrefix = "branch_prefix"
        case defaultLead = "default_lead"
        case defaultWorkflow = "default_workflow"
        case approvePlans = "approve_plans"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)?.nilIfBlank
        self.branchPrefix = Self.cleanPrefix(try container.decodeIfPresent(String.self, forKey: .branchPrefix))
        self.defaultLead = try container.decodeIfPresent(String.self, forKey: .defaultLead)?.nilIfBlank
        self.defaultWorkflow = try container.decodeIfPresent(String.self, forKey: .defaultWorkflow)?.nilIfBlank
        self.approvePlans = try container.decodeIfPresent(Bool.self, forKey: .approvePlans) ?? true
    }

    public static func cleanPrefix(_ prefix: String?) -> String {
        let trimmed = (prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? defaultBranchPrefix : trimmed
    }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }

    public static func load(repository: URL) -> ProjectPreferences {
        guard let text = try? String(contentsOf: file(in: repository), encoding: .utf8),
              let preferences = try? YAMLDecoder().decode(ProjectPreferences.self, from: text) else { return ProjectPreferences() }
        return preferences
    }
}

extension ProjectConfigLoader {
    public static func write(_ preferences: ProjectPreferences, repository: URL) throws {
        try writeYAML(preferences, to: ProjectPreferences.file(in: repository))
    }
}

extension GitClient {
    public func baseBranch(of repository: URL) async throws -> String? {
        if let preferred = ProjectPreferences.load(repository: repository).baseBranch,
           (try? await hasCommit("refs/heads/\(preferred)", in: repository)) == true {
            return preferred
        }
        return try await currentBranch(in: repository)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
