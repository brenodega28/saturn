import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

enum CommandTarget: Hashable {
    case agent(project: Int64, agent: Int64)
    case run(project: Int64, run: Int64)
    case file(project: Int64, path: String)
    case pin(project: Int64, pin: Int64)
}

struct WorkflowMenuAction: Equatable {
    enum Kind {
        case newWorkflow
        case history
    }

    let project: Int64
    let kind: Kind
}

struct PinPrompt: Identifiable {
    enum Kind {
        case requestChange
        case askAgent
    }

    let pin: Pin
    let kind: Kind

    var id: String { "\(pin.id ?? -1)-\(kind)" }
}

struct CommandContext {
    let model: AppModel
    let openWindow: OpenWindowAction?
    var target: CommandTarget?
}

struct MenuCommand: Identifiable {
    let id: String
    let title: String
    let menu: String
    var section = 0
    var order = 0
    var shortcut: KeyboardShortcut?
    var keywords = ""
    var isEnabled: @MainActor (CommandContext) -> Bool = { _ in true }
    var isChecked: (@MainActor (CommandContext) -> Bool)?
    let perform: @MainActor (CommandContext) -> Void
}

@MainActor
final class CommandRegistry {
    static let shared: CommandRegistry = {
        let registry = CommandRegistry()
        registry.registerMenuCommands()
        return registry
    }()

    static let menuBar = ["File", "View", "Navigate", "Agent", "Run", "Review", "Workflow", "Window", "Help"]

    private(set) var commands: [MenuCommand] = []

    func register(_ command: MenuCommand) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    func commands(in menu: String) -> [[MenuCommand]] {
        let matching = commands.filter { $0.menu == menu }
        return Dictionary(grouping: matching, by: \.section)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.order < $1.order } }
    }

    func command(_ id: String) -> MenuCommand? {
        commands.first { $0.id == id }
    }
}

extension KeyboardShortcut {
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.displayString
    }
}

extension KeyEquivalent {
    var displayString: String {
        switch self {
        case .return: "↩"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .delete: "⌫"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        default: String(character).uppercased()
        }
    }
}

extension Run {
    var displayTitle: String {
        title.isEmpty ? workflow : title
    }
}

@MainActor
extension CommandContext {
    func with(_ target: CommandTarget) -> CommandContext {
        var copy = self
        copy.target = target
        return copy
    }

    var agentSession: AgentSession? {
        if case .agent(let project, let agent) = target {
            return model.project(withID: project).flatMap { model.agentSessions(in: $0).first { $0.id == agent } }
        }
        guard case .agent(let agent) = model.mainScreen, let project = model.currentProject else { return nil }
        return model.agentSessions(in: project).first { $0.id == agent }
    }

    var agentProject: Project? {
        if case .agent(let project, _) = target { return model.project(withID: project) }
        guard case .agent = model.mainScreen else { return nil }
        return model.currentProject
    }

    var run: Run? {
        if case .run(_, let run) = target { return model.run(withID: run) }
        if case .run(let run) = model.mainScreen, let live = model.run(withID: run) { return live }
        if let session = agentSession, let run = session.agent.runId.flatMap(model.run(withID:)) { return run }
        return model.runToStop()
    }

    var pin: Pin? {
        if case .pin(_, let pin) = target { return try? model.database.pin(id: pin) }
        guard isReviewing else { return nil }
        return model.focusedPin()
    }

    var isReviewing: Bool {
        model.mainScreen == .tool(.changes) || model.mainScreen == .tool(.code)
    }

    var file: (project: Project, path: String)? {
        if case .file(let project, let path) = target, let project = model.project(withID: project) { return (project, path) }
        return nil
    }
}

extension AppModel {
    func run(withID id: Int64) -> Run? {
        engine.runs[id] ?? (try? database.run(id: id)) ?? nil
    }

    func runs(in projects: [Project]) -> [Run] {
        projects.compactMap(\.id).flatMap { (try? database.runs(projectId: $0)) ?? [] }
    }

    func runToStop() -> Run? {
        guard let project = currentProject?.id else { return nil }
        return engine.runs.values.filter { $0.projectId == project }.max { $0.startedAt < $1.startedAt }
    }

