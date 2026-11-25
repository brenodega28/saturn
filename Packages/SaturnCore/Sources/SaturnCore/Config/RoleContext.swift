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
                "Skill “\(name)” isn’t in .claude/skills, ~/.claude/skills or an installed plugin, so agents start without it."
            case .missingDoc(let path):
                "Document \(path) doesn’t exist in the repository."
            case .truncatedDoc(let path, let characters, let limit):
                "\(path) has \(characters.formatted()) characters; agents read the first \(limit.formatted())."
            }
        }
    }

    public static let defaultDocumentLimit = 40_000

    public let kind: AgentKind
    public let skills: [String]
    public let sections: [Section]
    public let warnings: [Warning]

    public var role: RoleDefinition { kind.builtInRole }

    public var totalTokens: Int { sections.reduce(0) { $0 + $1.tokens } }

    public var systemPrompt: String {
        var parts: [String] = []
        if let prompt = sections.first(where: { $0.kind == .prompt }) {
            parts.append("# Role: \(kind.name)\n\n\(prompt.text)")
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

    public init(kind: AgentKind, skills: [String], sections: [Section], warnings: [Warning]) {
        self.kind = kind
        self.skills = skills
        self.sections = sections
        self.warnings = warnings
    }

    public static func build(
        kind: AgentKind,
        skills: [String] = [],
        config: ProjectConfig,
        repository: URL,
        pluginSkills: Set<String> = [],
        documentLimit: Int = defaultDocumentLimit
    ) -> RoleContext {
        var sections: [Section] = []
        var warnings: [Warning] = []

        let prompt = kind.builtInRole.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            sections.append(Section(kind: .prompt, title: "Role prompt", source: nil, text: prompt, isTruncated: false))
        }

        for doc in config.docs(for: kind) {
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

        if !skills.isEmpty {
            let installed = SkillLibrary.installedSkills(in: repository).union(pluginSkills)
            for skill in skills where !installed.contains(skill) {
                warnings.append(.missingSkill(skill))
            }
            let list = skills.map { "- \($0)" }.joined(separator: "\n")
            let text = "Your lead chose these skills for this work. Load each one with the Skill tool before you start, and follow it whenever it applies:\n\(list)"
            sections.append(Section(kind: .skills, title: "Skills", source: nil, text: text, isTruncated: false))
        }

        return RoleContext(kind: kind, skills: skills, sections: sections, warnings: warnings)
    }
}

public struct InstalledSkill: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, CaseIterable {
        case project
        case plugin
        case global

        public var title: String {
            switch self {
            case .project: "Project"
            case .plugin: "Plugin"
            case .global: "Global"
            }
        }

        public var location: String {
            switch self {
            case .project: ".claude/skills"
            case .plugin: "an installed plugin"
            case .global: "~/.claude/skills"
            }
        }
    }

    public let name: String
    public let source: Source
    public let description: String

    public var id: String { name }

    public init(name: String, source: Source, description: String = "") {
        self.name = name
        self.source = source
        self.description = description
    }
}

public enum SkillLibrary {
    public static func directory(in repository: URL) -> URL {
        repository.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    public static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func globalDirectory(home: URL = homeDirectory) -> URL {
        home.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    public static func installedSkills(in repository: URL, home: URL = homeDirectory) -> Set<String> {
        Set(skillFolders(in: directory(in: repository))).union(skillFolders(in: globalDirectory(home: home)))
    }

    public static func skills(in repository: URL, pluginSkills: Set<String> = [], home: URL = homeDirectory) -> [InstalledSkill] {
        var seen: Set<String> = []
        var skills: [InstalledSkill] = []
        func add(_ names: [String], source: InstalledSkill.Source, folder: URL?) {
            for name in names.sorted() where seen.insert(name).inserted {
                let description = folder.map { describe(skillFile: $0.appending(path: name).appending(path: "SKILL.md")) } ?? ""
                skills.append(InstalledSkill(name: name, source: source, description: description))
            }
        }
        add(skillFolders(in: directory(in: repository)), source: .project, folder: directory(in: repository))
        add(Array(pluginSkills), source: .plugin, folder: nil)
        add(skillFolders(in: globalDirectory(home: home)), source: .global, folder: globalDirectory(home: home))
        return skills
    }

    static func skillFolders(in directory: URL) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
            .map(\.lastPathComponent)
    }

    static func describe(skillFile: URL) -> String {
        guard let text = try? String(contentsOf: skillFile, encoding: .utf8), text.hasPrefix("---") else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard line.hasPrefix("description:") else { continue }
            let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
    }

    public static func unknownSkills(_ skills: [String], in repository: URL, pluginSkills: Set<String> = [], home: URL = homeDirectory) -> [String] {
        let installed = installedSkills(in: repository, home: home).union(pluginSkills)
        return skills.filter { !installed.contains($0) }
    }

    public static func file(_ relativePath: String, in repository: URL) -> URL? {
        let base = repository.standardizedFileURL
        let file = base.appending(path: relativePath).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
