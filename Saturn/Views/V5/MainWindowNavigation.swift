import SaturnCore
import Foundation

enum MainTool: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case changes
    case agents
    case workflows
    case code
    case usage
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .agents: "Agents"
        case .workflows: "Workflows"
        case .code: "Code"
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .usage: "chart.bar"
        default: projectTab?.systemImage ?? "square"
        }
    }

    var projectTab: ProjectTab? {
        switch self {
        case .usage: nil
        case .changes: .changes
        case .agents: .agents
        case .workflows: .workflows
        case .code: .code
        case .settings: .settings
        }
    }

    init?(tab: ProjectTab) {
        switch tab {
        case .lead: return nil
        case .changes: self = .changes
        case .agents: self = .agents
        case .workflows: self = .workflows
        case .code: self = .code
        case .settings: self = .settings
        }
    }
}

enum MainScreen: Hashable {
    case none
    case chat
    case terminal
    case code
    case tool(MainTool)
    case project(ProjectPageSection)
    case run(Int64)
    case agent(Int64)
    case spec(String)

    var isChat: Bool { self == .chat }

    func shows(_ tool: MainTool) -> Bool {
        switch self {
        case .tool(let shown): shown == tool
        case .project(let section): ProjectPageSection(legacyTool: tool.rawValue) == section
        default: false
        }
    }
}

extension AppModel {
    var activePage: MainPage? { pages.active }

    var mainScreen: MainScreen {
        switch activePage?.kind {
        case nil: .none
        case .chat, .newChat: .chat
        case .terminal: .terminal
        case .code: .code
        case .tool(let tool, _): .tool(tool)
        case .project(_, let section): .project(section.key)
        case .run(let id, _): .run(id)
        case .agent(let id, _): .agent(id)
        case .spec(let path, _): .spec(path)
        }
    }

    var focusedChat: Chat? {
        activePage.flatMap { workspace(of: $0.kind)?.sideBarChat(for: $0.kind) }
    }

    var focusedChatTarget: DaemonChat? {
        guard let page = activePage, let workspace = workspace(of: page.kind),
              let chat = workspace.sideBarChat(for: page.kind) else { return nil }
        return DaemonChat(daemon: workspace.id, chat: chat)
    }

    func workspace(of kind: MainPageKind) -> DaemonWorkspace? {
        kind.daemon.flatMap(workspace(for:))
    }

    func project(of kind: MainPageKind) -> Project? {
        workspace(of: kind)?.project(of: kind)
    }

    func open(_ tool: MainTool) {
        if tool == .usage {
            pages.open(.tool(.usage, project: nil))
        } else if let project = currentProject {
            currentWorkspace.open(tool, in: project)
        }
    }

    func showPage(_ kind: MainPageKind) {
        pages.open(kind)
    }

    var canGoBack: Bool {
        currentProject != nil && !mainScreen.isChat
    }

    func goBack() {
        if let project = currentProject { currentWorkspace.showChat(in: project) }
    }

    func openTerminal() {
        guard let project = currentProject else { return }
        currentWorkspace.openTerminal(in: project)
    }

    func apply(_ page: MainPage?) {
        guard let kind = page?.kind else { return }
        if case .tool(.usage, _) = kind {
            selection = .usage
        } else {
            workspace(of: kind)?.apply(kind)
        }
    }

    func focusProject(_ ref: ProjectRef) {
        if selection != .project(ref) { selection = .project(ref) }
    }

    func pageClosed(_ page: MainPage) {
        terminals.terminate(page.id)
        codePages[page.id] = nil
    }

    func isLive(_ kind: MainPageKind) -> Bool {
        if case .tool(.usage, _) = kind { return true }
        guard let daemon = kind.daemon else { return false }
        guard let workspace = workspace(for: daemon) else { return knownDaemons.contains { $0.id == daemon } }
        guard workspace.isConnected || !workspace.isRemote else { return true }
        return workspace.isLive(kind)
    }

    func dropStalePages() {
        pages.retain { isLive($0.kind) }
    }

    func title(of kind: MainPageKind) -> String {
        if case .tool(.usage, _) = kind { return MainTool.usage.title }
        return workspace(of: kind)?.title(of: kind) ?? "Offline"
    }
}

extension DaemonWorkspace {
    func project(of kind: MainPageKind) -> Project? {
        switch kind {
        case .chat, .newChat, .terminal, .code, .spec, .tool, .project: kind.project.flatMap { project(withID: $0.id) }
        case .run(let id, _): run(withID: id).flatMap { project(withID: $0.projectId) }
        case .agent(let id, _): agent(id: id).flatMap { project(withID: $0.projectId) }
        }
    }

    var selectedRequestID: Int64? {
        app.currentProject.flatMap(selectedRequest(in:))?.id
    }

    func sideBarChat(for kind: MainPageKind) -> Chat? {
        switch kind {
        case .chat(let chatID?, _): try? database.task(id: chatID)
        case .terminal, .code: project(of: kind).flatMap(selectedRequest(in:))
        default: nil
        }
    }

    func showPage(_ kind: MainPageKind) {
        pages.open(kind)
    }

    func showChatPage(_ chatID: Int64?, inProjectID projectID: Int64) {
        guard let chatID else {
            openDraft(latestDraft(inProjectID: projectID) ?? draftStore.createNewDraft(projectID: projectID))
            return
        }
        requestPageProjectIDs.remove(projectID)
        pages.showChat(.chat(chatID: chatID, project: ref(projectID)))
    }

