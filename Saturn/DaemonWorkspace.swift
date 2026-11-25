import AppKit
import SaturnCore
import Foundation
import Observation

struct ProjectRef: Hashable, Codable, Sendable {
    var daemon: DaemonID
    var id: Int64
}

@MainActor
@Observable
final class DaemonWorkspace: Identifiable {
    let connection: DaemonConnection
    @ObservationIgnored unowned let app: AppModel
    var requests: ChatRequestFeed
    var chatNotifications: ChatNotificationFeed
    var pendingPermissions: PendingPermissionFeed
    let returnedMessages = ReturnedMessages<LeadSendTarget>()
    let draftStore: ChatDraftStore
    var deliveringSends: [DeliveringSend] = []

    private(set) var openProjects: [Project] = []
    private(set) var recentProjects: [Project] = []
    var projectStates: [Int64: ProjectState] = [:]
    var configs: [Int64: ProjectConfig] = [:]
    var runDetailIDs: [Int64: Int64] = [:]
    var selectedAgents: [Int64: Int64] = [:]
    var leadSelections: [Int64: LeadSelection] = [:]
    var requestPageProjectIDs: Set<Int64> = []
    var changesRunSelections: [Int64: Int64] = [:]
    var skillPlugins: [Int64: [SkillPlugin]] = [:]
    var settingsSections: [Int64: SettingsSection] = [:]
    var workflowEditors: [Int64: WorkflowEditor] = [:]
    var appRunners: [Int64: AppRunner] = [:]
    var runTargetSelections: [Int64: String] = [:]
    var newChatOptionsByProject: [Int64: NewChatOptions] = [:]
    var projectFileLists: [Int64: [String]] = [:]
    var setupAttempts: Set<Int64> = []
    var setupsInFlight: Set<Int64> = []
    var onboardingsInFlight: Set<Int64> = []
    var onboardingChecks: Set<Int64> = []
    var focusedPinIDs: [Int64: Int64] = [:]
    var remoteStatuses: [Int64: RemoteProjectStatus] = [:]
    var remoteFileSyncs: [Int64: Task<Void, Error>] = [:]
    @ObservationIgnored var fetchingFiles: Set<String> = []
    @ObservationIgnored var pendingCodeLines: [String: Int] = [:]
    @ObservationIgnored var specTunnels: [Int: SSHPortForward] = [:]
    @ObservationIgnored var specTunnelPorts: [Int64: Int] = [:]
    @ObservationIgnored var specTunnelOpenings: [Int: Task<Int, Error>] = [:]
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    @ObservationIgnored private var isStarted = false

