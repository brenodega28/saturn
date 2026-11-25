import Foundation

extension AgentRuntime {
    var checkRunner: CheckRunner {
        CheckRunner(environment: setupEnvironment())
    }

    func checkVariables(for agent: Agent, worktree: URL) -> [String: String] {
        var variables = ["SATURN_WORKTREE": worktree.path, "SATURN_AGENT": agent.name]
        if let port = agent.port {
            variables["PORT"] = String(port)
            variables["SATURN_PORT"] = String(port)
        }
        return variables
    }

    func runChecks(_ checks: [CheckDefinition], for agent: Agent, in directory: URL? = nil, label: String) async -> [CheckResult] {
        guard let worktree = directory ?? agent.worktreeURL, let id = agent.id else { return [] }
        let logs = paths.agentDirectory(id).appending(path: "checks/\(label)", directoryHint: .isDirectory)
        return await checkRunner.run(checks, in: worktree, variables: checkVariables(for: agent, worktree: worktree), logDirectory: logs)
    }
}
