import EnsembleCore
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
    case run(Int64)
    case agent(Int64)
    case spec(String)

    var isChat: Bool { self == .chat }
}

extension AppModel {
    static func pagesKey(for daemon: DaemonID) -> String {
        "pages.\(daemon.uuidString.lowercased())"
    }

    var activePage: MainPage? { pages.active }

    var mainScreen: MainScreen {
        switch activePage?.kind {
        case nil: .none
        case .chat: .chat
        case .terminal: .terminal
        case .code: .code
        case .tool(let tool, _): .tool(tool)
        case .run(let id): .run(id)
        case .agent(let id): .agent(id)
        case .spec(let path, _): .spec(path)
        }
    }

    var selectedRequestID: Int64? {
        currentProject.flatMap(selectedRequest(in:))?.id
    }

    var focusedChat: Chat? {
        activePage.flatMap { sideBarChat(for: $0.kind) }
    }

    func project(of kind: MainPageKind) -> Project? {
        switch kind {
        case .chat(_, let id), .terminal(let id, _), .code(let id, _), .spec(_, let id): project(withID: id)
        case .tool(_, let id): id.flatMap(project(withID:))
        case .run(let id): run(withID: id).flatMap { project(withID: $0.projectId) }
        case .agent(let id): agent(id: id).flatMap { project(withID: $0.projectId) }
        }
    }

    func sideBarChat(for kind: MainPageKind) -> Chat? {
        switch kind {
        case .chat(let chatID?, _): try? database.task(id: chatID)
        case .terminal, .code: project(of: kind).flatMap(selectedRequest(in:))
        default: nil
        }
    }

    func open(_ tool: MainTool) {
        if tool == .usage {
            pages.open(.tool(.usage, projectID: nil))
        } else if let id = currentProject?.id {
            pages.open(.tool(tool, projectID: id))
        }
    }

    func showPage(_ kind: MainPageKind) {
        pages.open(kind)
    }

    func showChatPage(_ chatID: Int64?, inProjectID projectID: Int64) {
        requestPageProjectIDs.remove(projectID)
        guard let chatID else {
            pages.open(.chat(chatID: nil, projectID: projectID))
            return
        }
        pages.showChat(.chat(chatID: chatID, projectID: projectID))
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
        pages.open(.spec(path: path, projectID: id))
    }

    var canGoBack: Bool {
        currentProject != nil && !mainScreen.isChat
    }

    func goBack() {
        if let project = currentProject { showChat(in: project) }
    }

    func openTerminal(in project: Project? = nil) {
        guard let project = project ?? currentProject, let id = project.id else { return }
        let chosen = selectedRunTarget(in: project)
        let folder = chosen.isMain ? runTargets(in: project).dropFirst().first?.folder ?? project.url : chosen.folder
        pages.open(.terminal(projectID: id, directory: folder.path), unique: false)
    }

    func apply(_ page: MainPage?) {
        guard let kind = page?.kind else { return }
        switch kind {
        case .chat(let chatID, let projectID):
            focusProject(projectID)
            tabs[projectID] = .lead
            runDetailIDs[projectID] = nil
            leadSelections[projectID] = chatID.map(LeadSelection.request) ?? .newRequest
        case .tool(.usage, _):
            selection = .usage
        case .tool(let tool, let projectID?):
            focusProject(projectID)
            if let tab = tool.projectTab { tabs[projectID] = tab }
            runDetailIDs[projectID] = nil
        case .tool(_, nil):
            break
        case .run(let runID):
            guard let run = run(withID: runID) else { return }
            focusProject(run.projectId)
            runDetailIDs[run.projectId] = runID
        case .agent(let agentID):
            guard let agent = agent(id: agentID) else { return }
            focusProject(agent.projectId)
            tabs[agent.projectId] = .agents
            selectedAgents[agent.projectId] = agentID
        case .terminal(let projectID, _), .code(let projectID, _), .spec(_, let projectID):
            focusProject(projectID)
        }
    }

    private func focusProject(_ id: Int64) {
        if selection != .project(id) { selection = .project(id) }
    }

    func pageClosed(_ page: MainPage) {
        terminals.terminate(page.id)
        codePages[page.id] = nil
    }

    func isLive(_ kind: MainPageKind) -> Bool {
        switch kind {
        case .chat(let chatID, let projectID):
            guard project(withID: projectID) != nil else { return false }
            guard let chatID else { return true }
            return (try? database.task(id: chatID))?.projectId == projectID
        case .tool(.usage, _):
            return true
        case .tool(_, let projectID):
            return projectID.flatMap(project(withID:)) != nil
        case .run(let id):
            return run(withID: id).flatMap { project(withID: $0.projectId) } != nil
        case .agent(let id):
            return agent(id: id).flatMap { project(withID: $0.projectId) } != nil
        case .terminal(let projectID, _), .code(let projectID, _), .spec(_, let projectID):
            return project(withID: projectID) != nil
        }
    }

    func dropStalePages() {
        pages.retain { isLive($0.kind) }
    }

    func title(of kind: MainPageKind) -> String {
        switch kind {
        case .chat(let chatID?, _): (try? database.task(id: chatID))?.title ?? "Chat"
        case .chat(nil, _): "New chat"
        case .terminal(let projectID, let directory):
            "Terminal · \(project(withID: projectID).map { terminalPlace(directory, in: $0) } ?? (directory as NSString).lastPathComponent)"
        case .code(_, let path): (path as NSString).lastPathComponent
        case .tool(let tool, _): tool.title
        case .run(let id): run(withID: id).map { "Run · \($0.displayTitle)" } ?? "Run"
        case .agent(let id): agent(id: id).map { displayName(of: $0) } ?? "Agent"
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
