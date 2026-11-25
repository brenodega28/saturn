import AppKit
import EnsembleCore
import Foundation

struct KnownDaemon: Codable, Hashable, Identifiable {
    var id: DaemonID
    var name: String
    var destination: String?

    var displayName: String {
        destination.map(SSHDestination.displayName) ?? name
    }
}

struct ServerProblem: Equatable {
    var message: String
    var runsActive: Int?
}

extension AppModel {
    static func loadKnownDaemons(_ paths: AppPaths) -> [KnownDaemon] {
        guard let data = try? Data(contentsOf: paths.knownDaemons) else { return [] }
        return (try? JSONDecoder().decode([KnownDaemon].self, from: data)) ?? []
    }

    func saveKnownDaemons() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: clientPaths.root, withIntermediateDirectories: true)
        try? encoder.encode(knownDaemons.filter { $0.destination != nil }).write(to: clientPaths.knownDaemons, options: .atomic)
    }

    var helperDirectory: URL {
        LocalDaemon.helper.deletingLastPathComponent()
    }

    func installer(for destination: String) -> RemoteDaemonInstaller {
        RemoteDaemonInstaller(client: SSHClient(destination: destination, runner: runner), helperDirectory: helperDirectory)
    }

    func workspace(forServer destination: String) -> DaemonWorkspace? {
        workspaces.values.first { $0.connection.destination == destination }
    }

    @discardableResult
    private func adopt(_ connection: DaemonConnection) -> DaemonWorkspace {
        let workspace = DaemonWorkspace(connection: connection, app: self)
        add(workspace)
        workspace.start()
        return workspace
    }

    func adoptKnownDaemons() {
        for known in knownDaemons {
            guard let destination = known.destination, workspaces[known.id] == nil else { continue }
            let identity = DaemonIdentity(id: known.id, name: known.name)
            let client = DaemonClient(
                clientID: LocalDaemon.clientID(clientPaths), transport: RemoteDaemonInstaller.transport(destination: destination),
                replicasDirectory: clientPaths.replicasDirectory, knownDaemon: identity
            )
            guard let replica = client.replica else { continue }
            let remote = DaemonConnection(client: client, replica: replica)
            remote.destination = destination
            adopt(remote)
        }
    }

    func connectRemoteDaemons() async {
        adoptKnownDaemons()
        for workspace in orderedWorkspaces where workspace.isRemote && !workspace.isConnected {
            guard let destination = workspace.connection.destination else { continue }
            await checkServer(destination, activeRuns: 0, confirmedRestart: false)
            workspace.connection.start()
            Task { await workspace.refreshAllProjects() }
        }
    }

    func checkServer(_ destination: String, activeRuns: Int, confirmedRestart: Bool) async {
        serverChecks.insert(destination)
        defer { serverChecks.remove(destination) }
        do {
            _ = try await installer(for: destination).ensureInstalled(activeRuns: activeRuns, confirmedRestart: confirmedRestart)
            serverProblems[destination] = nil
        } catch let error as RemoteDaemonInstallerError {
            if case .runsActive(let count) = error {
                serverProblems[destination] = ServerProblem(message: error.localizedDescription, runsActive: count)
            } else {
                serverProblems[destination] = ServerProblem(message: error.localizedDescription)
            }
        } catch {
            serverProblems[destination] = ServerProblem(message: error.localizedDescription)
        }
    }

    func upgradeServer(_ workspace: DaemonWorkspace) async {
        guard let destination = workspace.connection.destination else { return }
        await checkServer(destination, activeRuns: workspace.live.activeRunCount, confirmedRestart: true)
    }

    @discardableResult
    func addServer(_ input: String) async -> DaemonWorkspace? {
        let destination: String
        do {
            destination = try SSHDestination.normalize(input)
        } catch {
            alert = AppAlert(title: "That isn’t an SSH destination", message: error.localizedDescription)
            return nil
        }
        if let existing = workspace(forServer: destination) { return existing }
        addingServers.insert(destination)
        defer { addingServers.remove(destination) }
        do {
            _ = try await installer(for: destination).ensureInstalled()
            let client = DaemonClient(
                clientID: LocalDaemon.clientID(clientPaths), transport: RemoteDaemonInstaller.transport(destination: destination),
                replicasDirectory: clientPaths.replicasDirectory
            )
            client.start()
            try await client.waitUntilConnected(timeout: .seconds(120))
            guard let replica = client.replica, let identity = client.identity else { throw ChannelError.closed }
            let remote = DaemonConnection(client: client, replica: replica)
            remote.destination = destination
            let workspace = adopt(remote)
            knownDaemons.removeAll { $0.id == identity.id || $0.destination == destination }
            knownDaemons.append(KnownDaemon(id: identity.id, name: identity.name, destination: destination))
            saveKnownDaemons()
            serverProblems[destination] = nil
            return workspace
        } catch {
            alert = AppAlert(title: "Couldn’t add \(SSHDestination.displayName(destination))", message: error.localizedDescription)
            return nil
        }
    }

    func removeServer(_ remote: DaemonWorkspace) {
        guard remote.isRemote else { return }
        knownDaemons.removeAll { $0.id == remote.id }
        saveKnownDaemons()
        remove(remote)
        pages.retain { $0.kind.daemon != remote.id }
        if case .project(let ref) = selection, ref.daemon == remote.id { selection = nil }
        if lastProjectID?.daemon == remote.id { lastProjectID = nil }
        tabs = tabs.filter { $0.key.daemon != remote.id }
        projectsChanged(in: local)
    }

    func stopServerDaemon(_ remote: DaemonWorkspace) {
        guard let destination = remote.connection.destination else { return }
        Task {
            await remote.command("Couldn’t stop the daemon on \(SSHDestination.displayName(destination))", SettingsCommands.Shutdown())
        }
    }

    func openOnServer(_ destination: String, path: String) async throws {
        let existing = workspace(forServer: destination)
        guard let remote = existing == nil ? await addServer(destination) : existing else { return }
        let project = try await remote.send(ProjectCommands.Open(path: path))
        remote.reloadProjects()
        if let opened = project.id.flatMap(remote.project(withID:)) { remote.showChat(in: opened) }
        await remote.refresh(project)
    }

    func moveToServerDaemon(_ project: Project) async {
        guard let destination = project.host else { return }
        do {
            try await openOnServer(destination, path: project.path)
        } catch {
            alert = AppAlert(title: "Couldn’t move \(project.name) to \(SSHDestination.displayName(destination))’s daemon", message: error.localizedDescription)
            return
        }
        guard let id = project.id else { return }
        local.dispatch("Couldn’t close the old SSH project", ProjectCommands.Close(projectID: id))
    }
}