    init(connection: DaemonConnection, app: AppModel) {
        self.connection = connection
        self.app = app
        draftStore = ChatDraftStore(directory: app.clientPaths.root.appending(path: "drafts/\(connection.id.uuidString.lowercased())", directoryHint: .isDirectory))
        requests = ChatRequestFeed(database: connection.database)
        chatNotifications = ChatNotificationFeed(database: connection.database)
        pendingPermissions = PendingPermissionFeed(database: connection.database)
        connection.onError = { [weak app] title, error in
            app?.alert = AppAlert(title: title, message: error.localizedDescription)
        }
        connection.onEvent = { [weak self] event in self?.receive(event) }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.draftStore.flush()
                self?.closeSpecTunnels()
            }
        }
        reloadProjects()
        migrateLegacyNewChatPages()
        observeReplica()
        observeConnection()
    }

    nonisolated var id: DaemonID { connection.id }

    var database: AppDatabase { connection.database }

    var live: LiveState { connection.live }

    var isRemote: Bool { connection.isRemote }

    var isConnected: Bool { connection.isConnected }

    var displayName: String {
        connection.destination.map(SSHDestination.displayName) ?? "This Mac"
    }

    var systemImage: String { isRemote ? "server.rack" : "laptopcomputer" }

    func ref(_ projectID: Int64) -> ProjectRef {
        ProjectRef(daemon: id, id: projectID)
    }

    func ref(of project: Project) -> ProjectRef? {
        project.id.map(ref)
    }

    var alert: AppAlert? {
        get { app.alert }
        set { app.alert = newValue }
    }

    var pages: MainPages { app.pages }

    var leadChatRevision: Int {
        get { app.leadChatRevision }
        set { app.leadChatRevision = newValue }
    }

    var composerFocusToken: Int {
        get { app.composerFocusToken }
        set { app.composerFocusToken = newValue }
    }

    private func observeReplica() {
        withObservationTracking {
            _ = connection.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadProjects()
                self.observeReplica()
            }
        }
    }

    private func observeConnection() {
        withObservationTracking {
            _ = connection.isConnected
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isConnected { self.closeSpecTunnels() }
                self.app.shareDaemonPeers()
                self.observeConnection()
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startRequests()
        startRemoteFileSync()
    }

    func stop() {
        requests.stop()
        chatNotifications.stop()
        pendingPermissions.stop()
        for runner in appRunners.values { runner.stopImmediately() }
        closeSpecTunnels()
        connection.stop()
    }

    @discardableResult
    func send<C: DaemonCommand>(_ command: C) async throws -> C.Response {
        try await connection.send(command)
    }

    func dispatch<C: DaemonCommand>(_ failureTitle: String, _ command: C) {
        connection.perform(failureTitle, command)
    }

    @discardableResult
    func command<C: DaemonCommand>(_ failureTitle: String, _ command: C) async -> C.Response? {
        do {
            return try await connection.send(command)
        } catch {
            alert = AppAlert(title: failureTitle, message: error.localizedDescription)
            return nil
        }
    }

    func receive(_ event: DaemonEvent) {
        switch event {
        case .worktreeRemoving(let path):
            Task { await stopApp(runningIn: URL(fileURLWithPath: path, isDirectory: true)) }
        case .leadTurnEnded(let taskId):
            chatNotifications.leadTurnEnded(taskId: taskId)
        case .specDrafted(let projectId, let taskId, _):
            specDrafted(projectId: projectId, taskId: taskId)
        case .specReviewEnded(let taskId):
            closeSpecTunnel(chatID: taskId)
        case .readChat(let relayID, let daemon, let request):
            Task { await relayChat(relayID, daemon: daemon, request: request) }
        case .agentReplied, .shuttingDown:
            break
        }
    }

    func reloadProjects() {
        do {
            openProjects = try database.openProjects()
            recentProjects = try database.recentProjects()
        } catch {
            alert = AppAlert(title: "Couldn’t load projects", message: error.localizedDescription)
        }
        app.projectsChanged(in: self)
    }

    func project(withID id: Int64) -> Project? {
        openProjects.first { $0.id == id }
    }

    func state(for project: Project) -> ProjectState {
        project.id.flatMap { projectStates[$0] } ?? ProjectState()
    }

    func tab(for project: Project) -> ProjectTab {
        ref(of: project).flatMap { app.tabs[$0] } ?? .lead
    }

    func setTab(_ tab: ProjectTab, for project: Project) {
        if let tool = MainTool(tab: tab) {
            open(tool, in: project)
        } else {
            showChat(in: project)
        }
    }

    func open(_ tool: MainTool, in project: Project) {
        let settings = project.id.flatMap { settingsSections[$0] } ?? .general
        guard let section = ProjectSection(tool: tool, settings: settings) else { return }
        openProject(project, section: section)
    }

    func openProject(_ project: Project, section: ProjectSection = .overview) {
        guard let id = project.id else { return }
        if case .settings(let settings) = section { settingsSections[id] = settings }
        app.selection = .project(ref(id))
        pages.openProject(ref(id), section: section)
    }

    func pauseAllAgents(in project: Project) {
        guard let id = project.id else { return }
        dispatch("Couldn’t pause the agents", AgentCommands.PauseAll(projectID: id))
    }

    var weeklySpend: Double {
        _ = connection.usageRevision
        let start = UsagePeriod.week.displayedStart(at: .now, countingSince: app.usageResetPoint) ?? .now
        return (try? database.spend(since: start)) ?? 0
    }

    func agentSessions(in project: Project) -> [LiveAgentSession] {
        guard let id = project.id else { return [] }
        return (try? connection.sessions(inProject: id)) ?? []
    }

    func selectedAgent(in project: Project) -> LiveAgentSession? {
        guard let projectID = project.id, let agentID = selectedAgents[projectID] else { return nil }
        return agentSessions(in: project).first { $0.id == agentID }
    }

    func select(_ session: LiveAgentSession?, in project: Project) {
        guard let projectID = project.id else { return }
        selectedAgents[projectID] = session?.id
        if let id = session?.id {
            showPage(.agent(id, daemon: self.id))
        } else if let page = app.activePage, case .agent = page.kind {
            pages.close(page.id)
            openProject(project, section: .agents)
        }
    }

    func config(for project: Project) -> ProjectConfig {
        guard let id = project.id else { return ProjectConfig() }
        if let config = configs[id] { return config }
        return ProjectConfigLoader.load(repository: project.filesRoot)
    }

    func hasConfig(_ project: Project) -> Bool {
        _ = configs[project.id ?? -1]
        return ProjectConfigLoader.hasConfig(repository: project.filesRoot)
    }

    func reloadConfig(for project: Project) {
        guard let id = project.id else { return }
        configs[id] = ProjectConfigLoader.load(repository: project.filesRoot)
    }

    func reloadAllConfigs() {
        for project in openProjects {
            reloadConfig(for: project)
        }
        Task { await pullAllRemoteFiles() }
    }

    func installDefaultConfig(in project: Project) {
        guard let id = project.id else { return }
        Task {
            await command("Couldn’t add the default workflows", ProjectCommands.InstallDefaults(projectID: id))
            reloadConfig(for: project)
        }
    }

    func role(for agent: Agent, in project: Project) -> RoleDefinition? {
        config(for: project).role(agent.role)
    }

    func displayName(of agent: Agent, in project: Project) -> String {
        AgentNaming.displayName(of: agent)
    }

    func displayName(of agent: Agent) -> String {
        guard let project = self.project(withID: agent.projectId) else { return agent.name }
        return displayName(of: agent, in: project)
    }

    func agentNames(for base: String, count: Int, in project: Project) -> [String] {
        guard let id = project.id else { return [] }
        let existing = ((try? database.agents(inProject: id)) ?? []).map(\.name)
        return AgentNaming.names(base: base, count: count, existing: existing)
    }

    func spawnAgents(in project: Project, kind: AgentKind, count: Int, name: String, model: String, skills: [String], pinned: Bool, task: String) async throws {
        guard let projectID = project.id else { return }
        let ids = try await send(AgentCommands.Spawn(
            projectID: projectID, kind: kind, count: count, name: name, model: model, skills: skills, pinned: pinned, task: task
        ))
        if ids.count == 1, let id = ids.first {
            select(connection.session(agentID: id), in: project)
        }
        await refresh(project)
    }

    func updateSettings(_ settings: ProjectSettings, for project: Project) {
        guard let id = project.id else { return }
        dispatch("Couldn’t save project settings", ProjectCommands.UpdateSettings(projectID: id, settings: settings))
    }

    func runs(for sessions: [LiveAgentSession]) -> [Run] {
        let ids = Array(Set(sessions.compactMap(\.agent.runId)))
        return (try? database.runs(withIDs: ids)) ?? []
    }

    func deleteAgent(_ session: LiveAgentSession, in project: Project, deleteBranch: Bool) async {
        do {
            try await send(AgentCommands.Delete(agentID: session.id, deleteBranch: deleteBranch))
            if selectedAgent(in: project)?.id == session.id { select(nil, in: project) }
        } catch {
            alert = AppAlert(title: "Couldn’t delete \(displayName(of: session.agent, in: project))", message: error.localizedDescription)
        }
        await refresh(project)
    }

    func openFolder(_ url: URL) async {
        do {
            let project = try await send(ProjectCommands.Open(path: url.path))
            reloadProjects()
            showChat(in: project)
            await applyRecommendedSetup(project)
            await openOnboardingIfNeeded(project)
            await refresh(project)
        } catch {
            alert = AppAlert(title: "Couldn’t open \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    func clone(_ remote: String, into parent: URL, folderName: String) async throws {
        let destination = parent.appending(path: folderName, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CloneError.destinationExists(destination)
        }
        app.activeClones[remote] = .now
        defer { app.activeClones[remote] = nil }
        let project = try await send(ProjectCommands.Clone(remote: remote, destination: destination.path))
        reloadProjects()
        showChat(in: project)
        await refresh(project)
    }

    func close(_ project: Project) {
        guard let id = project.id else { return }
        projectStates[id] = nil
        remoteStatuses[id] = nil
        if let runner = appRunners[id] { Task { await runner.stop() } }
        Task {
            await command("Couldn’t close \(project.name)", ProjectCommands.Close(projectID: id))
            reloadProjects()
            app.dropStalePages()
        }
    }

    func forgetRecent(_ project: Project) {
        guard let id = project.id else { return }
        Task {
            await command("Couldn’t remove \(project.name)", ProjectCommands.Forget(projectID: id))
            reloadProjects()
        }
    }

    func refreshAllProjects() async {
        for project in openProjects {
            await refresh(project)
        }
    }

    func refresh(_ project: Project) async {
        if project.isRemote {
            refreshLegacySSHProject(project)
            return
        }
        guard let id = project.id else { return }
        do {
            let status = try await send(ProjectCommands.Refresh(projectID: id))
            if status.missing {
                alert = AppAlert(title: "\(project.name) is missing", message: "\(project.path) no longer exists. It has been closed.")
                close(project)
                return
            }
            projectStates[id] = ProjectState(branch: status.branch, worktrees: status.recovery.worktrees, recovery: status.recovery)
            await pullConfigFiles(project)
            reloadConfig(for: project)
        } catch {
            alert = AppAlert(title: "Couldn’t read worktrees for \(project.name)", message: error.localizedDescription)
        }
    }

    func createWorktree(in project: Project, agent: String, slug: String) async throws {
        guard let id = project.id else { return }
        try await send(ProjectCommands.CreateWorktree(projectID: id, agent: agent, slug: slug))
        await refresh(project)
    }

    func nextDebugAgentName(in project: Project) -> String {
        let taken = Set(state(for: project).worktrees.map(\.agent))
        return (1...).lazy.map { "debug-\($0)" }.first { !taken.contains($0) }!
    }

    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool, deleteBranch: Bool) async throws {
        guard let id = project.id else { return }
        await stopApp(runningIn: worktree.path)
        try await send(ProjectCommands.RemoveWorktree(projectID: id, path: worktree.path.path, force: force, deleteBranch: deleteBranch))
        await refresh(project)
    }

    func deleteOrphanedDirectory(_ directory: URL, in project: Project) async {
        guard let id = project.id else { return }
        await command("Couldn’t delete \(directory.lastPathComponent)", ProjectCommands.DeleteOrphanedDirectory(projectID: id, path: directory.path))
        await refresh(project)
    }

    func saveAPIKey(_ key: String) async {
        if await !storeAPIKeyOnServer(key) {
            await command("Couldn’t save the API key", SettingsCommands.SaveAPIKey(key: key))
        }
    }

    func removeAPIKey() async {
        if await !removeAPIKeyOnServer() {
            await command("Couldn’t remove the API key", SettingsCommands.RemoveAPIKey())
        }
    }

    func copyToPasteboard(_ text: String) {
        app.copyToPasteboard(text)
    }
}
