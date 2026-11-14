import EnsembleCore
import Foundation

enum PaletteMode: Equatable {
    case everything
    case agents
}

struct TestRunRequest: Equatable {
    let project: Int64
    let workflow: String
}

enum DetailDestination: Codable, Hashable {
    case run(project: Int64, run: Int64)
    case agent(project: Int64, agent: Int64)
    case file(project: Int64, path: String)
}

extension ProjectTab {
    static let sidebarOrder: [ProjectTab] = [.lead, .agents, .workflows, .changes, .code, .settings]
}

extension AppModel {
    func newChat() {
        guard let project = currentProject else {
            newProject()
            return
        }
        newChat(in: project)
    }

    func newChat(in project: Project) {
        showChat(in: project)
        startNewLeadRequest(in: project)
        composerFocusToken += 1
    }

    func showChat(in project: Project) {
        guard let id = project.id else { return }
        selection = .project(id)
        runDetailIDs[id] = nil
        setTab(.lead, for: project)
    }

    func openPalette(_ mode: PaletteMode = .everything) {
        paletteMode = mode
        isPalettePresented = true
    }

    func spawnAgent() {
        guard let id = currentProject?.id else { return }
        selection = .project(id)
        isNewAgentPresented = true
    }

    func pauseAllAgentsInSelectedProject() {
        guard let project = currentProject else { return }
        pauseAllAgents(in: project)
    }

    func openAgent(_ session: AgentSession, in project: Project) {
        guard let id = project.id else { return }
        selection = .project(id)
        select(session, in: project)
    }

    func goToSection(_ index: Int) {
        if index == 0 {
            selection = .inbox
            return
        }
        let tabs = ProjectTab.sidebarOrder
        guard let project = currentProject, let id = project.id, tabs.indices.contains(index - 1) else { return }
        selection = .project(id)
        runDetailIDs[id] = nil
        setTab(tabs[index - 1], for: project)
    }

    func sendToLead(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let project = currentProject else { return }
        showChat(in: project)
        startNewLeadRequest(in: project)
        Task { await sendLeadMessage(trimmed, lead: leadRole(in: project), to: nil, in: project) }
    }

    func openFile(_ path: String, in project: Project) {
        guard let id = project.id else { return }
        selection = .project(id)
        setTab(.code, for: project)
        codeBrowser(for: project).open(path)
    }

    func testRun(_ workflow: WorkflowDefinition, in project: Project) {
        guard let id = project.id else { return }
        selection = .project(id)
        testRunRequest = TestRunRequest(project: id, workflow: workflow.id)
        setTab(.workflows, for: project)
    }

    func hasPendingPins(in project: Project) -> Bool {
        guard let id = project.id else { return false }
        return ((try? database.openPinCounts(projectId: id)) ?? [:]).values.contains { $0 > 0 }
    }

    func openSettings(_ section: SettingsSection, in project: Project) {
        guard let id = project.id else { return }
        selection = .project(id)
        settingsSections[id] = section
        setTab(.settings, for: project)
    }
}
