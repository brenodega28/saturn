import AppKit
import EnsembleCore
import Foundation
import Observation

enum SidebarItem: Hashable, Codable {
    case usage
    case project(ProjectRef)
}

struct DaemonChat: Hashable, Identifiable {
    let daemon: DaemonID
    let chat: Chat

    var id: String { "\(daemon.uuidString)-\(chat.id ?? -1)" }
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
    let localID: DaemonID
    private(set) var workspaces: [DaemonID: DaemonWorkspace] = [:]
    var knownDaemons: [KnownDaemon]
    var serverProblems: [String: ServerProblem] = [:]
    var serverChecks: Set<String> = []
    var addingServers: Set<String> = []
    let locator: ToolLocator
    let runner: CommandRunner
    let requestNotifier = RequestNotifier()
    let planUsage = PlanUsagePoller()
    @ObservationIgnored private var planUsageActivationObserver: NSObjectProtocol?

    private(set) var environment: EnvironmentReport?
    private(set) var providerMode: ProviderMode?
    private(set) var isCheckingEnvironment = false
    var isNewAgentPresented = false
    var leadChatRevision = 0
    var composerFocusToken = 0
    var paletteMode: PaletteMode = .everything
    var testRunRequest: TestRunRequest?
    let activityLog = ActivityLog()
    var isRunMenuOpen = false
    var isNewChatPickerShown = false
    var isAppOutputShown = false
    var composerPrefill: String?
    var pendingChatDeletion: DaemonChat?
    var activeClones: [String: Date] = [:]
    var listeningPorts: Set<Int> = []
    var isOffline = false
    var problemCursor = -1
    var pinPrompt: PinPrompt?
    var workflowMenuAction: WorkflowMenuAction?
    let pages: MainPages
    let terminals = TerminalStore()
    @ObservationIgnored var codePages: [UUID: CodeBrowser] = [:]
    var isPageFinderShown = false
    @ObservationIgnored weak var mainWindowRef: NSWindow?
    @ObservationIgnored var connectivity: ConnectivityMonitor?

    var selection: SidebarItem? {
        didSet {
            if case .project(let ref) = selection {
                lastProjectID = ref
                if tabs[ref] == nil { tabs[ref] = .lead }
            }
            persistNavigation()
        }
    }
    var lastProjectID: ProjectRef?
    var tabs: [ProjectRef: ProjectTab] = [:]

    var isPalettePresented = false
    var isClonePresented = false
    var isOpenPanelPresented = false
    var isRemoteFolderPresented = false
    var remoteHostInfos: [String: RemoteHostInfo] = [:]
    var alert: AppAlert?
    var chatHighlight: ChatLink?

