import Foundation
import Yams

public struct BundledSkill: Sendable, Hashable, Identifiable {
    public let name: String
    public let description: String
    let directory: URL

    public var id: String { name }

    public func install(in repository: URL) throws -> Bool {
        let target = SkillLibrary.directory(in: repository).appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: target.appending(path: "SKILL.md").path) else { return false }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let destination = target.appending(path: file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: file, to: destination)
                }
            }
        } else {
            try FileManager.default.copyItem(at: directory, to: target)
        }
        return true
    }

    static func load(in folder: URL) -> [BundledSkill] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
            .map { BundledSkill(name: $0.lastPathComponent, description: SkillLibrary.describe(skillFile: $0.appending(path: "SKILL.md")), directory: $0) }
            .sorted { $0.name < $1.name }
    }
}

public struct CrewTemplate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let order: Int
    public let workflows: [String]
    public let recommendedSkills: [String]
    public let bundledSkills: [BundledSkill]
    let directory: URL

    public func install(in repository: URL) throws {
        try ProjectConfigLoader.install(from: directory, repository: repository)
    }

    struct Manifest: Decodable {
        var name: String
        var description: String
        var order: Int?
        var recommendedSkills: [String]?

        enum CodingKeys: String, CodingKey {
            case name, description, order
            case recommendedSkills = "recommended_skills"
        }
    }
}

public enum CrewTemplates {
    public static let manifestName = "template.yaml"

    public static var bundled: [CrewTemplate] {
        guard let root = Bundle.module.url(forResource: "Templates", withExtension: nil) else { return [] }
        return load(from: root)
    }

    public static func template(_ id: String) -> CrewTemplate? {
        bundled.first { $0.id == id }
    }

    static func load(from root: URL) -> [CrewTemplate] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap(template(in:)).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    static func template(in directory: URL) -> CrewTemplate? {
        guard let text = try? String(contentsOf: directory.appending(path: manifestName), encoding: .utf8),
              let manifest = try? YAMLDecoder().decode(CrewTemplate.Manifest.self, from: text)
        else { return nil }
        let workflows = yamlFiles(in: directory.appending(path: "workflows")).map { $0.deletingPathExtension().lastPathComponent }
        return CrewTemplate(
            id: directory.lastPathComponent,
            name: manifest.name,
            description: manifest.description,
            order: manifest.order ?? .max,
            workflows: workflows,
            recommendedSkills: manifest.recommendedSkills ?? [],
            bundledSkills: BundledSkill.load(in: directory.appending(path: "skills")),
            directory: directory
        )
    }

    public static func createRepository(at folder: URL, template: CrewTemplate?, git: GitClient) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git.run(["init"], in: folder)
        let readme = folder.appending(path: "README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try "# \(folder.lastPathComponent)\n".write(to: readme, atomically: true, encoding: .utf8)
        }
        try template?.install(in: folder)
        try AgentInstructions.setUp(repository: folder)
        try await git.run(["add", "-A"], in: folder)
        let identity = try await hasIdentity(in: folder, git: git) ? [] : ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]
        try await git.run(identity + ["commit", "-m", "Initial commit"], in: folder)
    }

    private static func hasIdentity(in folder: URL, git: GitClient) async throws -> Bool {
        let name = (try? await git.run(["config", "user.name"], in: folder)) ?? ""
        let email = (try? await git.run(["config", "user.email"], in: folder)) ?? ""
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func yamlFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
