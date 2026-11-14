import EnsembleCore
import Foundation

enum SkillPluginAvailability: Error, LocalizedError {
    case claudeMissing

    var errorDescription: String? {
        "Claude Code wasn’t found, so Ensemble can’t install plugins. Check Settings › General."
    }
}

extension AppModel {
    func pluginSkills(for project: Project) -> Set<String> {
        Set(project.id.flatMap { skillPlugins[$0] }?.flatMap(\.skills) ?? [])
    }

    func loadSkillPlugins(for project: Project) async throws {
        guard let id = project.id else { return }
        guard !project.isRemote else {
            skillPlugins[id] = []
            return
        }
        skillPlugins[id] = try await skillPluginInstaller().projectPlugins(in: project.url)
    }

    func installSkillPlugin(_ plugin: String, from source: String, in project: Project) async throws -> SkillPlugin {
        try RemoteProjectUnsupported.check(project, "Installing skill plugins")
        let installed = try await skillPluginInstaller().install(plugin: plugin, from: source, in: project.url)
        try await loadSkillPlugins(for: project)
        return installed
    }

    func hasUncommittedSkillSettings(in project: Project) async -> Bool {
        guard let git = git(for: project) else { return false }
        let status = try? await git.run(["status", "--porcelain", "--", SkillPluginInstaller.settingsPath], in: project.url)
        return !(status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func skillPluginInstaller() throws -> SkillPluginInstaller {
        guard let claude = agents.claudeExecutable else { throw SkillPluginAvailability.claudeMissing }
        return SkillPluginInstaller(claude: claude, runner: runner)
    }
}
