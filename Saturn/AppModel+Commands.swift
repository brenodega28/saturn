import SaturnCore
import Foundation

enum PaletteMode: Equatable {
    case everything
    case agents
}

struct TestRunRequest: Equatable {
    let project: ProjectRef
    let workflow: String
}

enum DetailDestination: Codable, Hashable {
    case run(project: ProjectRef, run: Int64)
    case agent(project: ProjectRef, agent: Int64)
    case file(project: ProjectRef, path: String)
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
        currentWorkspace.newChat(in: project)
    }

    func openPalette(_ mode: PaletteMode = .everything) {
        paletteMode = mode
        isPalettePresented = true
    }

    func spawnAgent() {
        guard let ref = currentRef else { return }
        selection = .project(ref)
        isNewAgentPresented = true
    }

    func pauseAllAgentsInSelectedProject() {
        guard let project = currentProject else { return }
        currentWorkspace.pauseAllAgents(in: project)
    }

    func goToSection(_ index: Int) {
        let tabs = ProjectTab.sidebarOrder
        guard let project = currentProject, tabs.indices.contains(index) else { return }
        currentWorkspace.setTab(tabs[index], for: project)
    }

    func sendToLead(_ text: String) {
        guard let project = currentProject else { return }
        currentWorkspace.sendToLead(text, in: project)
    }

    func openFileFinder() {
        guard let project = currentProject else { return }
        let browser = currentWorkspace.codeBrowser(for: project)
        isPageFinderShown = !mainScreen.shows(.code)
        browser.presentFinder()
        if browser.snapshot == nil { Task { await browser.refreshSources() } }
    }
}

extension DaemonWorkspace {
    func newChat(in project: Project) {
        startNewLeadRequest(in: project)
        composerFocusToken += 1
    }

    func showChat(in project: Project) {
        guard let id = project.id else { return }
        if let page = pages.pages.first(where: { $0.kind.isChat && $0.kind.project == ref(id) }) {
            requestPageProjectIDs.remove(id)
            pages.focus(page.id)
        } else {
            showChatPage(selectedRequest(in: project)?.id, inProjectID: id)
        }
    }

    func openAgent(_ session: LiveAgentSession, in project: Project) {
        select(session, in: project)
    }

    func sendToLead(_ text: String, in project: Project) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let draft = startNewLeadRequest(in: project) else { return }
        deliverLeadMessage(PendingMessage(text: trimmed), lead: leadRole(in: project), to: nil, fromDraft: draft.id, in: project)
    }

    func openFile(_ path: String, in project: Project, line: Int? = nil) {
        guard let id = project.id else { return }
        let root = codeBrowser(for: project).source?.root ?? project.url
        let absolute = path.hasPrefix("/") ? path : root.appending(path: path).path
        if let line { pendingCodeLines[absolute] = line }
        showPage(.code(project: ref(id), path: absolute))
    }

    func revealInCode(_ path: String, in project: Project) {
        setTab(.code, for: project)
        codeBrowser(for: project).open(path)
    }

    func testRun(_ workflow: WorkflowDefinition, in project: Project) {
        guard let id = project.id else { return }
        app.testRunRequest = TestRunRequest(project: ref(id), workflow: workflow.id)
        setTab(.workflows, for: project)
    }

    func hasPendingPins(in project: Project) -> Bool {
        guard let id = project.id else { return false }
        return ((try? database.openPinCounts(projectId: id)) ?? [:]).values.contains { $0 > 0 }
    }

    func openSettings(_ section: SettingsSection, in project: Project) {
        openProject(project, section: .settings(section))
    }
}
