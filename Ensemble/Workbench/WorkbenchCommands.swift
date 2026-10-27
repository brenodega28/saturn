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
        guard let active = workbench?.active, active.kind == EditorKindID.agent else { return nil }
        return model.session(for: active)
    }

    var agentProject: Project? {
        if case .agent(let project, _) = target { return model.project(withID: project) }
        return workbench?.active.flatMap { $0.kind == EditorKindID.agent ? model.project(of: $0) : nil }
    }

    var run: Run? {
        if case .run(_, let run) = target { return model.run(withID: run) }
        if let active = workbench?.active, active.kind == EditorKindID.run, let run = active.number.flatMap(model.run(withID:)) { return run }
        if let session = agentSession, let run = session.agent.runId.flatMap(model.run(withID:)) { return run }
        return model.runToStop(in: workbench)
    }

    var pin: Pin? {
        if case .pin(_, let pin) = target { return try? model.database.pin(id: pin) }
        guard isReviewing else { return nil }
        return model.focusedPin()
    }

    var isReviewing: Bool {
        guard let workbench else { return false }
        if workbench.navigatorTab == "pins", workbench.isShowing(.navigator) { return true }
        guard let active = workbench.active else { return false }
        return active.kind == EditorKindID.file || active.tab == .changes
    }

    var file: (project: Project, path: String)? {
        if case .file(let project, let path) = target, let project = model.project(withID: project) { return (project, path) }
        guard let active = workbench?.active, active.kind == EditorKindID.file, let path = active.ref, let project = model.project(of: active) else { return nil }
        return (project, path)
    }
}

extension AppModel {
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

    func stepPin(by offset: Int, workbench: WorkbenchState?) {
        guard let project = currentProject, let id = project.id else { return }
        let open = openPins(in: project)
        guard !open.isEmpty else { return }
        let current = focusedPinIDs[id].flatMap { focused in open.firstIndex { $0.pin.id == focused } }
        let next = open[current.map { ($0 + offset + open.count) % open.count } ?? 0]
        focusedPinIDs[id] = next.pin.id
        codeBrowser(for: project).open(next.pin.file, line: next.pin.startLine)
        workbench?.open(.file(next.pin.file, in: id))
    }

    func stepProblem(workbench: WorkbenchState?) {
        guard let workbench else { return }
        let problems = problems(scope: .project)
        guard !problems.isEmpty else { return }
        problemCursor = (problemCursor + 1) % problems.count
        let next = problems[problemCursor]
        open(next.problem, in: next.project, workbench: workbench)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func heldForFailure(_ run: Run) -> Bool {
        guard let id = run.id, let hold = engine.holds[id] else { return false }
        return hold.reason == .stepFailed || hold.reason == .timedOut
    }
}

extension WorkbenchRegistry {
    func registerMenuCommands() {
        registerFileCommands()
        registerNavigateCommands()
        registerAgentCommands()
        registerRunCommands()
        registerReviewCommands()
        registerWorkflowCommands()
        registerWindowCommands()
        registerFileContextCommands()
    }

