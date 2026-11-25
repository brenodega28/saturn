import Foundation

extension AgentWorkflowDriver {
    nonisolated static let saturnIdentity = ["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost"]

    @discardableResult
    public func askToCombine(_ conflict: MergeConflict, in run: Run) async throws -> String {
        let git = try requireGit(forRun: run)
        let (session, project) = try builder(owning: conflict.branch, in: run)
        guard let worktree = session.agent.worktreeURL else { throw WorkflowDriverError.notReady("\(displayName(of: session.agent)) has no worktree.") }
        let current = try await git.currentBranch(in: project.url)
        let base = session.agent.baseBranch ?? current ?? "HEAD"
        let staged = BranchConflict(branch: conflict.branch, base: base, mergedBefore: conflict.otherIsBase ? [] : [conflict.other], files: conflict.paths)
        let message = try await stageConflict(staged, in: worktree, git: git)
        clearHandoffs(session.id)
        session.send(message)
        return displayName(of: session.agent)
    }

    public func keep(_ winner: String, resolving conflict: MergeConflict, in run: Run) async throws {
        let git = try requireGit(forRun: run)
        let identity = Self.saturnIdentity
        if conflict.otherIsBase {
            let (session, _) = try builder(owning: conflict.branch, in: run)
            guard let worktree = session.agent.worktreeURL else { throw WorkflowDriverError.notReady("\(displayName(of: session.agent)) has no worktree.") }
            try await commitPending(in: worktree, git: git)
            if winner == conflict.other {
                try await git.run(["checkout", conflict.other, "--"] + conflict.paths, in: worktree)
                try await git.run(identity + ["commit", "-m", "Keep \(conflict.other)’s version of \(conflict.paths.joined(separator: ", "))"], in: worktree)
            } else {
                try await git.run(identity + ["merge", "--no-edit", "-X", "ours", conflict.other], in: worktree)
            }
            return
        }
        let loser = winner == conflict.branch ? conflict.other : conflict.branch
        let (session, _) = try builder(owning: loser, in: run)
        guard let worktree = session.agent.worktreeURL else { throw WorkflowDriverError.notReady("\(displayName(of: session.agent)) has no worktree.") }
        try await commitPending(in: worktree, git: git)
        try await git.run(["checkout", winner, "--"] + conflict.paths, in: worktree)
        try await git.run(identity + ["commit", "-m", "Keep \(winner)’s version of \(conflict.paths.joined(separator: ", "))"], in: worktree)
    }

    public func stageForMergeTool(_ conflict: MergeConflict, in run: Run) async throws -> (worktree: URL, files: [String]) {
        let git = try requireGit(forRun: run)
        let (session, _) = try builder(owning: conflict.branch, in: run)
        guard let worktree = session.agent.worktreeURL else { throw WorkflowDriverError.notReady("\(displayName(of: session.agent)) has no worktree.") }
        try await commitPending(in: worktree, git: git)
        _ = try await git.execute(Self.saturnIdentity + ["merge", "--no-ff", "--no-commit", conflict.other], in: worktree)
        let files = (try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree))?.split(separator: "\n").map(String.init) ?? []
        return (worktree, files.isEmpty ? conflict.paths : files)
    }

    private func builder(owning branch: String, in run: Run) throws -> (AgentSession, Project) {
        let runId = try requireRunID(run)
        guard let project = try runtime.database.project(id: run.projectId) else { throw WorkflowDriverError.notReady("The project is gone.") }
        guard let session = try runtime.runSessions(runId: runId, projectId: run.projectId).first(where: { $0.agent.branch == branch && !$0.agent.readOnly }) else {
            throw WorkflowDriverError.notReady("No agent in this run owns \(branch).")
        }
        guard !session.isRunning, !session.isQueued else {
            throw WorkflowDriverError.notReady("\(displayName(of: session.agent)) is working right now. Pause it first, then resolve the conflict.")
        }
        return (session, project)
    }

    private func commitPending(in worktree: URL, git: GitClient) async throws {
        let status = try await git.run(["status", "--porcelain", "--untracked-files=no"], in: worktree)
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await git.run(Self.saturnIdentity + ["commit", "-am", "Work in progress before resolving a conflict"], in: worktree)
    }
}
