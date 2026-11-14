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

    func git(for project: Project) -> GitClient? {
        connection.git(for: project)
    }

    func git(forAgent agent: Agent) -> GitClient? {
        guard let project = try? database.project(id: agent.projectId) else { return nil }
        return git(for: project)
    }

    func shellDestination(for project: Project?) -> String? {
        connection.destination ?? project?.host
    }

    func isRemote(_ agent: Agent) -> Bool {
        connection.isRemote || (((try? database.project(id: agent.projectId)) ?? nil)?.isRemote ?? false)
    }

    func openRemoteShell(at directory: URL, forAgent agent: Agent) {
        let project = (try? database.project(id: agent.projectId)) ?? nil
        guard let destination = shellDestination(for: project) else { return }
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

    func pullRemoteFiles(_ project: Project) async throws {
        await pullConfigFiles(project)
        reloadConfig(for: project)
    }

    func pullAllRemoteFiles() async {
        guard connection.isRemote else { return }
        for project in openProjects {
            await pullConfigFiles(project)
            reloadConfig(for: project)
        }
    }

    func syncRemoteFiles(_ project: Project) async throws {
        try await pushConfigFiles(project)
    }

    func startRemoteFileSync() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.connection.isRemote, self.connection.isConnected {
                    for project in self.openProjects {
                        guard let id = project.id else { continue }
                        do {
                            try await self.pushConfigFiles(project)
                            if self.remoteStatuses[id]?.syncError != nil { self.remoteStatuses[id]?.syncError = nil }
                        } catch {
                            self.remoteStatuses[id, default: RemoteProjectStatus()].syncError = "Couldn’t save changes to the server: \(error.localizedDescription)"
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func remoteStatus(for project: Project) -> RemoteProjectStatus {
        project.id.flatMap { remoteStatuses[$0] } ?? RemoteProjectStatus()
    }

    func refreshLegacySSHProject(_ project: Project) {
        guard let id = project.id, let host = project.host else { return }
        remoteStatuses[id] = RemoteProjectStatus(
            error: "This project ran agents over SSH, which Ensemble no longer does. Move it to \(SSHDestination.displayName(host))’s daemon to keep working on it there; its history stays here, read-only."
        )
    }

    func openRemoteFolder(host destination: String, path: String) async throws {
        try await openOnServer(destination, path: path)
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

    func appRunnerHost(for project: Project) async throws -> RemoteAppHost {
        guard let destination = shellDestination(for: project) else { throw RemoteProjectUnsupported("Running the app on the host") }
        let client = SSHClient(destination: destination, runner: runner)
        let info: RemoteHostInfo
        if let known = remoteHostInfos[destination] {
            info = known
        } else {
            info = try await RemoteHost(client: client).probe()
            remoteHostInfos[destination] = info
        }
        return RemoteAppHost(client: client, home: info.home)
    }
}