    private func registerFileContextCommands() {
        register(WorkbenchCommand(id: "file.open-editor", title: "Open", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file, let id = file.project.id else { return }
            context.workbench?.open(.file(file.path, in: id))
        })
        register(WorkbenchCommand(id: "file.open-split", title: "Open in Split", menu: "Context", isEnabled: { $0.file != nil && $0.workbench?.active != nil }) { context in
            guard let file = context.file, let id = file.project.id else { return }
            context.workbench?.secondary = .file(file.path, in: id)
            context.workbench?.isSplit = true
        })
        register(WorkbenchCommand(id: "file.diff", title: "Show Diff vs Base", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file else { return }
            let base = context.model.config(for: file.project).preferences.baseBranch ?? "main"
            TerminalSession.shared(for: file.project.url).run("git --no-pager diff \(base) -- '\(file.path)'", environment: context.model.locator.environment())
            context.workbench?.bottomTab = "terminal"
            context.workbench?.show(.bottom)
        })
        register(WorkbenchCommand(id: "file.history", title: "Show History", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file, let id = file.project.id else { return }
            context.workbench?.open(.file(file.path, in: id))
            context.workbench?.inspectorTabs[InspectorSubject.Kind.file.rawValue] = "history"
            context.workbench?.show(.inspector)
        })
        register(WorkbenchCommand(id: "file.risk", title: "Show Risk Tier", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file, let id = file.project.id else { return }
            context.workbench?.open(.file(file.path, in: id))
            context.workbench?.inspectorTabs[InspectorSubject.Kind.file.rawValue] = "risk"
            context.workbench?.show(.inspector)
        })
        register(WorkbenchCommand(id: "file.protect", title: "Protect Path", menu: "Context", isEnabled: { context in
            guard let file = context.file else { return false }
            return !(context.model.config(for: file.project).checks?.protectedPaths.contains(file.path) ?? false)
        }) { context in
            guard let file = context.file else { return }
            var checks = context.model.config(for: file.project).checks ?? ChecksConfig(checks: [])
            checks.protectedPaths.append(file.path)
            do {
                try ProjectConfigLoader.write(checks, repository: file.project.url)
                context.model.reloadConfig(for: file.project)
            } catch {
                context.model.alert = AppAlert(title: "Couldn’t protect \(file.path)", message: error.localizedDescription)
            }
        })
        register(WorkbenchCommand(id: "file.reveal", title: "Reveal in Source Navigator", menu: "Context", isEnabled: { $0.file != nil }) { context in
            guard let file = context.file else { return }
            context.model.codeBrowser(for: file.project).open(file.path)
            context.workbench?.navigatorTab = "source"
            context.workbench?.show(.navigator)
        })
        register(WorkbenchCommand(id: "file.copy-path", title: "Copy Path", menu: "Context", shortcut: KeyboardShortcut("c", modifiers: [.command, .option]), isEnabled: { $0.file != nil }) { context in
            if let file = context.file { context.model.copyToPasteboard(file.path) }
        })
    }

