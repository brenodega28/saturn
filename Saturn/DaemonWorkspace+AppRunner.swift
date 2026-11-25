import AppKit
import SaturnCore
import Foundation

struct RunTarget: Identifiable, Hashable {
    static let mainID = "main"

    let id: String
    let branch: String
    let who: String
    let folder: URL
    let port: Int?
    let agent: Agent?

    var isMain: Bool { agent == nil }
}

extension DaemonWorkspace {
    func runTargets(in project: Project) -> [RunTarget] {
        let home = (project.path as NSString).abbreviatingWithTildeInPath
        let main = RunTarget(
            id: RunTarget.mainID,
            branch: state(for: project).branch ?? "main",
            who: "Your checkout · \(home)",
            folder: project.url,
            port: project.settings.basePort,
            agent: nil
        )
        let chatID = selectedRequest(in: project)?.id
        let runIDs = Set(chatID.map { (try? database.runs(taskId: $0)) ?? [] }?.compactMap(\.id) ?? [])
        let workers = ChatWorktrees.agents(agentSessions(in: project).map(\.agent), inChat: chatID, runIDs: runIDs)
            .compactMap { agent -> RunTarget? in
                guard let id = agent.id, let worktree = agent.worktreeURL else { return nil }
                return RunTarget(
                    id: "agent-\(id)",
                    branch: agent.branch ?? worktree.lastPathComponent,
                    who: "\(displayName(of: agent, in: project)) · worktree \(Self.place(of: worktree, in: project))",
                    folder: worktree,
                    port: agent.port,
                    agent: agent
                )
            }
        return [main] + workers
    }

    static func place(of worktree: URL, in project: Project) -> String {
        let root = project.url.standardizedFileURL.path
        let path = worktree.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return String(path.dropFirst(root.count + 1))
    }

    func selectedRunTarget(in project: Project) -> RunTarget {
        let targets = runTargets(in: project)
        if let id = project.id, let chosen = runTargetSelections[id], let target = targets.first(where: { $0.id == chosen }) {
            return target
        }
        if let runner = appRunner(for: project), let target = targets.first(where: { runner.isRunning(in: $0.folder) }) {
            return target
        }
        return targets[0]
    }

    func selectRunTarget(_ target: RunTarget, in project: Project) {
        guard let id = project.id else { return }
        runTargetSelections[id] = target.id
    }

    func appRunner(for project: Project) -> AppRunner? {
        project.id.flatMap { appRunners[$0] }
    }

    func runCommand(for project: Project, in folder: URL? = nil) -> DetectedRunCommand? {
        RunCommandDetector.resolve(override: project.settings.runCommand, in: project.isRemote ? project.filesRoot : folder ?? project.url)
    }

    func startApp(_ target: RunTarget, in project: Project) async {
        guard let id = project.id, let command = runCommand(for: project, in: target.folder) else { return }
        let runner: AppRunner
        if let existing = appRunners[id] {
            runner = existing
        } else {
            runner = AppRunner(projectId: id, log: app.activityLog, environment: [:])
            appRunners[id] = runner
        }
        runner.environment = AppRunner.environment(from: app.locator.environment())
        if project.isRemote || connection.isRemote {
            do {
                runner.remote = try await appRunnerHost(for: project)
            } catch {
                alert = AppAlert(title: "Couldn’t run \(project.name) on \(project.location)", message: error.localizedDescription)
                return
            }
        } else {
            runner.remote = nil
        }
        await runner.start(command: command.command, label: command.label, in: target.folder, branch: target.branch, port: target.port)
    }

    func stopApp(in project: Project) async {
        await appRunner(for: project)?.stop()
    }

    func stopApp(runningIn worktree: URL) async {
        for runner in appRunners.values where runner.isRunning(in: worktree) {
            await runner.stop()
        }
    }

    func stopAllAppsImmediately() {
        for runner in appRunners.values {
            runner.stopImmediately()
        }
    }

    func openRunningApp(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func appOutput(in project: Project) -> [LogEntry] {
        guard let id = project.id else { return [] }
        return app.activityLog.entries.filter { $0.source == AppRunner.logSource && $0.projectId == id }
    }

    func clearAppOutput(in project: Project) {
        app.activityLog.clear()
    }

    func chatChecks(for chat: Chat, run: Run?) -> ChatChecks {
        let steps = run?.id.flatMap { try? database.runSteps(runId: $0) } ?? []
        let hold = run?.id.flatMap { connection.holds[$0] }
        let hasWorkers = !(chat.id.map { (try? database.requestAgents(taskId: $0)) ?? [] } ?? []).isEmpty || run != nil
        return ChatChecks.make(run: run, workflow: run.flatMap(runWorkflow), steps: steps, hold: hold, hasWorkers: hasWorkers)
    }
}
