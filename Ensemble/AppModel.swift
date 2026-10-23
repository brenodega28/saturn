import EnsembleCore
import Foundation
import Observation

enum SidebarItem: Hashable, Codable {
    case inbox
    case usage
    case project(Int64)
}

enum ProjectTab: String, CaseIterable, Identifiable, Codable {
    case tasks
    case lead
    case agents
    case changes
    case workflows
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .lead: "Lead"
        case .agents: "Agents"
        case .changes: "Changes"
        case .workflows: "Workflows"
        case .settings: "Settings"
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
    var runDetailIDs: [Int64: Int64] = [:]

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

    var selection: SidebarItem? {
        didSet { persistNavigation() }
    }
    var tabs: [Int64: ProjectTab] = [:] {
        didSet { persistNavigation() }
    }

    var isPalettePresented = false
    var isClonePresented = false
    var isOpenPanelPresented = false
    var alert: AppAlert?

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
        self.gitHub = GitHubIntegration(engine: engine, secrets: secrets)
        self.inbox = InboxFeed(database: database)
        driver.gitProvider = { [weak self] in self?.git }
        driver.gitHubProvider = { try? GitHubAuth(secrets: secrets).client() }
        restoreNavigation()
        connectGitHub()
    }

    var git: GitClient? {
        guard case .found(let path, _) = environment?.git else { return nil }
        return GitClient(executable: path, runner: runner)
    }

    var selectedProject: Project? {
        guard case .project(let id) = selection else { return nil }
        return openProjects.first { $0.id == id }
    }

    func tab(for project: Project) -> ProjectTab {
        project.id.flatMap { tabs[$0] } ?? .agents
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
        await checkEnvironment()
        perform("Couldn’t recover runs") { try engine.recover() }
        startInbox()
        gitHub.start()
        await refreshAllProjects()
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
        await checkEnvironment()
    }

    var weeklySpend: Double {
        _ = agents.usageRevision
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
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
        return ProjectConfigLoader.load(repository: project.url)
    }

    func hasConfig(_ project: Project) -> Bool {
        _ = configs[project.id ?? -1]
        return ProjectConfigLoader.hasConfig(repository: project.url)
    }

    func reloadConfig(for project: Project) {
        guard let id = project.id else { return }
        configs[id] = ProjectConfigLoader.load(repository: project.url)
    }

    func reloadAllConfigs() {
        for project in openProjects {
            reloadConfig(for: project)
        }
    }

    func installDefaultConfig(in project: Project) {
        perform("Couldn’t add the default roles and workflows") {
            try ProjectConfigLoader.installDefaults(repository: project.url)
        }
        reloadConfig(for: project)
    }

    func role(for agent: Agent, in project: Project) -> RoleDefinition? {
        config(for: project).role(agent.role)
    }

    func agentNames(for base: String, count: Int, in project: Project) -> [String] {
        guard let id = project.id else { return [] }
        _ = agents.usageRevision
        return (try? agents.agentNames(for: base, count: count, inProject: id)) ?? []
    }

    func spawnAgents(in project: Project, role: RoleDefinition, count: Int, name: String, pinned: Bool, task: String) async throws {
        guard let git = requireGit() else { return }
        let sessions = try await agents.spawn(
            in: project,
            role: role,
            count: count,
            config: config(for: project),
            git: git,
            pinned: pinned,
            name: name,
            task: task
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
            alert = AppAlert(title: "Couldn’t delete \(session.agent.name)", message: error.localizedDescription)
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
        try await git.clone(remote, to: destination)
        await openFolder(destination)
    }

    func close(_ project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t close \(project.name)") { try database.closeProject(id: id) }
        projectStates[id] = nil
        reloadProjects()
        if selection == .project(id) {
            selection = openProjects.first?.id.map(SidebarItem.project)
        }
    }

    func forgetRecent(_ project: Project) {
        guard let id = project.id else { return }
        perform("Couldn’t remove \(project.name)") { try database.forgetProject(id: id) }
        reloadProjects()
    }

    func refreshAllProjects() async {
        for project in openProjects {
            await refresh(project)
        }
    }

    func refresh(_ project: Project) async {
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
        } catch {
            alert = AppAlert(title: "Couldn’t read worktrees for \(project.name)", message: error.localizedDescription)
        }
    }

    func createWorktree(in project: Project, agent: String, slug: String) async throws {
        guard let manager = worktreeManager(for: project) else { return }
        try await manager.create(agent: agent, slug: slug)
        await refresh(project)
    }

    func nextDebugAgentName(in project: Project) -> String {
        let taken = Set(state(for: project).worktrees.map(\.agent))
        return (1...).lazy.map { "debug-\($0)" }.first { !taken.contains($0) }!
    }

    func removeWorktree(_ worktree: Worktree, in project: Project, force: Bool, deleteBranch: Bool) async throws {
        guard let manager = worktreeManager(for: project) else { return }
        try await manager.remove(worktree, force: force, deleteBranch: deleteBranch)
        await refresh(project)
    }

    func deleteOrphanedDirectory(_ directory: URL, in project: Project) async {
        guard let manager = worktreeManager(for: project) else { return }
        perform("Couldn’t delete \(directory.lastPathComponent)") { try manager.deleteOrphanedDirectory(directory) }
        await refresh(project)
    }

    private func worktreeManager(for project: Project) -> WorktreeManager? {
        requireGit().map { WorktreeManager(repository: project.url, git: $0) }
    }

    private func requireGit() -> GitClient? {
        if git == nil {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
        }
        return git
    }

    private func reloadProjects() {
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
        let defaults = UserDefaults.standard
        let savedTabs = defaults.data(forKey: Self.tabsKey).flatMap { try? JSONDecoder().decode([Int64: ProjectTab].self, from: $0) }
        let savedSelection = defaults.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(SidebarItem?.self, from: $0) }
        tabs = savedTabs ?? [:]
        selection = savedSelection ?? nil
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
