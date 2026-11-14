import AppKit
import EnsembleCore
import Foundation
import Observation

enum SidebarItem: Hashable, Codable {
    case inbox
    case usage
    case quality
    case project(Int64)
}

enum SidebarDestination: Hashable {
    case inbox
    case usage
    case quality
    case section(project: Int64, tab: ProjectTab)
    case run(project: Int64, run: Int64)
    case request(project: Int64, request: Int64)
    case requests(project: Int64)
}

enum ProjectTab: String, CaseIterable, Identifiable, Codable {
    case tasks
    case lead
    case agents
    case changes
    case workflows
    case settings
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .tasks: "Tasks"
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
        case .tasks: "checkmark.square"
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

    let database: AppDatabase
    let agents: AgentRuntime
    let driver: AgentWorkflowDriver
    let engine: RunEngine
    let secrets: any SecretStore
    let locator: ToolLocator
    let runner: CommandRunner
    let gitHub: GitHubIntegration
    let inbox: InboxFeed
    let inboxNotifier = InboxNotifier()
    let chatNotifications: ChatNotificationFeed
    let pendingPermissions: PendingPermissionFeed
    var runDetailIDs: [Int64: Int64] = [:]
    let idleCleanup: IdleCleanupScheduler
    let planUsage = PlanUsagePoller()
    @ObservationIgnored private var planUsageActivationObserver: NSObjectProtocol?

    private(set) var environment: EnvironmentReport?
    private(set) var providerMode: ProviderMode?
    private(set) var isCheckingEnvironment = false
    private(set) var openProjects: [Project] = []
    private(set) var recentProjects: [Project] = []
    private(set) var projectStates: [Int64: ProjectState] = [:]
    private(set) var configs: [Int64: ProjectConfig] = [:]
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
    var activeClones: [String: Date] = [:]
    var listeningPorts: Set<Int> = []
    var isOffline = false
    var focusedPinIDs: [Int64: Int64] = [:]
    var problemCursor = -1
    var pinPrompt: PinPrompt?
    var workflowMenuAction: WorkflowMenuAction?
    let mainWindow = MainWindowNavigation()
    @ObservationIgnored var connectivity: ConnectivityMonitor?
    let leadChat: LeadChat
    let directChat: DirectChat
    var chatTargets: [Int64: ChatTarget] = [:]
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
    var alert: AppAlert?
    var chatHighlight: ChatLink?