    func openPins(in project: Project) -> [(run: Run, pin: Pin)] {
        runs(in: [project]).filter { ProjectSignals.activeStatuses.contains($0.status) }.reversed().flatMap { run in
            ((try? database.pins(runId: run.id ?? -1)) ?? []).filter { $0.status == .open }.map { (run, $0) }
        }
    }

    func focusedPin() -> Pin? {
        guard let project = currentProject, let id = project.id else { return nil }
        let open = openPins(in: project)
        if let focused = focusedPinIDs[id], let match = open.first(where: { $0.pin.id == focused }) { return match.pin }
        return open.first?.pin
    }

    func stepPin(by offset: Int, opening: Bool = true) {
        guard let project = currentProject, let id = project.id else { return }
        let pins = openPins(in: project)
        guard !pins.isEmpty else { return }
        let current = focusedPinIDs[id].flatMap { focused in pins.firstIndex { $0.pin.id == focused } }
        let next = pins[current.map { ($0 + offset + pins.count) % pins.count } ?? 0]
        focusedPinIDs[id] = next.pin.id
        codeBrowser(for: project).open(next.pin.file, line: next.pin.startLine)
        if opening { open(.code) }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func heldForFailure(_ run: Run) -> Bool {
        guard let id = run.id, let hold = engine.holds[id] else { return false }
        return hold.reason == .stepFailed || hold.reason == .timedOut
    }

    func workflowIssues(_ editor: WorkflowEditor, config: ProjectConfig) -> [ConfigIssue] {
        var draft = editor.draft
        if editor.isNew {
            draft.id = ProjectConfigLoader.newWorkflowID(for: draft.name, existing: config.workflows)
        }
        var issues = ConfigValidator.validate(ProjectConfig(workflows: [draft], checks: config.checks))
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ConfigIssue(file: "", message: "a workflow needs a name"))
        }
        return issues
    }

    func suggestedWorkflowLabels(_ config: ProjectConfig, project: Project) -> [String] {
        let labels = config.workflows.flatMap(\.trigger.labels)
        return Array(Set(labels)).sorted()
    }
}

extension CommandRegistry {
    func registerMenuCommands() {
        registerFileCommands()
        registerViewCommands()
        registerNavigateCommands()
        registerAgentCommands()
        registerRunCommands()
        registerReviewCommands()
        registerWorkflowCommands()
        registerWindowCommands()
        registerFileContextCommands()
    }

    private func registerFileContextCommands() {
        register(MenuCommand(id: "file.open-editor", title: "Open", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file else { return }
            context.model.openFile(file.path, in: file.project)
        })
        register(MenuCommand(id: "file.protect", title: "Protect Path", menu: "Context", isEnabled: { context in
            guard let file = context.file else { return false }
            return !(context.model.config(for: file.project).checks?.protectedPaths.contains(file.path) ?? false)
        }) { context in
            guard let file = context.file else { return }
            var checks = context.model.config(for: file.project).checks ?? ChecksConfig(checks: [])
            checks.protectedPaths.append(file.path)
            do {
                try ProjectConfigLoader.write(checks, repository: file.project.filesRoot)
                context.model.reloadConfig(for: file.project)
            } catch {
                context.model.alert = AppAlert(title: "Couldn’t protect \(file.path)", message: error.localizedDescription)
            }
        })
        register(MenuCommand(id: "file.reveal", title: "Reveal in Code", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file else { return }
            context.model.openFile(file.path, in: file.project)
        })
        register(MenuCommand(id: "file.copy-path", title: "Copy Path", menu: "Context", shortcut: KeyboardShortcut("c", modifiers: [.command, .option]), isEnabled: { $0.file != nil }) { context in
            if let file = context.file { context.model.copyToPasteboard(file.path) }
        })
    }

