import Foundation

public enum IdleCleanupPolicy {
    public static let finishedRunStatuses: Set<RunStatus> = [.succeeded, .failed, .cancelled]

    public static func isDue(
        _ agent: Agent,
        minutes: Int,
        activeRunIDs: Set<Int64>,
        busyAgentIDs: Set<Int64>,
        now: Date
    ) -> Bool {
        guard minutes > 0, agent.status == .idle, !agent.isPinned, agent.archivedAt == nil, agent.taskId == nil else { return false }
        if let id = agent.id, busyAgentIDs.contains(id) { return false }
        if let runId = agent.runId, activeRunIDs.contains(runId) { return false }
        return now.timeIntervalSince(agent.updatedAt) >= TimeInterval(minutes * 60)
    }

    public static func summary(minutes: Int) -> String {
        guard minutes > 0 else { return "Kept until you delete them" }
        return "Removed after \(minutes) minute\(minutes == 1 ? "" : "s") unless pinned"
    }
}

@MainActor
public final class IdleCleanupScheduler {
    public let runtime: AgentRuntime
    public var gitProvider: @MainActor () -> GitClient?
    public var interval: Duration
    private var loop: Task<Void, Never>?

    public init(runtime: AgentRuntime, interval: Duration = .seconds(60), gitProvider: @escaping @MainActor () -> GitClient? = { nil }) {
        self.runtime = runtime
        self.interval = interval
        self.gitProvider = gitProvider
    }

    public var isRunning: Bool { loop != nil }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sweep()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    @discardableResult
    public func sweep(now: Date = .now) async -> [Int64] {
        guard let git = gitProvider(), let projects = try? runtime.database.openProjects() else { return [] }
        var archived: [Int64] = []
        for project in projects {
            guard let projectId = project.id, project.settings.idleCleanupMinutes > 0 else { continue }
            for session in dueSessions(in: projectId, minutes: project.settings.idleCleanupMinutes, now: now) {
                if await runtime.archiveIdleAgent(session, in: project, git: git, now: now) {
                    archived.append(session.id)
                }
            }
        }
        return archived
    }

    func dueSessions(in projectId: Int64, minutes: Int, now: Date) -> [AgentSession] {
        guard let sessions = try? runtime.sessions(inProject: projectId) else { return [] }
        let runIDs = Array(Set(sessions.compactMap(\.agent.runId)))
        let activeRunIDs = Set(((try? runtime.database.runs(withIDs: runIDs)) ?? [])
            .filter { !IdleCleanupPolicy.finishedRunStatuses.contains($0.status) }
            .compactMap(\.id))
        let busy = Set(sessions.filter { $0.isRunning || $0.isQueued || $0.isStopping }.map(\.id)).union(runtime.settingUp)
        return sessions.filter {
            IdleCleanupPolicy.isDue($0.agent, minutes: minutes, activeRunIDs: activeRunIDs, busyAgentIDs: busy, now: now)
        }
    }
}

extension AgentRuntime {
    public func archiveIdleAgent(_ session: AgentSession, in project: Project, git: GitClient, now: Date = .now) async -> Bool {
        if let path = session.agent.worktreeURL, FileManager.default.fileExists(atPath: path.path) {
            let manager = WorktreeManager(repository: project.url, git: git)
            let target = realPath(of: path)
            if let worktree = try? await manager.list().first(where: { realPath(of: $0.path) == target }) {
                do {
                    try await manager.remove(worktree, force: false, deleteBranch: false)
                } catch {
                    return false
                }
            }
        }
        guard !session.isRunning, !session.isQueued, session.agent.status == .idle else { return false }
        let branch = session.agent.branch.map { " Branch \($0) is kept." } ?? ""
        session.archive(detail: "Idle cleanup removed this agent’s worktree.\(branch)", at: now)
        usageDidChange()
        return true
    }
}