    init(database: AppDatabase, paths: AppPaths, secrets: any SecretStore, locator: ToolLocator = ToolLocator()) {
        self.database = database
        let storedMode = UserDefaults.standard.string(forKey: Self.providerModeKey).flatMap(ProviderMode.init(rawValue:))
        self.providerMode = storedMode
        let agents = AgentRuntime(database: database, paths: paths, secrets: secrets, providerMode: storedMode)
        self.agents = agents
        self.secrets = secrets
        self.locator = locator
        self.runner = CommandRunner(environment: locator.environment())
        let driver = AgentWorkflowDriver(runtime: agents)
        self.driver = driver
        self.engine = RunEngine(database: database, driver: driver)
        self.leadChat = LeadChat(runtime: agents, engine: engine, driver: driver)
        self.directChat = DirectChat(runtime: agents)
        self.gitHub = GitHubIntegration(engine: engine, secrets: secrets)
        self.inbox = InboxFeed(database: database)
        self.chatNotifications = ChatNotificationFeed(database: database)
        self.pendingPermissions = PendingPermissionFeed(database: database)
        self.idleCleanup = IdleCleanupScheduler(runtime: agents)
        driver.gitProvider = { [weak self] in self?.git }
        connectWorkspaces()
        connectAppRunners()
        driver.gitHubProvider = { try? GitHubAuth(secrets: secrets).client() }
        restoreNavigation()
        connectGitHub()
        CommandRegistry.shared.registerChatLinkCommands()
        planUsageActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlanUsageOnActivation() }
        }
    }

    var git: GitClient? {
        guard case .found(let path, _) = environment?.git else { return nil }
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
            case .inbox: .inbox
            case .usage: .usage
            case .quality: .quality
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
            case .inbox:
                selection = .inbox
            case .usage:
                selection = .usage
            case .quality:
                selection = .quality
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
        perform("Couldn’t recover agents") { try agents.recoverAfterLaunch() }
        do {
            try await driver.ensureServer()
        } catch {
            alert = AppAlert(title: "Couldn’t start Ensemble’s agent tools", message: error.localizedDescription)
        }
        await checkEnvironment()
        updatePlanUsagePolling()
        perform("Couldn’t recover runs") { try engine.recover() }
        engine.startOrphanWatchdog()
        await deleteAgentsOfClosedRequests()
        startInbox()
        startBudgetMonitor()
        startMemoryUpdates()
        gitHub.start()
        idleCleanup.start()
        await refreshAllProjects()
        startWeeklySummaries()
        startActivityRecorder()
        startRemoteFileSync()
        connectivity = ConnectivityMonitor { [weak self] offline in self?.isOffline = offline }
    }

    func pauseAllAgents(in project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t pause the agents") { _ = try agents.pauseAll(inProject: id) }
    }

    func startWeeklySummaries() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                for project in self.openProjects {
                    _ = try? WeeklySummary.postIfDue(for: project, database: self.database)
                }
                _ = try? self.engine.postApprovalReminders()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkEnvironment() async {
        isCheckingEnvironment = true
        defer { isCheckingEnvironment = false }
        let report = await EnvironmentChecker(locator: locator, runner: runner, secrets: secrets, mode: providerMode).check()
        environment = report
        agents.claudeExecutable = report.claude.isOK ? report.claude.path : nil
        agents.processEnvironment = locator.environment()
    }

    private static let providerModeKey = "providerMode"

    func chooseProvider(_ mode: ProviderMode) async {
        providerMode = mode
        agents.providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.providerModeKey)
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
        _ = agents.usageRevision
        let start = UsagePeriod.week.displayedStart(at: .now, countingSince: usageResetPoint) ?? .now
        return (try? database.spend(since: start)) ?? 0
    }

    func agentSessions(in project: Project) -> [AgentSession] {
        guard let id = project.id else { return [] }
        _ = agents.usageRevision
        return (try? agents.sessions(inProject: id)) ?? []
    }

    func selectedAgent(in project: Project) -> AgentSession? {
        guard let projectID = project.id, let agentID = selectedAgents[projectID] else { return nil }
        return agentSessions(in: project).first { $0.id == agentID }
    }

    func select(_ session: AgentSession?, in project: Project) {
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
        let config = ProjectConfigLoader.load(repository: project.filesRoot)
        configs[id] = config
        reportMigration(RoleMigration.takeNotices(for: project.filesRoot), in: project)
    }

    private func reportMigration(_ notices: [MigrationNotice], in project: Project) {
        guard let id = project.id, !notices.isEmpty else { return }
        let body = "Roles are now built-in Lead, Builder and Checker agents. Ensemble updated this project:\n\n"
            + notices.map { "- \($0.file): \($0.message)" }.joined(separator: "\n")
        _ = try? database.createInboxItem(InboxItem(
            projectId: id, kind: .notice, title: "\(project.name) moved from roles to agent kinds", body: body, createdAt: .now
        ))
    }

    func reloadAllConfigs() {
        for project in openProjects {
            reloadConfig(for: project)
        }
        Task { await pullAllRemoteFiles() }
    }

    func installDefaultConfig(in project: Project) {
        perform("Couldn’t add the default workflows") {
            try ProjectConfigLoader.installDefaults(repository: project.filesRoot)
        }
        reloadConfig(for: project)
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
        _ = agents.usageRevision
        return (try? agents.agentNames(for: base, count: count, inProject: id)) ?? []
    }

    func spawnAgents(in project: Project, kind: AgentKind, count: Int, name: String, model: String, skills: [String], pinned: Bool, task: String) async throws {
        guard let git = requireGit() else { return }
        let sessions = try await agents.spawn(
            in: project,
            kind: kind,
            count: count,
            git: git,
            pinned: pinned,
            name: name,
            model: model,
            task: task,
            skills: skills
        )
        if sessions.count == 1 {
            select(sessions.first, in: project)
        }
        await refresh(project)
    }

    func updateSettings(_ settings: ProjectSettings, for project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t save project settings") {
            try database.updateSettings(settings, forProject: id)
        }
        reloadProjects()
        agents.startQueuedTurns(inProject: id)
    }

    func runs(for sessions: [AgentSession]) -> [Run] {
        let ids = Array(Set(sessions.compactMap(\.agent.runId)))
        return (try? database.runs(withIDs: ids)) ?? []
    }

    func project(withID id: Int64) -> Project? {
        openProjects.first { $0.id == id }
    }

    func deleteAgent(_ session: AgentSession, in project: Project, deleteBranch: Bool) async {
        guard let git = requireGit() else { return }
        do {
            try await agents.delete(session, in: project, git: git, deleteBranch: deleteBranch)
            if selectedAgent(in: project)?.id == session.id { select(nil, in: project) }
        } catch {
            alert = AppAlert(title: "Couldn’t delete \(displayName(of: session.agent, in: project))", message: error.localizedDescription)
        }
        await refresh(project)
    }

    func saveAPIKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Couldn’t save the API key") { try secrets.write(trimmed, for: .anthropicAPIKey) }
        await checkEnvironment()
    }

    func removeAPIKey() async {
        perform("Couldn’t remove the API key") { try secrets.delete(.anthropicAPIKey) }
        await checkEnvironment()
    }

    func openFolder(_ url: URL) async {
        guard let git = requireGit() else { return }
        do {
            let root = try await git.repositoryRoot(containing: url)
            let project = try database.openProject(at: root)
            reloadProjects()
            if let id = project.id {
                selection = .project(id)
            }
            await refresh(project)
        } catch is CommandError {
            alert = AppAlert(title: "Not a git repository", message: "\(url.path) isn’t inside a git repository. Ensemble needs git to give each agent its own worktree.")
        } catch {
            alert = AppAlert(title: "Couldn’t open \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    func clone(_ remote: String, into parent: URL, folderName: String) async throws {
        guard let git = requireGit() else { return }
        let destination = parent.appending(path: folderName, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CloneError.destinationExists(destination)
        }
        activeClones[remote] = .now
        defer { activeClones[remote] = nil }
        try await git.clone(remote, to: destination)
        await openFolder(destination)
    }

    func close(_ project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t close \(project.name)") { try database.closeProject(id: id) }
        projectStates[id] = nil
        remoteStatuses[id] = nil
        if let runner = appRunners[id] { Task { await runner.stop() } }
        reloadProjects()
        if selection == .project(id) {
            selection = openProjects.first?.id.map(SidebarItem.project)
        }
    }

    func forgetRecent(_ project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t remove \(project.name)") { try database.forgetProject(id: id) }
        if project.isRemote {
            try? FileManager.default.removeItem(at: RemoteMirror.location(forProject: id).directory.deletingLastPathComponent())
        }
        reloadProjects()
    }

    func refreshAllProjects() async {
        for project in openProjects {
            await refresh(project)
        }
    }

    func refresh(_ project: Project) async {
        if project.isRemote {
            await refreshRemote(project)
            return
        }
        guard let id = project.id, let git else { return }
        guard FileManager.default.fileExists(atPath: project.path) else {
            alert = AppAlert(title: "\(project.name) is missing", message: "\(project.path) no longer exists. It has been closed.")
            close(project)
            return
        }
        let manager = WorktreeManager(repository: project.url, git: git)
        do {
            let recovery = try await manager.recover()
            let branch = try await git.currentBranch(in: project.url)
            projectStates[id] = ProjectState(branch: branch, worktrees: recovery.worktrees, recovery: recovery)
            reloadConfig(for: project)
            _ = try? CheckSetupNotice.postIfNeeded(for: project, config: config(for: project), database: database)
        } catch {
            alert = AppAlert(title: "Couldn’t read worktrees for \(project.name)", message: error.localizedDescription)
        }
    }

    func refreshRemote(_ project: Project) async {
        guard let id = project.id, let destination = project.host else { return }
        remoteStatuses[id, default: RemoteProjectStatus()].isConnecting = true
        let host = remoteHost(destination)
        do {
            let info = try await host.probe()
            let manager = await remoteWorktreeManager(for: project, destination: destination)
            let recovery = try await manager.recover()
            let branch = try await host.currentBranch(in: project.path)
            projectStates[id] = ProjectState(branch: branch, worktrees: recovery.worktrees, recovery: recovery)
            try await pullRemoteFiles(project)
            remoteStatuses[id] = RemoteProjectStatus(info: info, filesPulledAt: .now)
        } catch {
            remoteStatuses[id] = RemoteProjectStatus(info: remoteStatuses[id]?.info, error: error.localizedDescription, filesPulledAt: remoteStatuses[id]?.filesPulledAt)
        }
    }

    func createWorktree(in project: Project, agent: String, slug: String) async throws {
        guard let manager = await worktreeManager(for: project) else { return }
        try await manager.create(agent: agent, slug: slug)
        await refresh(project)
    }

    func nextDebugAgentName(in project: Project) -> String {
        let taken = Set(state(for: project).worktrees.map(\.agent))
        return (1...).lazy.map { "debug-\($0)" }.first { !taken.contains($0) }!
    }

    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool, deleteBranch: Bool) async throws {
        guard let manager = await worktreeManager(for: project) else { return }
        await stopApp(runningIn: worktree.path)
        try await manager.remove(worktree, force: force, deleteBranch: deleteBranch)
        await refresh(project)
    }

    func deleteOrphanedDirectory(_ directory: URL, in project: Project) async {
        guard let manager = await worktreeManager(for: project) else { return }
        do {
            try await manager.deleteOrphanedDirectory(directory)
        } catch {
            alert = AppAlert(title: "Couldn’t delete \(directory.lastPathComponent)", message: error.localizedDescription)
        }
        await refresh(project)
    }

    private func worktreeManager(for project: Project) async -> WorktreeManager? {
        if let destination = project.host {
            return await remoteWorktreeManager(for: project, destination: destination)
        }
        return requireGit().map { WorktreeManager(repository: project.url, git: $0) }
    }

    private func requireGit() -> GitClient? {
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
