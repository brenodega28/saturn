import EnsembleCore
import EnsembleUI
import SwiftUI

extension WorkbenchRegistry {
    func registerBuiltIns() {
        registerEditorKinds()
        register(NavigatorTabSpec(id: NavigatorTabID.workspace, title: "Workspace", systemImage: "folder", order: 0) {
            AnyView(WorkspaceNavigator())
        })
        register(NavigatorTabSpec(id: "runs", title: "Runs", systemImage: "play.circle", order: 10, showsScope: true) {
            AnyView(RunsNavigator())
        })
        register(NavigatorTabSpec(id: "agents", title: "Agents", systemImage: "person.2", order: 20, showsScope: true) {
            AnyView(AgentsNavigator())
        })
        register(NavigatorTabSpec(id: "source", title: "Source", systemImage: "list.bullet.indent", order: 30) {
            AnyView(SourceNavigator())
        })
        register(NavigatorTabSpec(id: "source-control", title: "Source control", systemImage: "arrow.triangle.branch", order: 40) {
            AnyView(SourceControlNavigator())
        })
        register(NavigatorTabSpec(id: "pins", title: "Pins", systemImage: "pin", order: 50, showsScope: true, badge: { model in
            model.currentProject.flatMap(\.id).map { ((try? model.database.openPinCounts(projectId: $0)) ?? [:]).values.reduce(0, +) }
        }) {
            AnyView(PinsNavigator())
        })
        register(NavigatorTabSpec(id: "checks", title: "Checks", systemImage: "checklist", order: 60, showsScope: true, badge: { model in
            let runs = model.runs(in: model.navigatorProjects(.project)).filter { ProjectSignals.activeStatuses.contains($0.status) }
            return ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs), holds: model.engine.holds).filter { $0.state != .passed }.count
        }) {
            AnyView(ChecksNavigator())
        })
        register(NavigatorTabSpec(id: "problems", title: "Problems", systemImage: "exclamationmark.triangle", order: 70, showsScope: true, badge: { model in
            model.problems(scope: .project).count
        }) {
            AnyView(ProblemsNavigator())
        })
        register(NavigatorTabSpec(id: "find", title: "Find", systemImage: "magnifyingglass", order: 80, showsScope: true) {
            AnyView(FindNavigator())
        })
        registerInspectors()
        registerBottomPanels()
        registerActivitySources()
        registerToolbar()
        registerToolbarItems()
        registerMenuCommands()
        registerStatusItems()
        registerViewCommands()
        registerNavigatorCommands()
    }

    private func registerEditorKinds() {
        register(EditorKindSpec(
            id: EditorKindID.inbox,
            title: { _, _ in "Inbox" },
            systemImage: { _ in "tray" },
            jumpBar: { _, model in [JumpSegment(title: "Inbox"), JumpSegment(title: model.inboxCount == 1 ? "1 waiting" : "\(model.inboxCount) waiting")] },
            content: { _ in AnyView(InboxView()) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.usage,
            title: { _, _ in "Usage" },
            systemImage: { _ in "chart.bar" },
            jumpBar: { _, _ in [JumpSegment(title: "All projects"), JumpSegment(title: "Usage")] },
            content: { _ in AnyView(UsageView()) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.quality,
            title: { _, _ in "Quality" },
            systemImage: { _ in "gauge.with.dots.needle.50percent" },
            jumpBar: { _, _ in [JumpSegment(title: "All projects"), JumpSegment(title: "Quality")] },
            content: { _ in AnyView(QualityView()) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.section,
            title: { item, model in
                guard let tab = item.tab else { return "Project" }
                if tab == .lead, let project = model.project(of: item), let target = model.chatTargetName(in: project) {
                    return "Chat · \(target)"
                }
                return tab.title
            },
            systemImage: { item in item.tab?.systemImage ?? "folder" },
            jumpBar: { item, model in
                guard let project = model.project(of: item), let tab = item.tab, let id = project.id else { return [] }
                return [
                    model.projectSegment(project) { .section(tab, in: $0) },
                    JumpSegment(title: tab.title, options: ProjectTab.sidebarOrder.map {
                        JumpOption(title: $0.title, isCurrent: $0 == tab, item: .section($0, in: id))
                    }),
                ]
            },
            inspectorSubject: { item, model in
                guard item.tab == .workflows, let project = item.project, let editor = model.workflowEditors[project] else { return nil }
                return .step(project: project, workflow: editor.draft.id, step: editor.selection.nodeID ?? "")
            },
            accessory: { item in
                AnyView(ProjectAccessoryHost(item: item))
            },
            isAvailable: { item, _ in item.tab != nil },
            content: { item in AnyView(ProjectScreenHost(item: item)) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.run,
            title: { item, model in "Run: \(model.runTitle(item))" },
            systemImage: { _ in "play.circle" },
            jumpBar: { item, model in
                guard let project = model.project(of: item), let id = project.id else { return [] }
                let runs = model.recentRuns(in: project)
                return [
                    model.projectSegment(project) { .section(.tasks, in: $0) },
                    JumpSegment(title: "Runs", options: [JumpOption(title: "Tasks", item: .section(.tasks, in: id))]),
                    JumpSegment(title: model.runTitle(item), options: runs.compactMap { run in
                        run.id.map { JumpOption(title: run.displayTitle, isCurrent: $0 == item.number, item: .run($0, in: id)) }
                    }),
                ]
            },
            inspectorSubject: { item, _ in
                guard let project = item.project, let run = item.number else { return nil }
                return .run(project: project, run: run)
            },
            isAvailable: { item, model in item.number.map { model.run(withID: $0) != nil } ?? false },
            content: { item in AnyView(RunEditor(item: item)) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.agent,
            title: { item, model in model.agentName(item) },
            systemImage: { _ in "person" },
            jumpBar: { item, model in
                guard let project = model.project(of: item), let id = project.id else { return [] }
                let sessions = model.agentSessions(in: project)
                return [
                    model.projectSegment(project) { .section(.agents, in: $0) },
                    JumpSegment(title: "Agents", options: [JumpOption(title: "All agents", item: .section(.agents, in: id))]),
                    JumpSegment(title: model.agentName(item), options: sessions.map { session in
                        JumpOption(title: model.displayName(of: session.agent, in: project), isCurrent: session.id == item.number, item: .agent(session.id, in: id))
                    }),
                    JumpSegment(title: "Session"),
                ]
            },
            inspectorSubject: { item, _ in
                guard let project = item.project, let agent = item.number else { return nil }
                return .agent(project: project, agent: agent)
            },
            isAvailable: { item, model in model.session(for: item) != nil },
            content: { item in AnyView(AgentEditor(item: item)) }
        ))
        register(EditorKindSpec(
            id: EditorKindID.file,
            title: { item, _ in (item.ref.map { ($0 as NSString).lastPathComponent }) ?? "File" },
            systemImage: { _ in "doc.text" },
            jumpBar: { item, model in
                guard let project = model.project(of: item), let path = item.ref else { return [] }
                return [model.projectSegment(project) { .section(.code, in: $0) }] + path.split(separator: "/").map { JumpSegment(title: String($0)) }
            },
            inspectorSubject: { item, _ in
                guard let project = item.project, let path = item.ref else { return nil }
                return .file(project: project, path: path)
            },
            content: { item in AnyView(FileEditor(item: item)) }
        ))
    }

    private func registerToolbar() {
        register(ToolbarItemSpec(id: "toggle-navigator", placement: .leading, order: 0) {
            AnyView(PaneToggle(pane: .navigator, systemImage: "sidebar.left", help: "Navigator (⌘0)"))
        })
        register(ToolbarItemSpec(id: "inbox", placement: .trailing, order: 0) {
            AnyView(InboxToolbarButton())
        })
        register(ToolbarItemSpec(id: "toggle-bottom", placement: .trailing, order: 10) {
            AnyView(PaneToggle(pane: .bottom, systemImage: "rectangle.bottomthird.inset.filled", help: "Bottom panel (⇧⌘Y)"))
        })
        register(ToolbarItemSpec(id: "toggle-inspector", placement: .trailing, order: 20) {
            AnyView(PaneToggle(pane: .inspector, systemImage: "sidebar.right", help: "Inspector (⌥⌘0)"))
        })
    }

    private func registerStatusItems() {
        register(StatusItemSpec(id: "branch", placement: .leading, order: 0) { AnyView(BranchStatusItem()) })
        register(StatusItemSpec(id: "spend", placement: .trailing, order: 100) { AnyView(SpendStatusItem()) })
    }

    private func registerViewCommands() {
        register(WorkbenchCommand(id: "view.palette", title: "Command Palette…", menu: "View", section: 0, order: 0, shortcut: KeyboardShortcut("k")) { context in
            if context.model.isPalettePresented { context.model.isPalettePresented = false } else { context.model.openPalette() }
        })
        register(WorkbenchCommand(id: "view.navigator", title: "Show Navigator", menu: "View", section: 1, order: 0, shortcut: KeyboardShortcut("0"),
                                  isEnabled: { $0.workbench != nil }, isChecked: { $0.workbench?.isShowing(.navigator) ?? false }) {
            $0.workbench?.toggle(.navigator)
        })
        register(WorkbenchCommand(id: "view.inspector", title: "Show Inspector", menu: "View", section: 1, order: 1, shortcut: KeyboardShortcut("0", modifiers: [.command, .option]),
                                  isEnabled: { $0.workbench != nil }, isChecked: { $0.workbench?.isShowing(.inspector) ?? false }) {
            $0.workbench?.toggle(.inspector)
        })
        register(WorkbenchCommand(id: "view.bottom", title: "Show Bottom Panel", menu: "View", section: 1, order: 2, shortcut: KeyboardShortcut("y", modifiers: [.command, .shift]),
                                  isEnabled: { $0.workbench != nil }, isChecked: { $0.workbench?.isShowing(.bottom) ?? false }) {
            $0.workbench?.toggle(.bottom)
        })
        register(WorkbenchCommand(id: "view.split", title: "Split Editor", menu: "View", section: 2, order: 0, shortcut: KeyboardShortcut("t", modifiers: [.command, .control]),
                                  isEnabled: { $0.workbench?.active != nil }, isChecked: { $0.workbench?.isSplit ?? false }) {
            $0.workbench?.toggleSplit()
        })
        register(WorkbenchCommand(id: "view.toolbar", title: "Show Toolbar", menu: "View", section: 2, order: 1, shortcut: KeyboardShortcut("t", modifiers: [.command, .option]),
                                  isEnabled: { $0.workbench != nil }, isChecked: { !($0.workbench?.isToolbarHidden ?? true) }) {
            $0.workbench?.isToolbarHidden.toggle()
        })
        register(WorkbenchCommand(id: "navigate.back", title: "Back", menu: "Navigate", section: 0, order: 0, shortcut: KeyboardShortcut(.leftArrow, modifiers: [.command, .control]),
                                  isEnabled: { $0.workbench?.canGoBack ?? false }) {
            $0.workbench?.goBack()
        })
        register(WorkbenchCommand(id: "navigate.forward", title: "Forward", menu: "Navigate", section: 0, order: 1, shortcut: KeyboardShortcut(.rightArrow, modifiers: [.command, .control]),
                                  isEnabled: { $0.workbench?.canGoForward ?? false }) {
            $0.workbench?.goForward()
        })
        register(WorkbenchCommand(id: "navigate.next-tab", title: "Show Next Tab", menu: "Navigate", section: 1, order: 0, shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]),
                                  isEnabled: { ($0.workbench?.tabs.count ?? 0) > 1 }) {
            $0.workbench?.selectNextTab(offset: 1)
        })
        register(WorkbenchCommand(id: "navigate.previous-tab", title: "Show Previous Tab", menu: "Navigate", section: 1, order: 1, shortcut: KeyboardShortcut("[", modifiers: [.command, .shift]),
                                  isEnabled: { ($0.workbench?.tabs.count ?? 0) > 1 }) {
            $0.workbench?.selectNextTab(offset: -1)
        })
        register(WorkbenchCommand(id: "navigate.close-tab", title: "Close Tab", menu: "Navigate", section: 1, order: 2, shortcut: KeyboardShortcut("w"),
                                  isEnabled: { $0.workbench?.active != nil }) { context in
            if let active = context.workbench?.active { context.workbench?.close(active) }
        })
    }

    func registerNavigatorCommands() {
        for (index, tab) in navigatorTabs.enumerated() {
            register(WorkbenchCommand(
                id: "navigator.\(tab.id)", title: tab.title, menu: "View.Navigator", section: 0, order: index,
                shortcut: index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil,
                isEnabled: { $0.workbench != nil },
                isChecked: { $0.workbench?.navigatorTab == tab.id }
            ) { context in
                context.workbench?.navigatorTab = tab.id
                context.workbench?.show(.navigator)
            })
        }
    }
}

extension AppModel {
    func projectSegment(_ project: Project, item: @escaping (Int64) -> EditorItem) -> JumpSegment {
        JumpSegment(title: project.name, options: openProjects.compactMap { other in
            other.id.map { JumpOption(title: other.name, isCurrent: other.id == project.id, item: item($0)) }
        })
    }

    func run(withID id: Int64) -> Run? {
        engine.runs[id] ?? (try? database.run(id: id)) ?? nil
    }

    func runTitle(_ item: EditorItem) -> String {
        item.number.flatMap(run(withID:))?.displayTitle ?? "Run"
    }

    func recentRuns(in project: Project) -> [Run] {
        guard let id = project.id else { return [] }
        return Array(((try? database.runs(projectId: id)) ?? []).reversed().prefix(12))
    }

    func session(for item: EditorItem) -> AgentSession? {
        guard let project = project(of: item), let agent = item.number else { return nil }
        return agentSessions(in: project).first { $0.id == agent }
    }

    func agentName(_ item: EditorItem) -> String {
        guard let project = project(of: item), let session = session(for: item) else { return "Agent" }
        return displayName(of: session.agent, in: project)
    }

    func chatTargetName(in project: Project) -> String? {
        guard let id = project.id else { return nil }
        switch chatTargets[id] {
        case .agent(let agentID):
            return agentSessions(in: project).first { $0.id == agentID }.map { displayName(of: $0.agent, in: project) }
        case .lead(let role):
            return leadRoles(in: project).first { $0.id == role }?.name
        case nil:
            return leadRoles(in: project).first?.name
        }
    }
}

extension Run {
    var displayTitle: String {
        title.isEmpty ? workflow : title
    }
}

private struct ProjectScreenHost: View {
    @Environment(AppModel.self) private var model
    let item: EditorItem

    var body: some View {
        if let project = model.project(of: item), let tab = item.tab {
            ProjectScreen(project: project, tab: tab)
        }
    }
}

private struct ProjectAccessoryHost: View {
    @Environment(AppModel.self) private var model
    let item: EditorItem

    var body: some View {
        if let project = model.project(of: item), let tab = item.tab {
            ProjectScreenAccessory(project: project, tab: tab)
        }
    }
}

private struct RunEditor: View {
    @Environment(AppModel.self) private var model
    let item: EditorItem

    var body: some View {
        if let project = model.project(of: item), let run = item.number {
            RunDetailView(runID: run, project: project)
                .padding(EdgeInsets(top: 14, leading: 22, bottom: 20, trailing: 20))
        }
    }
}

private struct AgentEditor: View {
    @Environment(AppModel.self) private var model
    let item: EditorItem

    var body: some View {
        if let project = model.project(of: item), let session = model.session(for: item) {
            AgentSessionView(session: session, project: project)
                .padding(EdgeInsets(top: 14, leading: 22, bottom: 20, trailing: 20))
        }
    }
}

private struct FileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let item: EditorItem

    var body: some View {
        if let project = model.project(of: item), let path = item.ref, let id = project.id {
            let browser = model.codeBrowser(for: project)
            CodeReader(browser: browser, project: project)
                .overlay {
                    if browser.isFinderPresented { CodeFinder(browser: browser) }
                }
                .task(id: path) { if browser.activePath != path { browser.open(path) } }
                .onChange(of: browser.activePath) { _, next in
                    if let next, next != path, state.active == item { state.open(.file(next, in: id)) }
                }
        }
    }
}

private struct PaneToggle: View {
    @Environment(WorkbenchState.self) private var state
    let pane: WorkbenchPane
    let systemImage: String
    let help: String

    var body: some View {
        Button { state.toggle(pane) } label: {
            Image(systemName: systemImage).font(.system(size: 14))
        }
        .buttonStyle(ToolbarChipStyle(width: 30, height: 28, cornerRadius: 7, fill: state.isShowing(pane) ? .white.opacity(0.12) : .clear,
                                      foreground: Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.85)))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(state.isShowing(pane) ? "Shown" : "Hidden")
    }
}

