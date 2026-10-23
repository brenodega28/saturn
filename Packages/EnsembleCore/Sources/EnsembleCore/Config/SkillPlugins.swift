import Foundation

public struct SkillPlugin: Sendable, Hashable, Identifiable {
    public let id: String
    public let skills: [String]

    public init(id: String, skills: [String]) {
        self.id = id
        self.skills = skills
    }

    public var name: String {
        String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id))
    }
}

public enum SkillPluginError: Error, LocalizedError, Equatable {
    case emptySource
    case emptyPlugin
    case failed(command: String, message: String)
    case unreadableOutput(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .emptySource: "Enter a marketplace, like getsentry/skills."
        case .emptyPlugin: "Enter the plugin to install, like sentry-skills."
        case .failed(let command, let message): "claude plugin \(command) failed: \(message)"
        case .unreadableOutput(let command, let output): "claude plugin \(command) gave an unexpected answer: \(output)"
        }
    }
}

public struct SkillPluginInstaller: Sendable {
    public static let settingsPath = ".claude/settings.json"

    let claude: URL
    let runner: CommandRunner

    public init(claude: URL, runner: CommandRunner) {
        self.claude = claude
        self.runner = runner
    }

    @discardableResult
    public func install(plugin: String, from source: String, in repository: URL) async throws -> SkillPlugin {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let plugin = plugin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw SkillPluginError.emptySource }
        guard !plugin.isEmpty else { throw SkillPluginError.emptyPlugin }

        let added = try await outcome(of: "marketplace add", ["marketplace", "add", source], in: repository)
        guard let marketplace = added["marketplace"] as? String else {
            throw SkillPluginError.unreadableOutput(command: "marketplace add", output: String(describing: added))
        }
        let qualified = plugin.contains("@") ? plugin : "\(plugin)@\(marketplace)"
        let installed = try await outcome(of: "install", ["install", qualified], in: repository)
        let id = installed["pluginId"] as? String ?? qualified
        return try await projectPlugins(in: repository).first { $0.id == id } ?? SkillPlugin(id: id, skills: [])
    }

    public func projectPlugins(in repository: URL) async throws -> [SkillPlugin] {
        let result = try await runner.runChecked(claude, ["plugin", "list", "--json"], in: repository)
        guard let entries = try? JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [[String: Any]] else {
            throw SkillPluginError.unreadableOutput(command: "list", output: result.standardOutput)
        }
        let projectPath = realPath(of: repository)
        let enabled = entries
            .filter { $0["projectEnabled"] as? Bool == true && $0["enabled"] as? Bool != false }
            .sorted { first, _ in first["projectPath"] as? String == projectPath }
        var plugins: [String: SkillPlugin] = [:]
        for entry in enabled {
            guard let id = entry["id"] as? String, plugins[id] == nil else { continue }
            let name = SkillPlugin(id: id, skills: []).name
            let skills = (entry["installPath"] as? String).map { Self.skillNames(plugin: name, installPath: URL(fileURLWithPath: $0)) } ?? []
            plugins[id] = SkillPlugin(id: id, skills: skills)
        }
        return plugins.values.sorted { $0.id < $1.id }
    }

    static func skillNames(plugin: String, installPath: URL) -> [String] {
        let skillsDirectory = installPath.appending(path: "skills", directoryHint: .isDirectory)
        return SkillLibrary.skillFolders(in: skillsDirectory).map { "\(plugin):\($0)" }.sorted()
    }

    private func outcome(of command: String, _ arguments: [String], in repository: URL) async throws -> [String: Any] {
        let result = try await runner.run(claude, ["plugin"] + arguments + ["--scope", "project", "--json"], in: repository)
        let line = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("{") }
        guard let line,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            let output = [result.standardError, result.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit code \(result.exitCode)"
            throw SkillPluginError.unreadableOutput(command: command, output: output)
        }
        guard object["outcome"] as? String == "ok" else {
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no details"
            throw SkillPluginError.failed(command: command, message: message)
        }
        return object
    }
}