    private func registerFileCommands() {
        register(WorkbenchCommand(id: "file.new-project", title: "New Project…", menu: "File", section: 0, order: 0,
                                  shortcut: nil) { $0.model.newProject() })
        register(WorkbenchCommand(id: "file.new-task", title: "New Task", menu: "File", section: 0, order: 1, shortcut: KeyboardShortcut("n"),
                                  isEnabled: { _ in true }) { $0.model.newTask() })
        register(WorkbenchCommand(id: "file.open", title: "Open…", menu: "File", section: 0, order: 2, shortcut: KeyboardShortcut("o")) {
            $0.model.isOpenPanelPresented = true
        })
        register(WorkbenchCommand(id: "file.clone", title: "Clone…", menu: "File", section: 0, order: 3) { $0.model.isClonePresented = true })
        register(WorkbenchCommand(id: "file.close-project", title: "Close Project", menu: "File", section: 1, order: 0, shortcut: KeyboardShortcut("w", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            if let project = context.model.currentProject { context.model.close(project) }
        })
    }

    private func registerNavigateCommands() {
        register(WorkbenchCommand(id: "navigate.open-quickly", title: "Open Quickly…", menu: "Navigate", section: -2, order: 0, shortcut: KeyboardShortcut("p")) { context in
            if let active = context.workbench?.active, active.tab == .code || active.kind == EditorKindID.file, let project = context.model.project(of: active) {
                context.model.codeBrowser(for: project).presentFinder()
            } else {
                context.model.openPalette()
            }
        })
        register(WorkbenchCommand(id: "navigate.open-symbol", title: "Open Symbol…", menu: "Navigate", section: -2, order: 1, shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject, let id = project.id else { return }
            context.workbench?.open(.section(.code, in: id))
            context.model.codeBrowser(for: project).presentFinder(.symbols)
        })
        register(WorkbenchCommand(id: "navigate.go-run", title: "Go to Run…", menu: "Navigate", section: -2, order: 2) { context in
            context.workbench?.navigatorTab = "runs"
            context.workbench?.show(.navigator)
        })
        register(WorkbenchCommand(id: "navigate.go-agent", title: "Go to Agent…", menu: "Navigate", section: -2, order: 3) { $0.model.openPalette(.agents) })
        register(WorkbenchCommand(id: "navigate.next-pin", title: "Next Pin", menu: "Navigate", section: -1, order: 0, shortcut: KeyboardShortcut("'"),
                                  isEnabled: { $0.model.focusedPin() != nil }) { $0.model.stepPin(by: 1, workbench: $0.workbench) })
        register(WorkbenchCommand(id: "navigate.previous-pin", title: "Previous Pin", menu: "Navigate", section: -1, order: 1, shortcut: KeyboardShortcut("'", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.focusedPin() != nil }) { $0.model.stepPin(by: -1, workbench: $0.workbench) })
        register(WorkbenchCommand(id: "navigate.next-problem", title: "Next Problem", menu: "Navigate", section: -1, order: 2, shortcut: KeyboardShortcut("'", modifiers: [.command, .control]),
                                  isEnabled: { $0.workbench != nil }) { $0.model.stepProblem(workbench: $0.workbench) })
    }

    private func registerAgentCommands() {
        register(WorkbenchCommand(id: "agent.message", title: "Message…", menu: "Agent", section: 0, order: 0, shortcut: KeyboardShortcut("j"),
                                  isEnabled: { !$0.model.openProjects.isEmpty }) { context in
            if let session = context.agentSession, let project = context.agentProject, context.target != nil {
                context.model.message(session, in: project)
            } else {
                context.model.openPalette(.agents)
            }
        })
        register(WorkbenchCommand(id: "agent.open", title: "Open Session", menu: "Context", section: 0, order: 1,
                                  isEnabled: { $0.agentSession != nil }) { context in
            if let session = context.agentSession, let id = context.agentProject?.id { context.workbench?.open(.agent(session.id, in: id)) }
        })
        register(WorkbenchCommand(id: "agent.spawn", title: "Spawn…", menu: "Agent", section: 0, order: 1, shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.currentProject != nil }) { $0.model.spawnAgent() })
        register(WorkbenchCommand(id: "agent.pause", title: "Pause", menu: "Agent", section: 1, order: 0,
                                  isEnabled: { $0.agentSession?.agent.status == .working }) { $0.agentSession?.pause() })
        register(WorkbenchCommand(id: "agent.resume", title: "Resume", menu: "Agent", section: 1, order: 1,
                                  isEnabled: { [.paused, .interrupted, .stopped].contains($0.agentSession?.agent.status) }) { $0.agentSession?.resume() })
        register(WorkbenchCommand(id: "agent.stop", title: "Stop", menu: "Agent", section: 1, order: 2,
                                  isEnabled: { $0.agentSession?.agent.status == .working }) { $0.agentSession?.stop() })
        register(WorkbenchCommand(id: "agent.take-over", title: "Take Over", menu: "Agent", section: 1, order: 3,
                                  isEnabled: { $0.agentSession?.agent.worktreeURL != nil }) { context in
            context.agentSession?.takeOver()
            context.model.takeOver(context.agentSession)
        })
        register(WorkbenchCommand(id: "agent.restart", title: "Restart", menu: "Agent", section: 1, order: 4,
                                  isEnabled: { $0.agentSession != nil }) { $0.agentSession?.restart() })
        register(WorkbenchCommand(id: "agent.pin", title: "Pin", menu: "Agent", section: 2, order: 0,
                                  isEnabled: { $0.agentSession != nil }, isChecked: { $0.agentSession?.agent.isPinned ?? false }) { context in
            guard let session = context.agentSession else { return }
            session.setPinned(!session.agent.isPinned)
        })
        register(WorkbenchCommand(id: "agent.memory", title: "Edit Memory…", menu: "Agent", section: 2, order: 1,
                                  isEnabled: { $0.agentSession?.agent.isPinned == true }) { context in
            guard let session = context.agentSession, let id = context.agentProject?.id else { return }
            context.workbench?.open(.agent(session.id, in: id))
            context.workbench?.inspectorTabs[InspectorSubject.Kind.agent.rawValue] = "memory"
            context.workbench?.show(.inspector)
        })
        register(WorkbenchCommand(id: "agent.copy-worktree", title: "Copy Worktree Path", menu: "Context", section: 3, order: 0,
                                  isEnabled: { $0.agentSession?.agent.worktreePath != nil }) { context in
            if let path = context.agentSession?.agent.worktreePath { context.model.copyToPasteboard(path) }
        })
    }

