import EnsembleCore
import Foundation

struct RemoteProjectStatus: Equatable {
    var info: RemoteHostInfo?
    var error: String?
    var isConnecting = false
}

extension AppModel {
    func remoteHost(_ destination: String) -> RemoteHost {
        RemoteHost(client: SSHClient(destination: destination, runner: runner))
    }

    func remoteStatus(for project: Project) -> RemoteProjectStatus {
        project.id.flatMap { remoteStatuses[$0] } ?? RemoteProjectStatus()
    }

    func openRemoteFolder(host destination: String, path: String) async throws {
        let host = remoteHost(destination)
        let root = try await host.repositoryRoot(containing: path)
        let project = try database.openRemoteProject(path: root, host: destination)
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
}