    func openDraft(_ draft: ChatDraft) {
        requestPageProjectIDs.remove(draft.projectID)
        pages.open(.newChat(draftID: draft.id, project: ref(draft.projectID)))
    }

    func latestDraft(inProjectID projectID: Int64) -> ChatDraft? {
        draftStore.newDrafts().filter { $0.projectID == projectID }.max { $0.updatedAt < $1.updatedAt }
    }

    func migrateLegacyNewChatPages() {
        for page in pages.pages where page.kind.isLegacyNewChat && page.kind.daemon == id {
            guard let project = page.kind.project else { continue }
            let draft = draftStore.createNewDraft(projectID: project.id)
            pages.replace(page.id, with: .newChat(draftID: draft.id, project: project))
        }
    }

    func showChat(_ request: Chat) {
        guard let id = request.id else { return }
        showChatPage(id, inProjectID: request.projectId)
    }

    func expand(_ project: Project) {
        showChat(in: project)
    }

    func startNewChat(in project: Project) {
        newChat(in: project)
    }

    func openSpecScreen(_ path: String, in project: Project) {
        guard let id = project.id else { return }
        pages.open(.spec(path: path, project: ref(id)))
    }

    func openTerminal(in project: Project) {
        guard let id = project.id else { return }
        let chosen = selectedRunTarget(in: project)
        let folder = chosen.isMain ? runTargets(in: project).dropFirst().first?.folder ?? project.url : chosen.folder
        pages.open(.terminal(project: ref(id), directory: folder.path), unique: false)
    }

    func apply(_ kind: MainPageKind) {
        switch kind {
        case .chat(let chatID, let project):
            app.focusProject(project)
            app.tabs[project] = .lead
            runDetailIDs[project.id] = nil
            leadSelections[project.id] = chatID.map(LeadSelection.request) ?? .newRequest
        case .newChat(_, let project):
            app.focusProject(project)
            app.tabs[project] = .lead
            runDetailIDs[project.id] = nil
            leadSelections[project.id] = .newRequest
        case .tool(let tool, let project?):
            app.focusProject(project)
            if let tab = tool.projectTab { app.tabs[project] = tab }
            runDetailIDs[project.id] = nil
        case .tool(_, nil):
            break
        case .project(let project, let section):
            app.focusProject(project)
            if let tab = section.tab { app.tabs[project] = tab }
            runDetailIDs[project.id] = nil
            if case .settings(let settings) = section { settingsSections[project.id] = settings }
        case .run(let runID, _):
            guard let run = run(withID: runID) else { return }
            app.focusProject(ref(run.projectId))
            runDetailIDs[run.projectId] = runID
        case .agent(let agentID, _):
            guard let agent = agent(id: agentID) else { return }
            app.focusProject(ref(agent.projectId))
            app.tabs[ref(agent.projectId)] = .agents
            selectedAgents[agent.projectId] = agentID
        case .terminal(let project, _), .code(let project, _), .spec(_, let project):
            app.focusProject(project)
        }
    }

    func isLive(_ kind: MainPageKind) -> Bool {
        switch kind {
        case .chat(let chatID, let project):
            guard self.project(withID: project.id) != nil else { return false }
            guard let chatID else { return true }
            return (try? database.task(id: chatID))?.projectId == project.id
        case .newChat(let draftID, let project):
            return self.project(withID: project.id) != nil && draftStore.newDraft(id: draftID) != nil
        case .tool(_, let project):
            return project.flatMap { self.project(withID: $0.id) } != nil
        case .project(let project, _):
            return self.project(withID: project.id) != nil
        case .run(let id, _):
            return run(withID: id).flatMap { project(withID: $0.projectId) } != nil
        case .agent(let id, _):
            return agent(id: id).flatMap { project(withID: $0.projectId) } != nil
        case .terminal(let project, _), .code(let project, _), .spec(_, let project):
            return self.project(withID: project.id) != nil
        }
    }

    func title(of kind: MainPageKind) -> String {
        switch kind {
        case .chat(let chatID?, _): (try? database.task(id: chatID))?.title ?? "Chat"
        case .chat(nil, _): "New chat"
        case .newChat(let draftID, _): draftStore.newDraft(id: draftID)?.title ?? "New chat"
        case .terminal(let project, let directory):
            "Terminal · \(self.project(withID: project.id).map { terminalPlace(directory, in: $0) } ?? (directory as NSString).lastPathComponent)"
        case .code(_, let path): (path as NSString).lastPathComponent
        case .tool(let tool, _): tool.title
        case .project(let project, _): self.project(withID: project.id)?.name ?? "Project"
        case .run(let id, _): run(withID: id).map { "Run · \($0.displayTitle)" } ?? "Run"
        case .agent(let id, _): agent(id: id).map { displayName(of: $0) } ?? "Agent"
        case .spec(let path, _): "Spec · \(specTitle(atPath: path))"
        }
    }

    func terminalPlace(_ directory: String, in project: Project) -> String {
        let root = (project.path as NSString).standardizingPath
        let path = (directory as NSString).standardizingPath
        if path == root { return project.name }
        if let agent = agentSessions(in: project).map(\.agent).first(where: { $0.worktreePath.map { ($0 as NSString).standardizingPath } == path }) {
            return displayName(of: agent, in: project)
        }
        return (path as NSString).lastPathComponent
    }
}
