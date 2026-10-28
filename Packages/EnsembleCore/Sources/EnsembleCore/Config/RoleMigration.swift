import Foundation
import Yams

public struct MigrationNotice: Sendable, Hashable, Identifiable {
    public let file: String
    public let message: String

    public var id: String { file + "|" + message }

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public enum RoleMigration {
    public static let rolesFolderName = "roles"
    public static let legacyFolderName = "legacy-roles"

    public static func rolesDirectory(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: rolesFolderName, directoryHint: .isDirectory)
    }

    public static func legacyDirectory(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: legacyFolderName, directoryHint: .isDirectory)
    }

    public static func needsMigration(repository: URL) -> Bool {
        FileManager.default.fileExists(atPath: rolesDirectory(in: repository).path)
            || workflowFiles(in: repository).contains { file in
                (try? decodeWorkflow(file))?.steps.contains { $0.legacyRole != nil } == true
            }
    }

    @discardableResult
    public static func migrate(repository: URL) throws -> [MigrationNotice] {
        guard needsMigration(repository: repository) else { return [] }
        var notices: [MigrationNotice] = []
        let roles = loadRoles(in: repository, notices: &notices)
        try migrateWorkflows(in: repository, roles: roles, notices: &notices)
        try migrateDocs(in: repository, roles: roles, notices: &notices)
        try migratePermissions(in: repository, roles: roles, notices: &notices)
        for role in roles.values.sorted(by: { $0.id < $1.id }) where needsSkill(role) {
            try writeSkill(for: role, repository: repository, notices: &notices)
        }
        try moveRolesAside(in: repository, notices: &notices)
        return notices
    }

    static func loadRoles(in repository: URL, notices: inout [MigrationNotice]) -> [String: RoleDefinition] {
        var roles: [String: RoleDefinition] = [:]
        for file in yamlFiles(in: rolesDirectory(in: repository)) {
            let id = file.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  var role = try? YAMLDecoder().decode(RoleDefinition.self, from: text) else {
                notices.append(MigrationNotice(file: relative(file, to: repository), message: "couldn’t read this role; it was kept in \(ProjectConfig.directoryName)/\(legacyFolderName) without migrating it"))
                continue
            }
            role.id = id
            roles[id] = role
        }
        return roles
    }

    static func migrateWorkflows(in repository: URL, roles: [String: RoleDefinition], notices: inout [MigrationNotice]) throws {
        for file in workflowFiles(in: repository) {
            guard var workflow = try? decodeWorkflow(file), workflow.steps.contains(where: { $0.legacyRole != nil }) else { continue }
            let name = relative(file, to: repository)
            for index in workflow.steps.indices {
                guard let roleID = workflow.steps[index].legacyRole else { continue }
                var step = workflow.steps[index]
                var kind: AgentKind
                if let role = roles[roleID] {
                    kind = role.kind
                    if step.model == nil { step.model = role.model }
                    if step.budget == nil, let budget = role.budgetPerRun { step.budget = budget }
                } else {
                    kind = AgentKind.guessing(roleID: roleID)
                    if AgentKind(rawValue: roleID) == nil {
                        notices.append(MigrationNotice(file: name, message: "steps.\(step.id): role “\(roleID)” has no file, so it became a \(kind.name) by its name"))
                    }
                }
                if step.type == .spawn { kind = .builder }
                step.agent = kind
                step.legacyRole = nil
                workflow.steps[index] = step
                let model = step.model.map { " on \($0)" } ?? ""
                notices.append(MigrationNotice(file: name, message: "steps.\(step.id): role “\(roleID)” is now agent \(kind.rawValue)\(model)"))
            }
            try ProjectConfigLoader.writeYAML(workflow, to: file)
        }
    }

    static func migrateDocs(in repository: URL, roles: [String: RoleDefinition], notices: inout [MigrationNotice]) throws {
        let file = ProjectConfig.directory(in: repository).appending(path: "docs.yaml")
        guard !roles.isEmpty, let text = try? String(contentsOf: file, encoding: .utf8),
              var index = try? YAMLDecoder().decode(DocsIndex.self, from: text) else { return }
        var changed = false
        for position in index.docs.indices {
            guard case .roles(let ids) = index.docs[position].readers else { continue }
            let kinds = Set(ids.map { roles[$0]?.kind ?? AgentKind.guessing(roleID: $0) })
            let readers = readers(for: kinds)
            guard readers != index.docs[position].readers else { continue }
            index.docs[position].readers = readers
            changed = true
            notices.append(MigrationNotice(file: relative(file, to: repository), message: "“\(index.docs[position].title)” is now read by \(AgentKind.allCases.filter(kinds.contains).map(\.name).joined(separator: ", "))"))
        }
        if changed { try ProjectConfigLoader.write(index, repository: repository) }
    }

    static func readers(for kinds: Set<AgentKind>) -> DocReaders {
        if kinds == Set(AgentKind.allCases) { return .all }
        if kinds == [.lead] { return .leads }
        if kinds == [.builder] { return .coding }
        if kinds == [.checker] { return .reviewers }
        return .roles(AgentKind.allCases.filter(kinds.contains).map(\.rawValue))
    }

    static func migratePermissions(in repository: URL, roles: [String: RoleDefinition], notices: inout [MigrationNotice]) throws {
        let file = PermissionsConfig.file(in: repository)
        let existing = (try? String(contentsOf: file, encoding: .utf8)).flatMap { try? YAMLDecoder().decode(PermissionsConfig.self, from: $0) }
        var permissions = existing ?? PermissionsConfig()
        var changed = false
        for role in roles.values.sorted(by: { $0.id < $1.id }) {
            let kind = role.kind
            guard role.permissionProfile != PermissionsConfig.defaultProfileID, role.permissionProfile != kind.permissionProfileID,
                  let custom = permissions.profile(role.permissionProfile),
                  let target = permissions.profiles.firstIndex(where: { $0.id == kind.permissionProfileID }) else { continue }
            let added = custom.extraCommands.filter { !permissions.profiles[target].extraCommands.contains($0) }
            guard !added.isEmpty else { continue }
            permissions.profiles[target].extraCommands += added
            changed = true
            notices.append(MigrationNotice(
                file: "\(ProjectConfig.directoryName)/\(PermissionsConfig.fileName)",
                message: "\(kind.name) agents may now also run \(added.joined(separator: ", ")), which role “\(role.id)” allowed through the \(custom.name) profile"
            ))
        }
        if changed { try ProjectConfigLoader.write(permissions, repository: repository) }
    }

    static func needsSkill(_ role: RoleDefinition) -> Bool {
        !role.skills.isEmpty || !role.docs.isEmpty || !isBundledPrompt(role.prompt)
    }

    static func writeSkill(for role: RoleDefinition, repository: URL, notices: inout [MigrationNotice]) throws {
        let folder = SkillLibrary.directory(in: repository).appending(path: role.id, directoryHint: .isDirectory)
        let file = folder.appending(path: "SKILL.md")
        let name = ".claude/skills/\(role.id)/SKILL.md"
        guard !FileManager.default.fileExists(atPath: file.path) else {
            notices.append(MigrationNotice(file: name, message: "already exists, so role “\(role.id)” didn’t overwrite it; its prompt is still in \(ProjectConfig.directoryName)/\(legacyFolderName)"))
            return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try skillMarkdown(for: role).write(to: file, atomically: true, encoding: .utf8)
        notices.append(MigrationNotice(file: name, message: "made from role “\(role.id)” so the Lead can give its expertise to builders and checkers"))
    }

    static func skillMarkdown(for role: RoleDefinition) -> String {
        let description = role.description.nilIfBlank ?? "Expertise from the \(role.name) role"
        var parts = ["---\nname: \(role.id)\ndescription: \(quoted(description))\n---", "# \(role.name)"]
        if let prompt = role.prompt.nilIfBlank { parts.append(prompt) }
        if !role.skills.isEmpty { parts.append("## Related skills\n\n" + role.skills.map { "- \($0)" }.joined(separator: "\n")) }
        if !role.docs.isEmpty { parts.append("## Docs\n\n" + role.docs.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func moveRolesAside(in repository: URL, notices: inout [MigrationNotice]) throws {
        let source = rolesDirectory(in: repository)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = legacyDirectory(in: repository)
        let target = "\(ProjectConfig.directoryName)/\(legacyFolderName)"
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try FileManager.default.moveItem(at: file, to: freeName(for: file.lastPathComponent, in: destination))
            }
            try FileManager.default.removeItem(at: source)
        }
        notices.append(MigrationNotice(file: "\(ProjectConfig.directoryName)/\(rolesFolderName)", message: "moved to \(target); agents are now Lead, Builder or Checker"))
    }

    private static func freeName(for name: String, in directory: URL) -> URL {
        let candidate = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return (2...).lazy
            .map { directory.appending(path: ext.isEmpty ? "\(stem)-\($0)" : "\(stem)-\($0).\(ext)") }
            .first { !FileManager.default.fileExists(atPath: $0.path) } ?? candidate
    }

    static func isBundledPrompt(_ prompt: String) -> Bool {
        sentences(of: prompt).allSatisfy(bundledSentences.contains)
    }

    static func sentences(of text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var sentences: [String] = []
        var current = ""
        for character in normalized {
            if character == " ", let last = current.last, ".!?".contains(last) {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }

    static let bundledSentences: Set<String> = Set(bundledPrompts.flatMap(sentences(of:)))

    static let bundledPrompts: [String] = [
        AgentKind.leadPrompt,
        AgentKind.builderPrompt,
        AgentKind.checkerPrompt,
        """
        You are the Project Manager. Your job is to talk with the user and shape the work before anyone builds it.
        Clarify the goal behind each request. When requirements are ambiguous, ask questions instead of guessing.
        Define the next steps, raise ideas and trade-offs, and break the work into well-scoped tasks that can be
        handed to the right roles. Refine proposals with the user until they are ready to start.
        Do not write code and do not review branches. Stay in conversation and keep the plan clear and short.
        """,
        """
        You are the Tech Lead. When planning, read the request and the codebase, then split the work into
        independent tasks that can be built in parallel without touching the same files. Assign each task to the
        role best suited to it and say which files or folders it owns. Prefer fewer, well-scoped tasks.
        When reviewing, read every branch against the plan and the request. Approve only work you would merge.
        When you request changes, name the agent and file and describe the expected fix.
        """,
        """
        Unless the request fits in one sentence, add a short spec: interfaces, acceptance criteria, out of scope and
        how to verify it. When reviewing, comment rather than gatekeep: read every branch against the plan and its
        acceptance criteria, pin real findings with your confidence, and request changes only for real defects,
        naming the agent and file.
        """,
        """
        You are the Tech Lead. When planning, read the request and the codebase, then plan one task by default:
        one agent working alone is usually faster and easier to test than several. Split into more tasks only when
        every task works and can be tested on its own. Two tasks interfere when one needs the other's output to work,
        or when either can't be tested without the other; if any tasks would interfere, keep them in one task. When
        you do split, say in the summary why the tasks can't interfere. Assign each task to the role best suited to
        it and say which files or folders it owns.
        """,
        """
        You are a careful software engineer. Build exactly the task you were given, follow the conventions you see
        in the codebase, add or update tests, run them, and commit your work to your branch.
        """,
        """
        You review code like a senior engineer: correctness first, then tests, then clarity. Read the diff against
        the base branch and the task. Approve only what you would merge; otherwise request specific changes.
        """,
        """
        You review code like a senior engineer and comment rather than gatekeep: correctness first, then tests, then
        how easy the code will be to change. Read the diff against the base branch, the task and its acceptance
        criteria. Pin only findings worth a person's time, with your confidence. Request changes only for real defects.
        """,
        """
        You are the QA engineer. You work in a temporary worktree where every branch of this run has been merged.
        Run the project's test suites and exercise the changed behavior. Report failures with the exact command,
        the output, and which task they belong to. Never fix code yourself.
        """,
    ]

    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        return "\"\(escaped)\""
    }

    static func workflowFiles(in repository: URL) -> [URL] {
        yamlFiles(in: ProjectConfigLoader.workflowsDirectory(in: repository))
    }

    static func decodeWorkflow(_ file: URL) throws -> WorkflowDefinition {
        try YAMLDecoder().decode(WorkflowDefinition.self, from: String(contentsOf: file, encoding: .utf8))
    }

    private static func yamlFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func relative(_ file: URL, to repository: URL) -> String {
        realPath(of: file).replacingOccurrences(of: realPath(of: repository) + "/", with: "")
    }
}
