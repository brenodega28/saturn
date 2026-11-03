import EnsembleCore
import Foundation
import Observation

enum MainTool: String, CaseIterable, Identifiable, Hashable {
    case inbox
    case changes
    case agents
    case tasks
    case workflows
    case code
    case usage
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .changes: "Changes"
        case .agents: "Agents"
        case .tasks: "Tasks"
        case .workflows: "Workflows"
        case .code: "Code"
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }

    var projectTab: ProjectTab? {
        switch self {
        case .inbox, .usage: nil
        case .changes: .changes
        case .agents: .agents
        case .tasks: .tasks
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
        case .tasks: self = .tasks
        case .workflows: self = .workflows
        case .code: self = .code
        case .settings: self = .settings
        }
    }
}

enum MainScreen: Hashable {
    case chat
    case tool(MainTool)
    case run(Int64)
    case agent(Int64)
    case spec(String)

    var isChat: Bool { self == .chat }
}

struct SpecScreen: Hashable {
    let path: String
    let project: Int64?
    let chat: LeadSelection?
    let base: MainScreen
}

@MainActor
@Observable
final class MainWindowNavigation {
    var back: MainScreen?
    var spec: SpecScreen?
    var isLibraryShown = false

    func record(from old: MainScreen, to new: MainScreen) {
        switch new {
        case .chat, .tool:
            back = nil
        case .run, .agent, .spec:
            if case .tool = old { back = old }
        }
    }
}

extension AppModel {
    var baseScreen: MainScreen {
        switch selection {
        case .inbox: return .tool(.inbox)
        case .usage, .quality: return .tool(.usage)
        case .project(let id):
            if let run = runDetailIDs[id] { return .run(run) }
            let tab = tabs[id] ?? .lead
            if tab == .agents, let agent = selectedAgents[id] { return .agent(agent) }
            return MainTool(tab: tab).map(MainScreen.tool) ?? .chat
        case nil: return .chat
        }
    }

    var mainScreen: MainScreen {
        let base = baseScreen
        if let spec = mainWindow.spec, spec.base == base, spec.project == currentProject?.id,
           spec.chat == currentProject?.id.flatMap({ leadSelections[$0] }) {
            return .spec(spec.path)
        }
        return base
    }

    var selectedRequestID: Int64? {
        currentProject.flatMap(selectedRequest(in:))?.id
    }

    func open(_ tool: MainTool) {
        mainWindow.spec = nil
        switch tool {
        case .inbox:
            selection = .inbox
        case .usage:
            selection = .usage
        default:
            guard let project = currentProject, let id = project.id, let tab = tool.projectTab else { return }
            runDetailIDs[id] = nil
            if tool == .agents { selectedAgents[id] = nil }
            tabs[id] = tab
            selection = .project(id)
        }
    }

    func showChat(_ request: ProjectTask) {
        guard let project = project(withID: request.projectId) else { return }
        mainWindow.spec = nil
        showChat(in: project)
        showRequest(request)
    }

    func expand(_ project: Project) {
        mainWindow.spec = nil
        showChat(in: project)
        guard let id = project.id else { return }
        requestPageProjectIDs.remove(id)
        if case .agent = chatTargets[id] { chatTargets[id] = nil }
    }

    func startNewChat(in project: Project) {
        mainWindow.spec = nil
        newChat(in: project)
    }

    func openSpecScreen(_ path: String, in project: Project) {
        mainWindow.spec = SpecScreen(path: path, project: project.id, chat: project.id.flatMap { leadSelections[$0] }, base: baseScreen)
    }

    var canGoBack: Bool {
        !mainScreen.isChat
    }

    func goBack() {
        let screen = mainScreen
        if case .spec = screen {
            mainWindow.spec = nil
            return
        }
        if let back = mainWindow.back, case .tool(let tool) = back, screen != back {
            open(tool)
            return
        }
        if let project = currentProject {
            expand(project)
        }
    }
}