    private func registerRunCommands() {
        register(WorkbenchCommand(id: "run.open", title: "Open Run", menu: "Context", section: 0, order: 0,
                                  isEnabled: { $0.run != nil }) { context in
            if let run = context.run, let id = run.id { context.workbench?.open(.run(id, in: run.projectId)) }
        })
        register(WorkbenchCommand(id: "run.checks", title: "Run Checks", menu: "Run", section: 0, order: 2, shortcut: KeyboardShortcut("u"),
                                  isEnabled: { $0.workbench != nil }) { context in
            if let run = context.run, let id = run.id, let hold = context.model.engine.holds[id], hold.isChecksExhausted(in: run.snapshotWorkflow) {
                context.model.performRunAction("Couldn’t run the checks again") { try context.model.engine.resolveFailure(run, retry: true) }
            }
            context.workbench?.bottomTab = "checks"
            context.workbench?.show(.bottom)
        })
        register(WorkbenchCommand(id: "run.retry-step", title: "Retry Step", menu: "Run", section: 1, order: 0,
                                  isEnabled: { $0.run.map($0.model.heldForFailure) ?? false }) { context in
            guard let run = context.run else { return }
            context.model.performRunAction("Couldn’t retry the step") { try context.model.engine.resolveFailure(run, retry: true) }
        })
        register(WorkbenchCommand(id: "run.dry-run", title: "Dry Run", menu: "Run", section: 1, order: 1,
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject else { return }
            let config = context.model.config(for: project)
            let workflow = context.run.flatMap { config.workflow($0.workflow) } ?? config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first
            if let workflow { context.model.testRun(workflow, in: project) }
        })
        register(WorkbenchCommand(id: "run.pause", title: "Pause", menu: "Context", section: 2, order: 0,
                                  isEnabled: { $0.run?.status == .running }) { context in
            guard let run = context.run else { return }
            Task { await context.model.performRunAction("Couldn’t pause the run") { try await context.model.engine.pause(run) } }
        })
        register(WorkbenchCommand(id: "run.stop-target", title: "Stop", menu: "Context", section: 2, order: 1,
                                  isEnabled: { $0.run.map { ProjectSignals.activeStatuses.contains($0.status) } ?? false }) { context in
            guard let run = context.run else { return }
            Task { await context.model.performRunAction("Couldn’t stop the run") { try await context.model.engine.cancel(run) } }
        })
        register(WorkbenchCommand(id: "run.pause-all", title: "Pause All", menu: "Run", section: 2, order: 0, shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.currentProject != nil }) { $0.model.pauseAllAgentsInSelectedProject() })
        register(WorkbenchCommand(id: "run.logs", title: "Show Logs", menu: "Context", section: 3, order: 0) { context in
            context.workbench?.bottomTab = "log"
            context.workbench?.show(.bottom)
        })
        register(WorkbenchCommand(id: "run.copy-id", title: "Copy Run ID", menu: "Context", section: 3, order: 1,
                                  isEnabled: { $0.run?.id != nil }) { context in
            if let id = context.run?.id { context.model.copyToPasteboard(String(id)) }
        })
    }

