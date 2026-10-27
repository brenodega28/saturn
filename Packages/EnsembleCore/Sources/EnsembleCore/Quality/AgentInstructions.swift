import Foundation

public struct AgentInstructionsStatus: Sendable, Hashable {
    public var hasAgentsFile: Bool
    public var claudePointsToAgents: Bool
    public var lineCount: Int
    public var characterCount: Int

    public init(hasAgentsFile: Bool, claudePointsToAgents: Bool, lineCount: Int, characterCount: Int) {
        self.hasAgentsFile = hasAgentsFile
        self.claudePointsToAgents = claudePointsToAgents
        self.lineCount = lineCount
        self.characterCount = characterCount
    }

    public var isTooLong: Bool {
        lineCount > AgentInstructions.maxLines || characterCount > AgentInstructions.maxCharacters
    }

    public var isSetUp: Bool { hasAgentsFile && claudePointsToAgents }
}

public enum AgentInstructions {
    public static let fileName = "AGENTS.md"
    public static let claudeFileName = "CLAUDE.md"
    public static let claudePointer = "@AGENTS.md"
    public static let learnedHeading = "## Learned from review"
    public static let maxLines = 60
    public static let maxCharacters = 4000

    public static func status(repository: URL) -> AgentInstructionsStatus {
        let agents = try? String(contentsOf: repository.appending(path: fileName), encoding: .utf8)
        let claude = try? String(contentsOf: repository.appending(path: claudeFileName), encoding: .utf8)
        return AgentInstructionsStatus(
            hasAgentsFile: agents != nil,
            claudePointsToAgents: claude?.contains(fileName) == true,
            lineCount: agents.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0,
            characterCount: agents?.count ?? 0
        )
    }

    @discardableResult
    public static func setUp(repository: URL) throws -> [String] {
        let agentsURL = repository.appending(path: fileName)
        let claudeURL = repository.appending(path: claudeFileName)
        var written: [String] = []
        let claude = try? String(contentsOf: claudeURL, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: agentsURL.path) {
            let imported = claude.map { $0.replacingOccurrences(of: claudePointer, with: "").trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let contents = imported.isEmpty ? template(repository: repository) : imported + "\n"
            try contents.write(to: agentsURL, atomically: true, encoding: .utf8)
            written.append(fileName)
            if !imported.isEmpty {
                try (claudePointer + "\n").write(to: claudeURL, atomically: true, encoding: .utf8)
                written.append(claudeFileName)
                return written
            }
        }
        let current = try? String(contentsOf: claudeURL, encoding: .utf8)
        if current?.contains(fileName) != true {
            let rest = current.map { "\n\n" + $0 } ?? "\n"
            try (claudePointer + rest).write(to: claudeURL, atomically: true, encoding: .utf8)
            written.append(claudeFileName)
        }
        return written
    }

    public static func template(repository: URL) -> String {
        let checks = ProjectConfigLoader.load(repository: repository).checks?.checks ?? CheckDetector.suggest(repository: repository).checks
        var lines = [
            "# Agent instructions",
            "",
            "Only what an agent can't work out from the code. Keep this under a page; enforce anything that matters with a check or a hook instead.",
            "",
            "## Commands",
        ]
        lines += checks.isEmpty ? ["- Add the exact commands to build, lint and test this project."] : checks.map { "- \($0.name.capitalized): `\($0.command)`" }
        lines += ["", "## Conventions", "", "## Gotchas", ""]
        return lines.joined(separator: "\n")
    }

    public static func appendLearned(_ rule: String, repository: URL) throws {
        try setUp(repository: repository)
        let url = repository.appending(path: fileName)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = "- " + rule.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
        if !text.contains(learnedHeading) {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + learnedHeading + "\n"
        }
        if !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func commit(_ paths: [String], message: String, repository: URL, git: GitClient) async throws {
        try await git.run(["add", "--"] + paths, in: repository)
        try await git.run(["-c", "user.name=\(try await identity("user.name", fallback: "Ensemble", repository: repository, git: git))",
                           "-c", "user.email=\(try await identity("user.email", fallback: "ensemble@localhost", repository: repository, git: git))",
                           "commit", "-m", message, "--"] + paths, in: repository)
    }

    private static func identity(_ key: String, fallback: String, repository: URL, git: GitClient) async throws -> String {
        let value = (try? await git.run(["config", key], in: repository))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }
}

public enum CorrectionEncoding: Sendable, Hashable {
    case instruction(String)
    case check(CheckDefinition)
    case protectedPath(String)

    public var summary: String {
        switch self {
        case .instruction(let line): "AGENTS.md: \(line)"
        case .check(let check): "Check \(check.name): \(check.command)"
        case .protectedPath(let glob): "Protected path \(glob)"
        }
    }

    public static func suggestions(for correction: Correction) -> (instruction: String, protectedPath: String?) {
        let directory = correction.file.map { ($0 as NSString).deletingLastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let instruction = directory.map { "\(correction.text) (in \($0)/)" } ?? correction.text
        return (instruction, directory.map { "\($0)/**" })
    }
}

extension AppDatabase {
    public func encode(_ correction: Correction, as encoding: CorrectionEncoding, repository: URL, git: GitClient, now: Date = .now) async throws {
        let paths: [String]
        switch encoding {
        case .instruction(let line):
            try AgentInstructions.appendLearned(line, repository: repository)
            paths = [AgentInstructions.fileName, AgentInstructions.claudeFileName].filter {
                FileManager.default.fileExists(atPath: repository.appending(path: $0).path)
            }
        case .check(let check):
            var checks = ProjectConfigLoader.load(repository: repository).checks ?? ChecksConfig()
            checks.checks.removeAll { $0.name == check.name }
            checks.checks.append(check)
            try ProjectConfigLoader.write(checks, repository: repository)
            paths = ["\(ProjectConfig.directoryName)/\(ChecksConfig.fileName)"]
        case .protectedPath(let glob):
            var checks = ProjectConfigLoader.load(repository: repository).checks ?? ChecksConfig()
            if !checks.protectedPaths.contains(glob) { checks.protectedPaths.append(glob) }
            try ProjectConfigLoader.write(checks, repository: repository)
            paths = ["\(ProjectConfig.directoryName)/\(ChecksConfig.fileName)"]
        }
        let subject = correction.text.count > 60 ? String(correction.text.prefix(57)) + "…" : correction.text
        try await AgentInstructions.commit(paths, message: "Encode review correction: \(subject)", repository: repository, git: git)
        try markEncoded(correction, encoding: encoding.summary, now: now)
    }
}
