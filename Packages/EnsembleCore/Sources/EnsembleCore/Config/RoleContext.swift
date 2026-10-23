import Foundation

public enum TokenEstimate {
    public static func of(_ text: String) -> Int {
        (text.count + 3) / 4
    }
}

public struct RoleContext: Sendable, Hashable {
    public enum SectionKind: String, Sendable, Hashable {
        case prompt
        case fileDoc
        case promptDoc
        case skills
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public let kind: SectionKind
        public let title: String
        public let source: String?
        public let text: String
        public let isTruncated: Bool

        public var id: String { kind.rawValue + "|" + (source ?? title) }
        public var tokens: Int { TokenEstimate.of(text) }
    }

    public enum Warning: Sendable, Hashable, Identifiable {
        case missingSkill(String)
        case missingDoc(String)
        case truncatedDoc(path: String, characters: Int, limit: Int)

        public var id: String {
            switch self {
            case .missingSkill(let name): "skill|" + name
            case .missingDoc(let path): "doc|" + path
            case .truncatedDoc(let path, _, _): "truncated|" + path
            }
        }

        public var message: String {
            switch self {
            case .missingSkill(let name):
                "Skill “\(name)” isn’t in .claude/skills or an installed plugin, so agents start without it."
            case .missingDoc(let path):
                "Document \(path) doesn’t exist in the repository."
            case .truncatedDoc(let path, let characters, let limit):
                "\(path) has \(characters.formatted()) characters; agents read the first \(limit.formatted())."
            }
        }
    }

    public static let defaultDocumentLimit = 40_000

    public let role: RoleDefinition
    public let sections: [Section]
    public let warnings: [Warning]

    public var totalTokens: Int { sections.reduce(0) { $0 + $1.tokens } }

    public var skills: [String] { role.skills }

    public var systemPrompt: String {
        var parts: [String] = []
        if let prompt = sections.first(where: { $0.kind == .prompt }) {
            parts.append("# Role: \(role.name)\n\n\(prompt.text)")
        }
        let documents = sections.filter { $0.kind == .fileDoc || $0.kind == .promptDoc }
        if !documents.isEmpty {
            let body = documents.map { section in
                let heading = section.source.map { "## \(section.title) (\($0))" } ?? "## \(section.title)"
                return heading + "\n\n" + section.text
            }
            parts.append((["# Project documents"] + body).joined(separator: "\n\n"))
        }
        if let skills = sections.first(where: { $0.kind == .skills }) {
            parts.append("# Skills\n\n\(skills.text)")
        }
        return parts.joined(separator: "\n\n")
    }

    public init(role: RoleDefinition, sections: [Section], warnings: [Warning]) {
        self.role = role
        self.sections = sections
        self.warnings = warnings
    }

    public static func build(
        role: RoleDefinition,
        config: ProjectConfig,
        repository: URL,
        pluginSkills: Set<String> = [],
        documentLimit: Int = defaultDocumentLimit
    ) -> RoleContext {
        var sections: [Section] = []
        var warnings: [Warning] = []

        let prompt = role.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            sections.append(Section(kind: .prompt, title: "Role prompt", source: nil, text: prompt, isTruncated: false))
        }

        for doc in config.docs(for: role) {
            if let path = doc.path {
                guard let file = SkillLibrary.file(path, in: repository),
                      let contents = try? String(contentsOf: file, encoding: .utf8) else {
                    warnings.append(.missingDoc(path))
                    continue
                }
                let truncated = contents.count > documentLimit
                var text = truncated ? String(contents.prefix(documentLimit)) : contents
                if truncated {
                    text += "\n\n[Truncated: this is the first \(documentLimit) of \(contents.count) characters of \(path). Read the file for the rest.]"
                    warnings.append(.truncatedDoc(path: path, characters: contents.count, limit: documentLimit))
                }
                sections.append(Section(kind: .fileDoc, title: doc.title, source: path, text: text.trimmingCharacters(in: .whitespacesAndNewlines), isTruncated: truncated))
            } else if let body = doc.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                sections.append(Section(kind: .promptDoc, title: doc.title, source: nil, text: body, isTruncated: false))
            }
        }

        if !role.skills.isEmpty {
            let installed = SkillLibrary.installedSkills(in: repository).union(pluginSkills)
            for skill in role.skills where !installed.contains(skill) {
                warnings.append(.missingSkill(skill))
            }
            let list = role.skills.map { "- \($0)" }.joined(separator: "\n")
            let text = "Use these project skills whenever they apply to your work:\n\(list)"
            sections.append(Section(kind: .skills, title: "Skills", source: nil, text: text, isTruncated: false))
        }

        return RoleContext(role: role, sections: sections, warnings: warnings)
    }
}

public enum SkillLibrary {
    public static let manifestPath = "docs/SKILLS.md"

    public static func directory(in repository: URL) -> URL {
        repository.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    public static func installedSkills(in repository: URL) -> Set<String> {
        Set(skillFolders(in: directory(in: repository)))
    }

    static func skillFolders(in directory: URL) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
            .map(\.lastPathComponent)
    }

    public static func missingSkills(for role: RoleDefinition, in repository: URL, pluginSkills: Set<String> = []) -> [String] {
        let installed = installedSkills(in: repository).union(pluginSkills)
        return role.skills.filter { !installed.contains($0) }
    }

    public static func file(_ relativePath: String, in repository: URL) -> URL? {
        let base = repository.standardizedFileURL
        let file = base.appending(path: relativePath).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    public static func manifest(for config: ProjectConfig, repository: URL) -> String {
        let installed = installedSkills(in: repository)
        var lines = [
            "# Skills",
            "",
            "Which skills each Ensemble role loads. Skills live in `.claude/skills/<name>/SKILL.md`.",
            "Generated by Ensemble from `.ensemble/roles/`; edit the roles to change it.",
            "",
        ]
        for role in config.roles.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            lines.append("## \(role.name)")
            lines.append("")
            if role.skills.isEmpty {
                lines.append("No skills.")
            } else {
                for skill in role.skills {
                    lines.append(installed.contains(skill) ? "- \(skill)" : "- \(skill) (missing from .claude/skills)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public static func writeManifest(for config: ProjectConfig, repository: URL) throws -> URL {
        let file = repository.appending(path: manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest(for: config, repository: repository).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