    private func registerReviewCommands() {
        register(WorkbenchCommand(id: "review.approve-pin", title: "Approve Pin", menu: "Review", section: 0, order: 0, shortcut: KeyboardShortcut(.return),
                                  isEnabled: { $0.pin != nil }) { context in
            guard let pin = context.pin else { return }
            context.model.setPin(pin, status: .approved)
            context.model.stepPin(by: 1, workbench: nil)
        })
        register(WorkbenchCommand(id: "review.request-change", title: "Request Change…", menu: "Review", section: 0, order: 1, shortcut: KeyboardShortcut(.return, modifiers: [.command, .option]),
                                  isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.pinPrompt = PinPrompt(pin: pin, kind: .requestChange) }
        })
        register(WorkbenchCommand(id: "review.ask-agent", title: "Ask Agent…", menu: "Review", section: 0, order: 2,
                                  isEnabled: { $0.pin?.agentId != nil }) { context in
            if let pin = context.pin { context.model.pinPrompt = PinPrompt(pin: pin, kind: .askAgent) }
        })
        register(WorkbenchCommand(id: "review.dismiss", title: "Dismiss", menu: "Context", section: 0, order: 3,
                                  isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.setPin(pin, status: .approved, response: "Dismissed") }
        })
        register(WorkbenchCommand(id: "review.approve-all", title: "Approve All & Continue", menu: "Review", section: 1, order: 0,
                                  isEnabled: { context in context.run.map { ((try? context.model.database.openPinCount(runId: $0.id ?? -1)) ?? 0) > 0 || context.model.holdsForApproval($0) } ?? false }) { context in
            if let run = context.run { context.model.approveAllPins(in: run) }
        })
        register(WorkbenchCommand(id: "review.open-pr", title: "Open PR", menu: "Review", section: 1, order: 1,
                                  isEnabled: { $0.run?.pullRequestURL != nil }) { context in
            if let url = context.run?.pullRequestURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        })
        register(WorkbenchCommand(id: "review.encode", title: "Encode Correction…", menu: "Review", section: 2, order: 0, shortcut: KeyboardShortcut("e", modifiers: [.command, .shift]),
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            if let project = context.model.currentProject { context.model.openSettings(.learnedRules, in: project) }
        })
        register(WorkbenchCommand(id: "review.copy-link", title: "Copy Link", menu: "Context", section: 3, order: 0,
                                  isEnabled: { $0.pin != nil }) { context in
            if let pin = context.pin { context.model.copyToPasteboard("\(pin.file):\(pin.startLine)-\(pin.endLine)") }
        })
    }

    private func registerWorkflowCommands() {
        register(WorkbenchCommand(id: "workflow.new", title: "New Workflow…", menu: "Workflow", section: 0, order: 0,
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            guard let id = context.model.currentProject?.id else { return }
            context.workbench?.open(.section(.workflows, in: id))
            context.model.workflowMenuAction = WorkflowMenuAction(project: id, kind: .newWorkflow)
        })
        register(WorkbenchCommand(id: "workflow.edit", title: "Edit", menu: "Workflow", section: 0, order: 1,
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            if let id = context.model.currentProject?.id { context.workbench?.open(.section(.workflows, in: id)) }
        })
        register(WorkbenchCommand(id: "workflow.test-run", title: "Test Run", menu: "Workflow", section: 0, order: 2,
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            guard let project = context.model.currentProject, let id = project.id else { return }
            let config = context.model.config(for: project)
            let workflow = context.model.workflowEditors[id]?.saved ?? config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first
            if let workflow { context.model.testRun(workflow, in: project) }
        })
        register(WorkbenchCommand(id: "workflow.history", title: "Version History", menu: "Workflow", section: 0, order: 3,
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            guard let id = context.model.currentProject?.id else { return }
            context.workbench?.open(.section(.workflows, in: id))
            context.model.workflowMenuAction = WorkflowMenuAction(project: id, kind: .history)
        })
    }

    private func registerWindowCommands() {
        register(WorkbenchCommand(id: "window.inbox", title: "Inbox", menu: "Window", section: 1, order: 0) { $0.model.selection = .inbox })
        register(WorkbenchCommand(id: "window.usage", title: "Usage", menu: "Window", section: 1, order: 1) { $0.model.selection = .usage })
        register(WorkbenchCommand(id: "window.quality", title: "Quality", menu: "Window", section: 1, order: 2) { $0.model.selection = .quality })
        register(WorkbenchCommand(id: "help.docs", title: "Ensemble Docs", menu: "Help", section: 0, order: 0) { _ in
            if let url = URL(string: "https://github.com/Monoliti/ensemble#readme") { NSWorkspace.shared.open(url) }
        })
        register(WorkbenchCommand(id: "help.report", title: "Report an Issue…", menu: "Help", section: 0, order: 2) { _ in
            if let url = URL(string: "https://github.com/Monoliti/ensemble/issues/new") { NSWorkspace.shared.open(url) }
        })
    }
}

struct ContextCommands: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(WorkbenchState.self) private var workbench
    let groups: [[String]]
    let target: CommandTarget

    static let agent = [["agent.message", "agent.open"], ["agent.pause", "agent.resume", "agent.stop", "agent.take-over", "agent.restart"], ["agent.pin", "agent.memory"], ["agent.copy-worktree"]]
    static let run = [["run.open", "run.checks", "run.retry-step", "run.dry-run"], ["run.pause", "run.stop-target"], ["run.logs", "run.copy-id"]]
    static let pin = [["review.approve-pin", "review.request-change", "review.ask-agent", "review.dismiss"], ["review.encode"], ["navigate.next-pin", "review.copy-link"]]
    static let file = [["file.open-editor", "file.open-split", "file.diff", "file.history"], ["file.risk", "file.protect"], ["file.reveal", "file.copy-path"]]

    var body: some View {
        let context = CommandContext(model: model, workbench: workbench, openWindow: openWindow).with(target)
        let groups = groups.map { $0.compactMap(WorkbenchRegistry.shared.command) }.filter { !$0.isEmpty }
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { command in
                if let isChecked = command.isChecked {
                    Toggle(command.title, isOn: Binding(get: { isChecked(context) }, set: { _ in command.perform(context) }))
                        .disabled(!command.isEnabled(context))
                } else {
                    Button(command.title) { command.perform(context) }
                        .keyboardShortcut(command.shortcut)
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