    private func registerFileCommands() {
        register(MenuCommand(id: "file.new-project", title: "New Project…", menu: "File", section: 0, order: 0) { $0.model.newProject() })
        register(MenuCommand(id: "file.new-chat", title: "New Chat", menu: "File", section: 0, order: 1, shortcut: KeyboardShortcut("n")) { $0.model.requestNewChat() })
        register(MenuCommand(id: "file.open", title: "Open…", menu: "File", section: 0, order: 2, shortcut: KeyboardShortcut("o")) {
            $0.model.isOpenPanelPresented = true
        })
        register(MenuCommand(id: "file.open-ssh", title: "Open SSH Folder…", menu: "File", section: 0, order: 3) { $0.model.isRemoteFolderPresented = true })
        register(MenuCommand(id: "file.clone", title: "Clone…", menu: "File", section: 0, order: 4) { $0.model.isClonePresented = true })
        register(MenuCommand(id: "file.close-project", title: "Close Project", menu: "File", section: 1, order: 0, shortcut: KeyboardShortcut("w", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.currentProject != nil }) { context in
            if let project = context.model.currentProject { context.model.close(project) }
        })
    }

    private func registerViewCommands() {
        register(MenuCommand(id: "view.palette", title: "Command Palette…", menu: "View", section: 0, order: 0, shortcut: KeyboardShortcut("k")) { context in
            if context.model.isPalettePresented { context.model.isPalettePresented = false } else { context.model.openPalette() }
        })
        register(MenuCommand(id: "view.chat", title: "Chat", menu: "View", section: 1, order: 0, shortcut: KeyboardShortcut("0"),
                             isEnabled: { $0.model.currentProject != nil }, isChecked: { $0.model.mainScreen.isChat }) { context in
            if let project = context.model.currentProject { context.model.expand(project) }
        })
        for (index, tool) in MainTool.allCases.enumerated() {
            register(MenuCommand(
                id: "view.tool.\(tool.rawValue)", title: tool.title, menu: "View", section: 1, order: index + 1,
                shortcut: KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))),
                isEnabled: { tool.projectTab == nil || $0.model.currentProject != nil },
                isChecked: { $0.model.mainScreen == .tool(tool) }
            ) { $0.model.open(tool) })
        }
    }

    private func registerNavigateCommands() {
        register(MenuCommand(id: "navigate.back", title: "Back", menu: "Navigate", section: 0, order: 0, shortcut: KeyboardShortcut("[", modifiers: [.command]),
                             isEnabled: { $0.model.canGoBack }) { $0.model.goBack() })
        register(MenuCommand(id: "navigate.open-quickly", title: "Open Quickly…", menu: "Navigate", section: 1, order: 0, shortcut: KeyboardShortcut("p")) { context in
            if context.model.mainScreen == .tool(.code), let project = context.model.currentProject {
                context.model.codeBrowser(for: project).presentFinder()
            } else {
                context.model.openPalette()
            }
        })
        register(MenuCommand(id: "navigate.open-symbol", title: "Open Symbol…", menu: "Navigate", section: 1, order: 1, shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject else { return }
            context.model.open(.code)
            context.model.codeBrowser(for: project).presentFinder(.symbols)
        })
        register(MenuCommand(id: "navigate.go-run", title: "Go to Run…", menu: "Navigate", section: 1, order: 2) { $0.model.openPalette() })
        register(MenuCommand(id: "navigate.go-agent", title: "Go to Agent…", menu: "Navigate", section: 1, order: 3) { $0.model.openPalette(.agents) })
        register(MenuCommand(id: "navigate.next-pin", title: "Next Pin", menu: "Navigate", section: 2, order: 0, shortcut: KeyboardShortcut("'"),
                             isEnabled: { $0.model.focusedPin() != nil }) { $0.model.stepPin(by: 1) })
        register(MenuCommand(id: "navigate.previous-pin", title: "Previous Pin", menu: "Navigate", section: 2, order: 1, shortcut: KeyboardShortcut("'", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.focusedPin() != nil }) { $0.model.stepPin(by: -1) })
    }

    private func registerAgentCommands() {
        register(MenuCommand(id: "agent.open", title: "Open Session", menu: "Context", section: 0, order: 1,
                             isEnabled: { $0.agentSession != nil }) { context in
            if let session = context.agentSession, let project = context.agentProject { context.model.openAgentSession(session.agent, in: project) }
        })
        register(MenuCommand(id: "agent.spawn", title: "Spawn…", menu: "Agent", section: 0, order: 1, shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.currentProject != nil }) { $0.model.spawnAgent() })
        register(MenuCommand(id: "agent.pause", title: "Pause", menu: "Agent", section: 1, order: 0,
                             isEnabled: { $0.agentSession?.agent.status == .working }) { $0.agentSession?.pause() })
        register(MenuCommand(id: "agent.resume", title: "Resume", menu: "Agent", section: 1, order: 1,
                             isEnabled: { [.paused, .interrupted, .stopped].contains($0.agentSession?.agent.status) }) { $0.agentSession?.resume() })
        register(MenuCommand(id: "agent.stop", title: "Stop", menu: "Agent", section: 1, order: 2,
                             isEnabled: { $0.agentSession?.agent.status == .working }) { $0.agentSession?.stop() })
        register(MenuCommand(id: "agent.take-over", title: "Take Over", menu: "Agent", section: 1, order: 3,
                             isEnabled: { $0.agentSession?.agent.worktreeURL != nil }) { context in
            context.agentSession?.takeOver()
            context.model.takeOver(context.agentSession)
        })
        register(MenuCommand(id: "agent.restart", title: "Restart", menu: "Agent", section: 1, order: 4,
                             isEnabled: { $0.agentSession != nil }) { $0.agentSession?.restart() })
        register(MenuCommand(id: "agent.pin", title: "Pin", menu: "Agent", section: 2, order: 0,
                             isEnabled: { $0.agentSession != nil }, isChecked: { $0.agentSession?.agent.isPinned ?? false }) { context in
            guard let session = context.agentSession else { return }
            session.setPinned(!session.agent.isPinned)
        })
        register(MenuCommand(id: "agent.copy-worktree", title: "Copy Worktree Path", menu: "Context", section: 3, order: 0,
                             isEnabled: { $0.agentSession?.agent.worktreePath != nil }) { context in
            if let path = context.agentSession?.agent.worktreePath { context.model.copyToPasteboard(path) }
        })
    }

    private func registerRunCommands() {
        register(MenuCommand(id: "run.open", title: "Open Run", menu: "Context", section: 0, order: 0,
                             isEnabled: { $0.run != nil }) { context in
            if let run = context.run { context.model.openRunDetail(run) }
        })
        register(MenuCommand(id: "run.app-start", title: "Run the App", menu: "Run", section: 0, order: 0, shortcut: KeyboardShortcut("r"),
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject else { return }
            let target = context.model.selectedRunTarget(in: project)
            Task { await context.model.startApp(target, in: project) }
        })
        register(MenuCommand(id: "run.app-stop", title: "Stop the App", menu: "Run", section: 0, order: 1, shortcut: KeyboardShortcut("."),
                             isEnabled: { context in context.model.currentProject.flatMap(context.model.appRunner(for:))?.isActive ?? false }) { context in
            guard let project = context.model.currentProject else { return }
            Task { await context.model.stopApp(in: project) }
        })
        register(MenuCommand(id: "run.checks", title: "Run Checks", menu: "Run", section: 0, order: 2, shortcut: KeyboardShortcut("u"),
                             isEnabled: { $0.run != nil }) { context in
            guard let run = context.run else { return }
            if let id = run.id, let hold = context.model.engine.holds[id], hold.isChecksExhausted(in: run.snapshotWorkflow) {
                context.model.performRunAction("Couldn’t run the checks again") { try context.model.engine.resolveFailure(run, retry: true) }
            }
            context.model.openRunDetail(run)
        })
        register(MenuCommand(id: "run.retry-step", title: "Retry Step", menu: "Run", section: 1, order: 0,
                             isEnabled: { $0.run.map($0.model.heldForFailure) ?? false }) { context in
            guard let run = context.run else { return }
            context.model.performRunAction("Couldn’t retry the step") { try context.model.engine.resolveFailure(run, retry: true) }
        })
        register(MenuCommand(id: "run.dry-run", title: "Dry Run", menu: "Run", section: 1, order: 1,
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject else { return }
            let config = context.model.config(for: project)
            let workflow = context.run.flatMap { config.workflow($0.workflow) } ?? config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first
            if let workflow { context.model.testRun(workflow, in: project) }
        })
        register(MenuCommand(id: "run.pause", title: "Pause", menu: "Context", section: 2, order: 0,
                             isEnabled: { $0.run?.status == .running }) { context in
            guard let run = context.run else { return }
            Task { await context.model.performRunAction("Couldn’t pause the run") { try await context.model.engine.pause(run) } }
        })
        register(MenuCommand(id: "run.stop-target", title: "Stop", menu: "Context", section: 2, order: 1,
                             isEnabled: { $0.run.map { ProjectSignals.activeStatuses.contains($0.status) } ?? false }) { context in
            guard let run = context.run else { return }
            Task { await context.model.performRunAction("Couldn’t stop the run") { try await context.model.engine.cancel(run) } }
        })
        register(MenuCommand(id: "run.pause-all", title: "Pause All", menu: "Run", section: 2, order: 0, shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.currentProject != nil }) { $0.model.pauseAllAgentsInSelectedProject() })
        register(MenuCommand(id: "run.copy-id", title: "Copy Run ID", menu: "Context", section: 3, order: 1,
                             isEnabled: { $0.run?.id != nil }) { context in
            if let id = context.run?.id { context.model.copyToPasteboard(String(id)) }
        })
    }

    private func registerReviewCommands() {
        register(MenuCommand(id: "review.approve-pin", title: "Approve Pin", menu: "Review", section: 0, order: 0, shortcut: KeyboardShortcut(.return),
                             isEnabled: { $0.pin != nil }) { context in
            guard let pin = context.pin else { return }
            context.model.setPin(pin, status: .approved)
            context.model.stepPin(by: 1, opening: false)
        })
        register(MenuCommand(id: "review.request-change", title: "Request Change…", menu: "Review", section: 0, order: 1, shortcut: KeyboardShortcut(.return, modifiers: [.command, .option]),
                             isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.pinPrompt = PinPrompt(pin: pin, kind: .requestChange) }
        })
        register(MenuCommand(id: "review.ask-agent", title: "Ask Agent…", menu: "Review", section: 0, order: 2,
                             isEnabled: { $0.pin?.agentId != nil }) { context in
            if let pin = context.pin { context.model.pinPrompt = PinPrompt(pin: pin, kind: .askAgent) }
        })
        register(MenuCommand(id: "review.dismiss", title: "Dismiss", menu: "Context", section: 0, order: 3,
                             isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.setPin(pin, status: .approved, response: "Dismissed") }
        })
        register(MenuCommand(id: "review.approve-all", title: "Approve All & Continue", menu: "Review", section: 1, order: 0,
                             isEnabled: { context in context.run.map { ((try? context.model.database.openPinCount(runId: $0.id ?? -1)) ?? 0) > 0 || context.model.holdsForApproval($0) } ?? false }) { context in
            if let run = context.run { context.model.approveAllPins(in: run) }
        })
        register(MenuCommand(id: "review.encode", title: "Encode Correction…", menu: "Review", section: 2, order: 0, shortcut: KeyboardShortcut("e", modifiers: [.command, .shift]),
                             isEnabled: { $0.model.currentProject != nil }) { context in
            if let project = context.model.currentProject { context.model.openSettings(.learnedRules, in: project) }
        })
        register(MenuCommand(id: "review.copy-link", title: "Copy Link", menu: "Context", section: 3, order: 0,
                             isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.copyToPasteboard("\(pin.file):\(pin.startLine)-\(pin.endLine)") }
        })
    }

    private func registerWorkflowCommands() {
        register(MenuCommand(id: "workflow.new", title: "New Workflow…", menu: "Workflow", section: 0, order: 0,
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let id = context.model.currentProject?.id else { return }
            context.model.open(.workflows)
            context.model.workflowMenuAction = WorkflowMenuAction(project: id, kind: .newWorkflow)
        })
        register(MenuCommand(id: "workflow.edit", title: "Edit", menu: "Workflow", section: 0, order: 1,
                             isEnabled: { $0.model.currentProject != nil }) { $0.model.open(.workflows) })
        register(MenuCommand(id: "workflow.test-run", title: "Test Run", menu: "Workflow", section: 0, order: 2,
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject, let id = project.id else { return }
            let config = context.model.config(for: project)
            let workflow = context.model.workflowEditors[id]?.saved ?? config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first
            if let workflow { context.model.testRun(workflow, in: project) }
        })
        register(MenuCommand(id: "workflow.history", title: "Version History", menu: "Workflow", section: 0, order: 3,
                             isEnabled: { $0.model.currentProject != nil }) { context in
            guard let id = context.model.currentProject?.id else { return }
            context.model.open(.workflows)
            context.model.workflowMenuAction = WorkflowMenuAction(project: id, kind: .history)
        })
    }

    private func registerWindowCommands() {
        register(MenuCommand(id: "window.organizer", title: "Organizer", menu: "Window", section: 0, order: 0, shortcut: KeyboardShortcut("1", modifiers: [.command, .shift])) { context in
            context.openWindow?(id: WindowID.organizer)
        })
        register(MenuCommand(id: "window.library", title: "Library", menu: "Window", section: 0, order: 1, shortcut: KeyboardShortcut("l", modifiers: [.command, .shift]),
                             isChecked: { $0.model.mainWindow.isLibraryShown }) { context in
            context.model.mainWindow.isLibraryShown.toggle()
        })
        register(MenuCommand(id: "help.shortcuts", title: "Keyboard Shortcuts", menu: "Help", section: 0, order: 1, shortcut: KeyboardShortcut("/")) { _ in
            UserDefaults.standard.set("keys", forKey: AppSettingsView.tabKey)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate()
        })
        register(MenuCommand(id: "window.usage", title: "Usage", menu: "Window", section: 1, order: 1) { $0.model.open(.usage) })
        register(MenuCommand(id: "window.quality", title: "Quality", menu: "Window", section: 1, order: 2) { context in
            context.model.mainWindow.spec = nil
            context.model.selection = .quality
        })
        register(MenuCommand(id: "help.docs", title: "Ensemble Docs", menu: "Help", section: 0, order: 0) { _ in
            if let url = URL(string: "https://github.com/Monoliti/ensemble#readme") { NSWorkspace.shared.open(url) }
        })
        register(MenuCommand(id: "help.report", title: "Report an Issue…", menu: "Help", section: 0, order: 2) { _ in
            if let url = URL(string: "https://github.com/Monoliti/ensemble/issues/new") { NSWorkspace.shared.open(url) }
        })
    }
}