extension DaemonWorkspace {
    func filesMirror(for project: Project) -> DaemonFilesMirror? {
        guard connection.isRemote else { return nil }
        return DaemonFilesMirror(connection: connection, project: project, cacheRoot: app.clientPaths.replicaFiles(connection.id))
    }

    func pullConfigFiles(_ project: Project) async {
        guard let mirror = filesMirror(for: project) else { return }
        mirror.activate()
        do {
            try await mirror.pull()
        } catch {
            remoteStatuses[project.id ?? -1] = RemoteProjectStatus(error: "Couldn’t read the project’s settings from the server: \(error.localizedDescription)")
        }
    }

    func pushConfigFiles(_ project: Project) async throws {
        guard let mirror = filesMirror(for: project) else { return }
        if try await !mirror.push().isEmpty { reloadConfig(for: project) }
    }

    func storeAPIKeyOnServer(_ key: String) async -> Bool {
        guard let destination = connection.destination else { return false }
        do {
            try await app.installer(for: destination).storeAPIKey(key, home: connection.environment.homeDirectory)
        } catch {
            alert = AppAlert(title: "Couldn’t save the API key on \(SSHDestination.displayName(destination))", message: error.localizedDescription)
        }
        return true
    }

    func removeAPIKeyOnServer() async -> Bool {
        guard let destination = connection.destination else { return false }
        try? await app.installer(for: destination).deleteAPIKey()
        return true
    }

    func cachedDaemonFile(_ kind: FileKind, id: String, name: String, maximumAge: TimeInterval = .infinity) -> URL {
        let url = app.clientPaths.replicaFiles(connection.id)
            .appending(path: "\(kind.rawValue)/\(id.replacingOccurrences(of: "/", with: "-"))", directoryHint: .isDirectory)
            .appending(path: name)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        let isStale = modified.map { Date.now.timeIntervalSince($0) > maximumAge } ?? true
        guard isStale, fetchingFiles.insert(url.path).inserted else { return url }
        let connection = connection
        Task {
            defer { fetchingFiles.remove(url.path) }
            guard let data = try? await connection.fileData(kind, id: id) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = try? Data(contentsOf: url)
            try? data.write(to: url, options: .atomic)
            if previous != data { leadChatRevision += 1 }
        }
        return url
    }

    func localURL(forEvidence item: Evidence) -> URL {
        guard connection.isRemote, let id = item.id else { return item.url }
        return cachedDaemonFile(.evidence, id: "\(id)", name: item.url.lastPathComponent)
    }
}
