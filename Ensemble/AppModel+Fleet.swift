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
    static let activeDaemonKey = "fleet.activeDaemon"

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

    var orderedConnections: [DaemonConnection] {
        connections.values.sorted { lhs, rhs in
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func displayName(of connection: DaemonConnection) -> String {
        connection.destination.map(SSHDestination.displayName) ?? "This Mac"
    }

    var helperDirectory: URL {
        LocalDaemon.helper.deletingLastPathComponent()
    }

    func installer(for destination: String) -> RemoteDaemonInstaller {
        RemoteDaemonInstaller(client: SSHClient(destination: destination, runner: runner), helperDirectory: helperDirectory)
    }

    func adopt(_ connection: DaemonConnection) {
        connection.onError = { [weak self] title, error in
            self?.alert = AppAlert(title: title, message: error.localizedDescription)
        }
        connections[connection.id] = connection
    }

    func connectRemoteDaemons() async {
        for known in knownDaemons {
            guard let destination = known.destination, connections[known.id] == nil else { continue }
            await connectRemote(known, destination: destination)
        }
        if let stored = AppDefaults.store.string(forKey: Self.activeDaemonKey).flatMap(UUID.init(uuidString:)),
           stored != connection.id, connections[stored] != nil {
            activate(stored)
        }
    }

    private func connectRemote(_ known: KnownDaemon, destination: String, confirmedRestart: Bool = false) async {
        let identity = DaemonIdentity(id: known.id, name: known.name)
        let client = DaemonClient(
            clientID: LocalDaemon.clientID(clientPaths), transport: RemoteDaemonInstaller.transport(destination: destination),
            replicasDirectory: clientPaths.replicasDirectory, knownDaemon: identity
        )
        guard let replica = client.replica else { return }
        let remote = DaemonConnection(client: client, replica: replica)
        remote.destination = destination
        adopt(remote)
        await checkServer(destination, activeRuns: 0, confirmedRestart: confirmedRestart)
        remote.start()
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

    func upgradeServer(_ connection: DaemonConnection) async {
        guard let destination = connection.destination else { return }
        await checkServer(destination, activeRuns: connection.live.activeRunCount, confirmedRestart: true)
    }

    @discardableResult
    func addServer(_ input: String) async -> DaemonConnection? {
        let destination: String
        do {
            destination = try SSHDestination.normalize(input)
        } catch {
            alert = AppAlert(title: "That isn’t an SSH destination", message: error.localizedDescription)
            return nil
        }
        if let existing = connections.values.first(where: { $0.destination == destination }) { return existing }
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
            adopt(remote)
            knownDaemons.removeAll { $0.id == identity.id || $0.destination == destination }
            knownDaemons.append(KnownDaemon(id: identity.id, name: identity.name, destination: destination))
            saveKnownDaemons()
            serverProblems[destination] = nil
            return remote
        } catch {
            alert = AppAlert(title: "Couldn’t add \(SSHDestination.displayName(destination))", message: error.localizedDescription)
            return nil
        }
    }

    func removeServer(_ remote: DaemonConnection) {
        guard remote.isRemote else { return }
        if connection === remote, let local = connections.values.first(where: { !$0.isRemote }) { activate(local.id) }
        remote.stop()
        connections[remote.id] = nil
        knownDaemons.removeAll { $0.id == remote.id }
        saveKnownDaemons()
    }

    func stopServerDaemon(_ remote: DaemonConnection) {
        guard let destination = remote.destination else { return }
        Task {
            await command("Couldn’t stop the daemon on \(SSHDestination.displayName(destination))", SettingsCommands.Shutdown())
        }
    }

    func activate(_ id: DaemonID) {
        guard let target = connections[id], target !== connection else { return }
        requests.stop()
        chatNotifications.stop()
        pendingPermissions.stop()
        connection = target
        requests = ChatRequestFeed(database: target.database)
        chatNotifications = ChatNotificationFeed(database: target.database)
        pendingPermissions = PendingPermissionFeed(database: target.database)
        target.onEvent = { [weak self] event in self?.receive(event) }
        selection = nil
        tabs = [:]
        runDetailIDs = [:]
        leadSelections = [:]
        requestPageProjectIDs = []
        selectedAgents = [:]
        projectStates = [:]
        configs = [:]
        changesRunSelections = [:]
        AppDefaults.store.set(id.uuidString, forKey: Self.activeDaemonKey)
        startRequests()
        reloadProjects()
        pages.reload(storageKey: Self.pagesKey(for: id))
        dropStalePages()
        Task { await refreshAllProjects() }
        Task { await checkEnvironment() }
    }

    func projects(on daemon: DaemonConnection) -> [Project] {
        _ = daemon.revision
        return (try? daemon.database.openProjects()) ?? []
    }

    func open(_ project: Project, on daemon: DaemonConnection) {
        activate(daemon.id)
        if let opened = project.id.flatMap(self.project(withID:)) { showChat(in: opened) }
    }

    func connection(forServer destination: String) async -> DaemonConnection? {
        if let existing = connections.values.first(where: { $0.destination == destination }) { return existing }
        return await addServer(destination)
    }

    func openOnServer(_ destination: String, path: String) async throws {
        guard let remote = await connection(forServer: destination) else { return }
        let project = try await remote.send(ProjectCommands.Open(path: path))
        activate(remote.id)
        reloadProjects()
        if let opened = project.id.flatMap(self.project(withID:)) { showChat(in: opened) }
        await refresh(project)
    }

    func moveToServerDaemon(_ project: Project) async {
        guard let destination = project.host else { return }
        do {
            try await openOnServer(destination, path: project.path)
        } catch {
            alert = AppAlert(title: "Couldn’t move \(project.name) to \(SSHDestination.displayName(destination))’s daemon", message: error.localizedDescription)
            return
        }
        guard let local = connections.values.first(where: { !$0.isRemote }), let id = project.id else { return }
        local.perform("Couldn’t close the old SSH project", ProjectCommands.Close(projectID: id))
    }

    func filesMirror(for project: Project) -> DaemonFilesMirror? {
        guard connection.isRemote else { return nil }
        return DaemonFilesMirror(connection: connection, project: project, cacheRoot: clientPaths.replicaFiles(connection.id))
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
            try await installer(for: destination).storeAPIKey(key, home: connection.environment.homeDirectory)
        } catch {
            alert = AppAlert(title: "Couldn’t save the API key on \(SSHDestination.displayName(destination))", message: error.localizedDescription)
        }
        return true
    }

    func removeAPIKeyOnServer() async -> Bool {
        guard let destination = connection.destination else { return false }
        try? await installer(for: destination).deleteAPIKey()
        return true
    }

    func cachedDaemonFile(_ kind: FileKind, id: String, name: String, remotePath: String? = nil, maximumAge: TimeInterval = .infinity) -> URL {
        let url = clientPaths.replicaFiles(connection.id)
            .appending(path: "\(kind.rawValue)/\(id.replacingOccurrences(of: "/", with: "-"))", directoryHint: .isDirectory)
            .appending(path: name)
        if let remotePath { remoteFilePaths[url.path] = remotePath }
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

    func saveDaemonFile(_ text: String, at localPath: String) async throws {
        try text.write(to: URL(fileURLWithPath: localPath), atomically: true, encoding: .utf8)
        guard let remotePath = remoteFilePaths[localPath] else { return }
        try await send(CodeCommands.WriteFile(path: remotePath, data: Data(text.utf8)))
    }
}
