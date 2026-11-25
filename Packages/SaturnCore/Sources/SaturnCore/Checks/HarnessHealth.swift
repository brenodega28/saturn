import Foundation

public struct HarnessReport: Sendable, Hashable, Codable {
    public var setupError: String?
    public var results: [CheckResult]
    public var problems: [String]
    public var finishedAt: Date

    public var isHealthy: Bool { problems.isEmpty }
}

extension AgentRuntime {
    public static let healthWorktreeName = "health-check"

    public func checkHarness(of project: Project, git: GitClient) async throws -> HarnessReport {
        try Self.refuseSSHProject(project)
        let config = ProjectConfigLoader.load(repository: project.filesRoot)
        let checks = config.checks?.checks ?? []
        var problems: [String] = []
        if checks.isEmpty {
            problems.append("No checks are set up, so agents’ work isn’t verified. Add them in \(ProjectConfig.directoryName)/\(ChecksConfig.fileName).")
        } else if !(config.checks?.hasTestCheck ?? false) {
            problems.append("No check of kind test, so agents’ work isn’t verified by tests.")
        }
        guard !checks.isEmpty, let projectId = project.id else {
            return HarnessReport(setupError: nil, results: [], problems: problems, finishedAt: .now)
        }

        let manager = WorktreeManager(project: project, git: git)
        let path = manager.crewDirectory.appending(path: Self.healthWorktreeName, directoryHint: .isDirectory)
        _ = try? await git.run(["worktree", "remove", "--force", path.path], in: project.url)
        try? await git.fileSystem.removeItem(path)
        try await manager.ensureExcluded()
        try await git.fileSystem.createDirectory(manager.crewDirectory)
        try await git.run(["worktree", "add", "--detach", path.path, "HEAD"], in: project.url)

        let logs = paths.pendingWorkspaceDirectory(Self.healthWorktreeName)
        var setupError: String?
        if needsSetup(projectId: projectId), let hook = worktreePrepared {
            do {
                try await hook(WorktreePreparation(
                    projectId: projectId, agentID: nil, agentName: Self.healthWorktreeName, worktree: path,
                    port: try nextPort(forProject: projectId), logDirectory: logs
                ))
            } catch {
                setupError = error.localizedDescription
                problems.append("The setup script fails in a fresh worktree, so agents start without dependencies: \(error.localizedDescription)")
            }
        }

        let results = await checkRunner.run(checks, in: path, variables: ["SATURN_WORKTREE": path.path, "SATURN_AGENT": Self.healthWorktreeName], logDirectory: logs.appending(path: "checks"))
        _ = try? await git.run(["worktree", "remove", "--force", path.path], in: project.url)
        for result in results where !result.passed {
            problems.append("\(result.headline) on a clean checkout. Agents can’t get it green unless it passes here first: check its command, dependencies, network access or credentials.")
        }
        return HarnessReport(setupError: setupError, results: results, problems: problems, finishedAt: .now)
    }
}