struct ContextCommands: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let groups: [[String]]
    let target: CommandTarget

    static let agent = [["agent.open"], ["agent.pause", "agent.resume", "agent.stop", "agent.take-over", "agent.restart"], ["agent.pin"], ["agent.copy-worktree"]]
    static let run = [["run.open", "run.checks", "run.retry-step", "run.dry-run"], ["run.pause", "run.stop-target"], ["run.copy-id"]]
    static let pin = [["review.approve-pin", "review.request-change", "review.ask-agent", "review.dismiss"], ["review.encode"], ["navigate.next-pin", "review.copy-link"]]
    static let file = [["file.open-editor"], ["file.protect"], ["file.reveal", "file.copy-path"]]

    var body: some View {
        let context = CommandContext(model: model, openWindow: openWindow).with(target)
        let groups = groups.map { $0.compactMap(CommandRegistry.shared.command) }.filter { !$0.isEmpty }
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { command in
                if let isChecked = command.isChecked {
                    Toggle(command.title, isOn: Binding(get: { isChecked(context) }, set: { _ in command.perform(context) }))
                        .disabled(!command.isEnabled(context))
                } else {
                    Button(command.title) { command.perform(context) }
                        .keyboardShortcut(KeyBindings.shared.shortcut(for: command))
                        .disabled(!command.isEnabled(context))
                }
            }
        }
    }
}

struct PinPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: PinPrompt
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.kind == .requestChange ? "Request a change" : "Ask the agent").font(.system(size: 15, weight: .semibold))
            Text("\(prompt.pin.title) · \((prompt.pin.file as NSString).lastPathComponent):\(prompt.pin.startLine)")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 8))
            if let result {
                Text(result).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.kind == .requestChange ? "Request Change" : "Send") {
                    switch prompt.kind {
                    case .requestChange:
                        model.setPin(prompt.pin, status: .changeRequested, response: text.isEmpty ? nil : text)
                        dismiss()
                    case .askAgent:
                        if model.askAgent(about: prompt.pin, question: text) { dismiss() } else { result = "Couldn’t reach the agent." }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.kind == .askAgent && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