    init(connection: DaemonConnection, clientPaths: AppPaths, daemonPaths: AppPaths, locator: ToolLocator = ToolLocator()) {
        self.localID = connection.id
        self.daemonPaths = daemonPaths
        let known = Self.loadKnownDaemons(clientPaths)
        self.knownDaemons = known
        self.clientPaths = clientPaths
        self.providerMode = AppDefaults.store.string(forKey: Self.providerModeKey).flatMap(ProviderMode.init(rawValue:))
        self.locator = locator
        self.runner = CommandRunner(environment: locator.environment())
        self.pages = MainPages(legacyDaemons: [connection.id] + known.map(\.id))
        workspaces[connection.id] = DaemonWorkspace(connection: connection, app: self)
        restoreNavigation()
        pages.onActivate = { [weak self] page in self?.apply(page) }
        pages.onClose = { [weak self] page in self?.pageClosed(page) }
        apply(pages.active)
        CommandRegistry.shared.registerChatLinkCommands()
        planUsageActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlanUsageOnActivation() }
        }
    }

    var local: DaemonWorkspace { workspaces[localID]! }

    var orderedWorkspaces: [DaemonWorkspace] {
        workspaces.values.sorted { lhs, rhs in
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func workspace(for id: DaemonID) -> DaemonWorkspace? {
        workspaces[id]
    }

    func add(_ workspace: DaemonWorkspace) {
        workspaces[workspace.id] = workspace
    }

    func remove(_ workspace: DaemonWorkspace) {
        workspace.stop()
        workspaces[workspace.id] = nil
    }

    var git: GitClient? {
        guard let path = locator.locate("git") else { return nil }
        return GitClient(executable: path, runner: runner)
    }

    func project(at ref: ProjectRef) -> Project? {
        workspace(for: ref.daemon)?.project(withID: ref.id)
    }

    var selectedProject: Project? {
        guard case .project(let ref) = selection else { return nil }
        return project(at: ref)
    }

    var currentRef: ProjectRef? {
        if case .project(let ref) = selection, project(at: ref) != nil { return ref }
        if let ref = lastProjectID, project(at: ref) != nil { return ref }
        return orderedWorkspaces.lazy.compactMap { workspace in workspace.openProjects.first?.id.map(workspace.ref) }.first
    }

    var currentProject: Project? {
        currentRef.flatMap(project(at:))
    }

    var currentWorkspace: DaemonWorkspace {
        currentRef.flatMap { workspace(for: $0.daemon) } ?? local
    }

    var hasOpenProjects: Bool {
        workspaces.values.contains { !$0.openProjects.isEmpty }
    }

    func projectsChanged(in workspace: DaemonWorkspace) {
        let openIDs = Set(workspace.openProjects.compactMap(\.id))
        if case .project(let ref) = selection, ref.daemon == workspace.id, !openIDs.contains(ref.id) {
            selection = firstProject
        } else if selection == nil {
            selection = firstProject
        }
    }

    private var firstProject: SidebarItem? {
        orderedWorkspaces.lazy.compactMap { workspace in workspace.openProjects.first?.id.map { SidebarItem.project(workspace.ref($0)) } }.first
    }

    func launch() async {
        local.reloadProjects()
        adoptKnownDaemons()
        dropStalePages()
        apply(pages.active)
        local.start()
        requestNotifier.onOpen = { [weak self] target, daemon in self?.openNotification(target, on: daemon) }
        requestNotifier.onAction = { [weak self] action, messageID, daemon in
            self?.workspace(for: daemon ?? self?.localID ?? UUID())?.performNotificationAction(action, messageID: messageID)
        }
        requestNotifier.requestAuthorization()
        await local.migrateSettingsToDaemon()
        await checkEnvironment()
        updatePlanUsagePolling()
        await local.refreshAllProjects()
        Task { await connectRemoteDaemons() }
        connectivity = ConnectivityMonitor { [weak self] offline in self?.isOffline = offline }
    }

    func checkEnvironment() async {
        isCheckingEnvironment = true
        defer { isCheckingEnvironment = false }
        guard let daemonEnvironment = try? await local.send(SettingsCommands.CheckEnvironment()) else { return }
        environment = daemonEnvironment.report
        if let mode = daemonEnvironment.providerMode, providerMode != mode {
            providerMode = mode
            AppDefaults.store.set(mode.rawValue, forKey: Self.providerModeKey)
        }
    }

    static let providerModeKey = "providerMode"

    func chooseProvider(_ mode: ProviderMode) async {
        providerMode = mode
        AppDefaults.store.set(mode.rawValue, forKey: Self.providerModeKey)
        await local.command("Couldn’t change how agents sign in", SettingsCommands.SetProviderMode(mode: mode))
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

    func saveAPIKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await local.saveAPIKey(trimmed)
        await checkEnvironment()
    }

    func removeAPIKey() async {
        await local.removeAPIKey()
        await checkEnvironment()
    }

    func openFolder(_ url: URL) async {
        await local.openFolder(url)
    }

    func clone(_ remote: String, into parent: URL, folderName: String) async throws {
        try await local.clone(remote, into: parent, folderName: folderName)
    }

    func reloadAllConfigs() {
        for workspace in workspaces.values { workspace.reloadAllConfigs() }
    }

    func requireGit() -> GitClient? {
        if git == nil {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
        }
        return git
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func stopAllAppsImmediately() {
        for workspace in workspaces.values { workspace.stopAllAppsImmediately() }
    }

    func stopAllConnections() {
        for workspace in workspaces.values { workspace.connection.stop() }
    }

    private static let selectionKey = "navigation.selection"

    private func persistNavigation() {
        AppDefaults.store.set(try? JSONEncoder().encode(selection), forKey: Self.selectionKey)
    }

    private func restoreNavigation() {
        let savedSelection = AppDefaults.store.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(SidebarItem?.self, from: $0) }
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