private struct InboxToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.inbox.items.count
        Button { model.selection = .inbox } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 13))
                if count > 0 {
                    Text("\(count)").font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: 0xFF9A5C))
                }
            }
        }
        .buttonStyle(ToolbarChipStyle(horizontalPadding: 10))
        .help("Inbox (\(count) waiting)")
        .accessibilityLabel("Inbox, \(count) waiting")
    }
}

private struct BranchStatusItem: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        if let active = state.active, active.kind == EditorKindID.agent, let session = model.session(for: active), let branch = session.agent.branch {
            StatusButton(help: "Branch and worktree of \(session.agent.name)", action: {
                state.navigatorTab = "source-control"
                state.show(.navigator)
            }) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branch).font(.system(size: 11.5, design: .monospaced))
                if let worktree = session.agent.worktreeURL {
                    Text("· .crew/\(worktree.lastPathComponent)").foregroundStyle(Theme.tertiaryText)
                }
            }
        } else if let project = model.currentProject {
            let branch = model.state(for: project).branch
            StatusButton(help: "Branch of \(project.name)", action: {
                state.navigatorTab = "source-control"
                state.show(.navigator)
            }) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branch ?? "no branch").font(.system(size: 11.5, design: .monospaced))
                Text("· \(project.name)").foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

private struct SpendStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let budget = model.globalWeeklyBudget
        StatusButton(help: "Spend this week", action: { model.selection = .usage }) {
            Text(budget.map { "\(model.weeklySpend.formatted(.currency(code: "USD").precision(.fractionLength(0)))) / \($0.formatted(.currency(code: "USD").precision(.fractionLength(0)))) this week" }
                 ?? "\(model.weeklySpend.formatted(.currency(code: "USD").precision(.fractionLength(2)))) this week")
                .font(.system(size: 11.5, design: .monospaced))
        }
    }
}
