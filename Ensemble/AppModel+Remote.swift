import AppKit
import EnsembleCore
import Foundation

struct RemoteProjectStatus: Equatable {
    var info: RemoteHostInfo?
    var error: String?
    var isConnecting = false
    var filesPulledAt: Date?
    var syncError: String?
}

extension AppModel {
    func remoteHost(_ destination: String) -> RemoteHost {
        RemoteHost(client: SSHClient(destination: destination, runner: runner))
    }

    func remoteWorktreeManager(for project: Project, destination: String) async -> WorktreeManager {
        let client = SSHClient(destination: destination, runner: runner)
        return await WorktreeManager.make(repository: project.url, git: GitClient(ssh: client), fileSystem: SSHFileSystem(client: client))
    }

    func git(for project: Project) -> GitClient? {
        connection.git(for: project)
    }

    func git(forAgent agent: Agent) -> GitClient? {
        guard let project = try? database.project(id: agent.projectId) else { return git }
        return git(for: project)
    }

    func isRemote(_ agent: Agent) -> Bool {
        ((try? database.project(id: agent.projectId)) ?? nil)?.isRemote ?? false
    }

    func openRemoteShell(at directory: URL, forAgent agent: Agent) {
        guard let project = try? database.project(id: agent.projectId), let destination = project.host else { return }
        let command = "exec /usr/bin/ssh -t -- " + ShellQuote.quote(destination) + " " + ShellQuote.quote("cd -- " + ShellQuote.quote(directory.path) + " && exec \"${SHELL:-/bin/sh}\" -l")
        let file = FileManager.default.temporaryDirectory.appending(path: "ensemble-ssh-\(UUID().uuidString.prefix(8)).command")
        do {
            try ("#!/bin/sh\nrm -f -- \"$0\"\n" + command + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            alert = AppAlert(title: "Couldn’t open a terminal on \(SSHDestination.displayName(destination))", message: error.localizedDescription)
        }
    }

    func remoteMirror(for project: Project) -> RemoteMirror? {
        guard let id = project.id, let destination = project.host else { return nil }
        let location = RemoteMirror.location(forProject: id)
        return RemoteMirror(
            directory: location.directory, manifestFile: location.manifest,
            repository: project.path, client: SSHClient(destination: destination, runner: runner)
        )
    }

    func pullRemoteFiles(_ project: Project) async throws {
        guard let mirror = remoteMirror(for: project) else { return }
        try await exclusively(project) {
            try await self.pushRemoteFiles(project, mirror: mirror)
            try await mirror.pull()
            self.reloadConfig(for: project)
        }
    }

    func pullAllRemoteFiles() async {
        for project in openProjects where project.isRemote {
            try? await pullRemoteFiles(project)
        }
    }

    func syncRemoteFiles(_ project: Project) async throws {
        guard let mirror = remoteMirror(for: project) else { return }
        try await exclusively(project) {
            try await self.pushRemoteFiles(project, mirror: mirror)
        }
    }

    private func exclusively(_ project: Project, _ work: @escaping @MainActor () async throws -> Void) async throws {
        guard let id = project.id else { return }
        while let running = remoteFileSyncs[id] {
            _ = await running.result
        }
        let task = Task { try await work() }
        remoteFileSyncs[id] = task
        defer { remoteFileSyncs[id] = nil }
        try await task.value
    }

    private func pushRemoteFiles(_ project: Project, mirror: RemoteMirror) async throws {
        do {
            let pushed = try await mirror.push()
            if !pushed.isEmpty { reloadConfig(for: project) }
        } catch let conflict as RemoteMirrorConflict {
            alert = AppAlert(title: "\(project.name) changed on \(project.host.map(SSHDestination.displayName) ?? "the host")", message: conflict.localizedDescription)
            try await mirror.pull()
            reloadConfig(for: project)
        }
    }

    func startRemoteFileSync() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                for project in self.openProjects where project.isRemote && self.remoteStatus(for: project).filesPulledAt != nil {
                    guard let id = project.id else { continue }
                    do {
                        try await self.syncRemoteFiles(project)
                        if self.remoteStatuses[id]?.syncError != nil { self.remoteStatuses[id]?.syncError = nil }
                    } catch {
                        self.remoteStatuses[id]?.syncError = "Couldn’t save changes to the host: \(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func remoteStatus(for project: Project) -> RemoteProjectStatus {
        project.id.flatMap { remoteStatuses[$0] } ?? RemoteProjectStatus()
    }

    func openRemoteFolder(host destination: String, path: String) async throws {
        let project = try await send(ProjectCommands.OpenRemote(host: destination, path: path))
        reloadProjects()
        if let id = project.id {
            selection = .project(id)
        }
        await refresh(project)
    }

    func reopen(_ project: Project) async {
        guard let destination = project.host else {
            await openFolder(project.url)
            return
        }
        do {
            try await openRemoteFolder(host: destination, path: project.path)
        } catch {
            alert = AppAlert(title: "Couldn’t open \(project.name) on \(SSHDestination.displayName(destination))", message: error.localizedDescription)
        }
    }

    func appRunnerHost(for project: Project) async throws -> RemoteAgentHost {
        guard let destination = project.host else { throw RemoteProjectUnsupported("Running the app on the host") }
        let client = SSHClient(destination: destination, runner: runner)
        let info: RemoteHostInfo
        if let known = remoteHostInfos[destination] {
            info = known
        } else {
            info = try await RemoteHost(client: client).probe()
            remoteHostInfos[destination] = info
        }
        return RemoteAgentHost(client: client, claudePath: info.claudePath ?? "", home: info.home, localPort: 0, relayPort: 0)
    }
}
