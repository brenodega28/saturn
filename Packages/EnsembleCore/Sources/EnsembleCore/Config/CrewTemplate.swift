import Foundation
import Yams

public struct CrewTemplate: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let order: Int
    public let crew: [String]
    public let roles: [RoleDefinition]
    public let workflows: [String]
    let directory: URL

    public var crewRoles: [RoleDefinition] {
        crew.compactMap { id in roles.first { $0.id == id } }
    }

    public func install(in repository: URL) throws {
        try ProjectConfigLoader.install(from: directory, repository: repository)
    }

    struct Manifest: Decodable {
        var name: String
        var description: String
        var order: Int?
        var crew: [String]
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
        let roles = yamlFiles(in: directory.appending(path: "roles")).compactMap { file -> RoleDefinition? in
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  var role = try? YAMLDecoder().decode(RoleDefinition.self, from: text)
            else { return nil }
            role.id = file.deletingPathExtension().lastPathComponent
            return role
        }
        let workflows = yamlFiles(in: directory.appending(path: "workflows")).map { $0.deletingPathExtension().lastPathComponent }
        return CrewTemplate(
            id: directory.lastPathComponent,
            name: manifest.name,
            description: manifest.description,
            order: manifest.order ?? .max,
            crew: manifest.crew,
            roles: roles,
            workflows: workflows,
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
        let identity = try await hasIdentity(in: folder, git: git) ? [] : ["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost"]
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
