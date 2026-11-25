import Foundation
import GRDB

public enum CheckSetupNotice {
    public static func title(for project: Project) -> String {
        "Set up checks for \(project.name)"
    }

    @discardableResult
    public static func postIfNeeded(for project: Project, config: ProjectConfig, database: AppDatabase, now: Date = .now) throws -> ChatRequest? {
        guard let projectId = project.id, config.checks == nil, ProjectConfigLoader.hasConfig(repository: project.url) else { return nil }
        let title = title(for: project)
        let alreadyPosted = try database.writer.read { db in
            try ChatRequest
                .filter(ChatRequest.Columns.projectId == projectId)
                .filter(Column("title") == title)
                .fetchCount(db) > 0
        }
        guard !alreadyPosted else { return nil }
        let suggestions = CheckDetector.suggest(repository: project.url)
        return try database.createChatRequest(ChatRequest(
            projectId: projectId, kind: .notice, title: title, body: body(for: suggestions), createdAt: now
        ))
    }

    static func body(for suggestions: CheckSuggestions) -> String {
        guard !suggestions.checks.isEmpty else {
            return "Nothing verifies agents’ work before you review it, and Saturn found no test, lint or format command to suggest. Add your commands in Settings › Checks."
        }
        var lines = ["Nothing verifies agents’ work before you review it yet. Saturn found these in the project (\(suggestions.evidence.joined(separator: ", "))):"]
        lines += suggestions.checks.map { "• \($0.name): \($0.command)" }
        if !suggestions.hasTestCheck {
            lines.append("There is no test command among them, so add one too.")
        }
        lines.append("Add them in Settings › Checks.")
        return lines.joined(separator: "\n")
    }
}
