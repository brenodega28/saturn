import AppKit
import EnsembleCore
import Foundation
import Observation

enum SidebarItem: Hashable, Codable {
    case usage
    case project(Int64)
}

enum SidebarDestination: Hashable {
    case usage
    case section(project: Int64, tab: ProjectTab)
    case run(project: Int64, run: Int64)
    case request(project: Int64, request: Int64)
    case requests(project: Int64)
}

enum ProjectTab: String, CaseIterable, Identifiable, Codable {
    case lead
    case agents
    case changes
    case workflows
    case settings
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .lead: "Chat"
        case .agents: "Agents"
        case .changes: "Changes"
        case .workflows: "Workflows"
        case .settings: "Settings"
        case .code: "Code"
        }
    }

    var systemImage: String {
        switch self {
        case .lead: "bubble.left"
        case .agents: "person.2"
        case .changes: "plus.forwardslash.minus"
        case .workflows: "flowchart"
        case .settings: "gearshape"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct ProjectState {
    var branch: String?
    var worktrees: [Worktree] = []
    var recovery: WorktreeRecovery?
}

@MainActor
@Observable
final class AppModel {
    static let keychainService = "dev.monoliti.Ensemble"

    let clientPaths: AppPaths
    let daemonPaths: AppPaths
    var connection: DaemonConnection
    var connections: [DaemonID: DaemonConnection]
    var knownDaemons: [KnownDaemon]
    var serverProblems: [String: ServerProblem] = [:]
    var serverChecks: Set<String> = []
    var addingServers: Set<String> = []
    @ObservationIgnored var fetchingFiles: Set<String> = []
    @ObservationIgnored var remoteFilePaths: [String: String] = [:]
    let locator: ToolLocator
    let runner: CommandRunner
    var requests: ChatRequestFeed
    let requestNotifier = RequestNotifier()
    var chatNotifications: ChatNotificationFeed
    var pendingPermissions: PendingPermissionFeed
    var runDetailIDs: [Int64: Int64] = [:]
    let planUsage = PlanUsagePoller()
    @ObservationIgnored private var planUsageActivationObserver: NSObjectProtocol?

    private(set) var environment: EnvironmentReport?
    private(set) var providerMode: ProviderMode?
    private(set) var isCheckingEnvironment = false
    private(set) var openProjects: [Project] = []
    private(set) var recentProjects: [Project] = []
    var projectStates: [Int64: ProjectState] = [:]
    var configs: [Int64: ProjectConfig] = [:]
    var selectedAgents: [Int64: Int64] = [:]
    var isNewAgentPresented = false
    var leadSelections: [Int64: LeadSelection] = [:]
    var requestPageProjectIDs: Set<Int64> = []
    var changesRunSelections: [Int64: Int64] = [:]
    var skillPlugins: [Int64: [SkillPlugin]] = [:]
    var leadChatRevision = 0
    var composerFocusToken = 0
    var paletteMode: PaletteMode = .everything
    var testRunRequest: TestRunRequest?
    var settingsSections: [Int64: SettingsSection] = [:]
    var workflowEditors: [Int64: WorkflowEditor] = [:]
    let activityLog = ActivityLog()
    var appRunners: [Int64: AppRunner] = [:]
    var runTargetSelections: [Int64: String] = [:]
    var isRunMenuOpen = false
    var isNewChatPickerShown = false
    var isAppOutputShown = false
    var composerPrefill: String?
    var pendingChatDeletion: Chat?
    var newChatOptionsByProject: [Int64: NewChatOptions] = [:]
    var projectFileLists: [Int64: [String]] = [:]
    var activeClones: [String: Date] = [:]
    var listeningPorts: Set<Int> = []
    var isOffline = false
    var focusedPinIDs: [Int64: Int64] = [:]
    var problemCursor = -1
    var pinPrompt: PinPrompt?
    var workflowMenuAction: WorkflowMenuAction?
    let mainWindow = MainWindowNavigation()
    @ObservationIgnored var connectivity: ConnectivityMonitor?
    let pendingSends = PendingSends<PendingSendTarget>()
    var deliveringSends: [HeldSend] = []

    var selection: SidebarItem? {
        didSet {
            if case .project(let id) = selection {
                lastProjectID = id
                if tabs[id] == nil { tabs[id] = .lead }
            }
            persistNavigation()
        }
    }
    var lastProjectID: Int64?
    var tabs: [Int64: ProjectTab] = [:] {
        didSet { persistNavigation() }
    }

    var isPalettePresented = false
    var isClonePresented = false
    var isOpenPanelPresented = false
    var isRemoteFolderPresented = false
    var remoteStatuses: [Int64: RemoteProjectStatus] = [:]
    var remoteFileSyncs: [Int64: Task<Void, Error>] = [:]
    var remoteHostInfos: [String: RemoteHostInfo] = [:]
    var alert: AppAlert?
    var chatHighlight: ChatLink?

    init(connection: DaemonConnection, clientPaths: AppPaths, daemonPaths: AppPaths, locator: ToolLocator = ToolLocator()) {
        self.connection = connection
        self.daemonPaths = daemonPaths
        self.connections = [connection.id: connection]
        self.knownDaemons = Self.loadKnownDaemons(clientPaths)
        self.clientPaths = clientPaths
        self.providerMode = UserDefaults.standard.string(forKey: Self.providerModeKey).flatMap(ProviderMode.init(rawValue:))
        self.locator = locator
        self.runner = CommandRunner(environment: locator.environment())
        self.requests = ChatRequestFeed(database: connection.database)
        self.chatNotifications = ChatNotificationFeed(database: connection.database)
        self.pendingPermissions = PendingPermissionFeed(database: connection.database)
        connection.onError = { [weak self] title, error in
            self?.alert = AppAlert(title: title, message: error.localizedDescription)
        }
        connection.onEvent = { [weak self] event in self?.receive(event) }
        restoreNavigation()
        observeReplica()
        CommandRegistry.shared.registerChatLinkCommands()
        planUsageActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlanUsageOnActivation() }
        }
    }

    var database: AppDatabase { connection.database }

    var live: LiveState { connection.live }

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
        case .agentReplied, .shuttingDown:
            break
        }
    }

    var git: GitClient? {
        guard let path = locator.locate("git") else { return nil }
        return GitClient(executable: path, runner: runner)
    }

    var selectedProject: Project? {
        guard case .project(let id) = selection else { return nil }
        return openProjects.first { $0.id == id }
    }

    var currentProject: Project? {
        selectedProject ?? openProjects.first { $0.id == lastProjectID } ?? openProjects.first
    }

    func tab(for project: Project) -> ProjectTab {
        project.id.map(tab(forProjectID:)) ?? .lead
    }

    private func tab(forProjectID id: Int64) -> ProjectTab {
        tabs[id] ?? .lead
    }

    var sidebarDestination: SidebarDestination? {
        get {
            switch selection {
            case .usage: .usage
            case .project(let id):
                if let runID = runDetailIDs[id] {
                    .run(project: id, run: runID)
                } else if tab(forProjectID: id) == .lead, requestPageProjectIDs.contains(id) {
                    .requests(project: id)
                } else if tab(forProjectID: id) == .lead, let requestID = selectedOpenRequestID(inProjectID: id) {
                    .request(project: id, request: requestID)
                } else {
                    .section(project: id, tab: tab(forProjectID: id))
                }
            case nil: nil
            }
        }
        set {
            switch newValue {
            case .usage:
                selection = .usage
            case .section(let id, let tab):
                runDetailIDs[id] = nil
                tabs[id] = tab
                selection = .project(id)
                requestPageProjectIDs.remove(id)
            case .run(let id, let runID):
                openRunDetail(runID: runID, in: id)
            case .request(let id, let requestID):
                runDetailIDs[id] = nil
                tabs[id] = .lead
                selection = .project(id)
                showRequest(id: requestID, inProjectID: id)
            case .requests(let id):
                showRequestPage(inProjectID: id)
            case nil:
                break
            }
        }
    }

    func setTab(_ tab: ProjectTab, for project: Project) {
        guard let id = project.id else { return }
        tabs[id] = tab
    }

    func state(for project: Project) -> ProjectState {
        project.id.flatMap { projectStates[$0] } ?? ProjectState()
    }

    func launch() async {
        reloadProjects()
        await migrateSettingsToDaemon()
        await checkEnvironment()
        updatePlanUsagePolling()
        startRequests()
        await refreshAllProjects()
        startRemoteFileSync()
        Task { await connectRemoteDaemons() }
        connectivity = ConnectivityMonitor { [weak self] offline in self?.isOffline = offline }
    }

    private static let settingsMigratedKey = "daemon.settingsMigrated"

    private func migrateSettingsToDaemon() async {
        let migratedKey = "\(Self.settingsMigratedKey).\(connection.id.uuidString.lowercased())"
        guard !UserDefaults.standard.bool(forKey: migratedKey),
              let settings = try? await send(SettingsCommands.Get()) else { return }
        if settings.providerMode == nil, let mode = providerMode {
            _ = try? await send(SettingsCommands.SetProviderMode(mode: mode))
        }
        if settings.globalMonthlyBudgetUSD == nil, settings.globalWeeklyBudgetUSD == nil, globalMonthlyBudget != nil || globalWeeklyBudget != nil {
            _ = try? await send(SettingsCommands.SetBudgets(monthlyUSD: globalMonthlyBudget, weeklyUSD: globalWeeklyBudget))
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    func pauseAllAgents(in project: Project) {
        guard let id = project.id else { return }
        dispatch("Couldn’t pause the agents", AgentCommands.PauseAll(projectID: id))
    }

    func checkEnvironment() async {
        isCheckingEnvironment = true
        defer { isCheckingEnvironment = false }
        guard let daemonEnvironment = try? await send(SettingsCommands.CheckEnvironment()) else { return }
        environment = daemonEnvironment.report
        if let mode = daemonEnvironment.providerMode, providerMode != mode {
            providerMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: Self.providerModeKey)
        }
    }

    private static let providerModeKey = "providerMode"

    func chooseProvider(_ mode: ProviderMode) async {
        providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.providerModeKey)
        await command("Couldn’t change how agents sign in", SettingsCommands.SetProviderMode(mode: mode))
        updatePlanUsagePolling()
        await checkEnvironment()
    }

    private func updatePlanUsagePolling() {
        guard providerMode == .claudeSignIn else {
            planUsage.stop()
            return
        }
        if planUsage.isRunning {
            Task { await planUsage.refresh() }
        } else {
            planUsage.start()
        }
    }

    private func refreshPlanUsageOnActivation() {
        guard providerMode == .claudeSignIn, planUsage.isRunning else { return }
        Task { await planUsage.refreshOnActivation() }
    }

    var weeklySpend: Double {
        _ = connection.usageRevision
        let start = UsagePeriod.week.displayedStart(at: .now, countingSince: usageResetPoint) ?? .now
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
        if session != nil { setTab(.agents, for: project) }
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

    func project(withID id: Int64) -> Project? {
        openProjects.first { $0.id == id }
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

    func saveAPIKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if await !storeAPIKeyOnServer(trimmed) {
            await command("Couldn’t save the API key", SettingsCommands.SaveAPIKey(key: trimmed))
        }
        await checkEnvironment()
    }

    func removeAPIKey() async {
        if await !removeAPIKeyOnServer() {
            await command("Couldn’t remove the API key", SettingsCommands.RemoveAPIKey())
        }
        await checkEnvironment()
    }

    func openFolder(_ url: URL) async {
        do {
            let project = try await send(ProjectCommands.Open(path: url.path))
            reloadProjects()
            if let id = project.id {
                selection = .project(id)
            }
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
        activeClones[remote] = .now
        defer { activeClones[remote] = nil }
        let project = try await send(ProjectCommands.Clone(remote: remote, destination: destination.path))
        reloadProjects()
        if let id = project.id { selection = .project(id) }
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
            if selection == .project(id) {
                selection = openProjects.first?.id.map(SidebarItem.project)
            }
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

    func requireGit() -> GitClient? {
        if git == nil {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
        }
        return git
    }

    func reloadProjects() {
        perform("Couldn’t load projects") {
            openProjects = try database.openProjects()
            recentProjects = try database.recentProjects()
        }
        let openIDs = Set(openProjects.compactMap(\.id))
        if case .project(let id) = selection, !openIDs.contains(id) {
            selection = openProjects.first?.id.map(SidebarItem.project)
        } else if selection == nil {
            selection = openProjects.first?.id.map(SidebarItem.project)
        }
    }

    private func perform(_ title: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = AppAlert(title: title, message: error.localizedDescription)
        }
    }

    private static let selectionKey = "navigation.selection"
    private static let tabsKey = "navigation.tabs"

    private func persistNavigation() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(selection), forKey: Self.selectionKey)
        defaults.set(try? JSONEncoder().encode(tabs), forKey: Self.tabsKey)
    }

    private func restoreNavigation() {
        let savedSelection = UserDefaults.standard.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(SidebarItem?.self, from: $0) }
        tabs = [:]
        if case .project = savedSelection { selection = savedSelection } else { selection = nil }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum CloneError: LocalizedError {
    case destinationExists(URL)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let url): "\(url.path) already exists. Choose another folder name."
        }
    }
}
