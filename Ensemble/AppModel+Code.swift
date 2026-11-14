import EnsembleCore
import Foundation

struct CodeSource: Identifiable, Hashable {
    static let projectID = "project"

    let id: String
    let title: String
    let branch: String?
    let root: URL
    let baseBranch: String?
    let agent: Agent?
    let role: RoleDefinition?

    var changeAuthor: String { agent.map { AgentNaming.displayName(of: $0) } ?? "you" }
}

extension AppModel {
    func codeSources(for project: Project) -> [CodeSource] {
        guard !project.isRemote else { return [] }
        let projectSource = CodeSource(
            id: CodeSource.projectID, title: "Project checkout", branch: state(for: project).branch,
            root: project.url, baseBranch: nil, agent: nil, role: nil
        )
        let agentSources = agentSessions(in: project)
            .map(\.agent)
            .filter { $0.archivedAt == nil }
            .compactMap { agent -> CodeSource? in
                guard let id = agent.id, let worktree = agent.worktreeURL,
                      FileManager.default.fileExists(atPath: worktree.path) else { return nil }
                return CodeSource(
                    id: "agent-\(id)", title: "\(displayName(of: agent, in: project))’s worktree", branch: agent.branch, root: worktree,
                    baseBranch: agent.baseBranch, agent: agent, role: role(for: agent, in: project)
                )
            }
            .sorted { ($0.agent?.updatedAt ?? .distantPast) > ($1.agent?.updatedAt ?? .distantPast) }
        return [projectSource] + agentSources
    }

    func codeWorkspace(for source: CodeSource) -> CodeWorkspace? {
        git.map { CodeWorkspace(root: source.root, baseBranch: source.baseBranch, git: $0) }
    }

    func codePins(for source: CodeSource) -> [Pin] {
        guard let id = source.agent?.id else { return [] }
        return (try? database.pins(agentId: id)) ?? []
    }

    func codeBrowser(for project: Project) -> CodeBrowser {
        CodeBrowser.shared(for: project, model: self)
    }
}
