import AppKit
import EnsembleCore
import EnsembleUI
import Network
import SwiftUI

extension WorkbenchRegistry {
    func registerToolbarItems() {
        register(ToolbarItemSpec(id: "project", placement: .leading, order: 5) { AnyView(ProjectSwitcher()) })
        register(ToolbarItemSpec(id: "scheme", placement: .leading, order: 10) { AnyView(SchemeSelector()) })
        register(ToolbarItemSpec(id: "start", placement: .leading, order: 20) { AnyView(StartStopButtons()) })
        register(ToolbarItemSpec(id: "activity", placement: .center, order: 0) { AnyView(ActivityViewer()) })

        register(StatusItemSpec(id: "agents", placement: .leading, order: 10) { AnyView(AgentsStatusItem()) })
        register(StatusItemSpec(id: "checks", placement: .leading, order: 20) { AnyView(ChecksStatusItem()) })
        register(StatusItemSpec(id: "problems", placement: .leading, order: 30) { AnyView(ProblemsStatusItem()) })
        register(StatusItemSpec(id: "claude", placement: .trailing, order: 0) { AnyView(ClaudeStatusItem()) })
        register(StatusItemSpec(id: "planUsage", placement: .trailing, order: 5) { AnyView(PlanUsageStatusItem()) })
        register(StatusItemSpec(id: "limits", placement: .trailing, order: 10) { AnyView(LimitsStatusItem()) })

        register(WorkbenchCommand(id: "run.start", title: "Start", menu: "Run", section: 0, order: 0, shortcut: KeyboardShortcut("r"),
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            context.model.newTask()
        })
        register(WorkbenchCommand(id: "run.stop", title: "Stop", menu: "Run", section: 0, order: 1, shortcut: KeyboardShortcut("."),
                                  isEnabled: { $0.model.runToStop(in: $0.workbench) != nil }) { context in
            guard let run = context.model.runToStop(in: context.workbench) else { return }
            Task { await context.model.performRunAction("Couldn’t stop the run") { try await context.model.engine.cancel(run) } }
        })
    }
}

extension AppModel {
    func runToStop(in workbench: WorkbenchState?) -> Run? {
        if let item = workbench?.active, item.kind == EditorKindID.run, let run = item.number.flatMap(run(withID:)),
           ProjectSignals.activeStatuses.contains(run.status) {
            return run
        }
        guard let project = currentProject?.id else { return nil }
        return engine.runs.values.filter { $0.projectId == project }.max { $0.startedAt < $1.startedAt }
    }

    var activeRunsInScope: [Run] {
        engine.runs.values.filter { run in openProjects.contains { $0.id == run.projectId } }.sorted { $0.startedAt > $1.startedAt }
    }

    func statusSummary(of project: Project) -> ProjectOutline.Summary {
        let waiting = inbox.items.filter { $0.projectId == project.id }
        let activeRuns = engine.runs.values.filter { $0.projectId == project.id && ProjectSignals.activeStatuses.contains($0.status) }.count
        return ProjectOutline.statusSummary(
            activeRuns: activeRuns,
            needsYou: waiting.filter { Self.needsYouKinds.contains($0.kind) }.count,
            failing: waiting.filter { $0.kind == .failure }.count
        )
    }
}

private struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPopover = false

    var body: some View {
        let project = model.currentProject
        Button { isShowingPopover.toggle() } label: {
            HStack(spacing: 7) {
                if let project {
                    ProjectTile(project: project)
                    Text(project.name).fontWeight(.semibold).lineLimit(1)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Image(systemName: "folder")
                    Text("No project").fontWeight(.semibold)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch project")
        .accessibilityLabel(project.map { "Project: \($0.name), local. Switch project" } ?? "No project open. Open a project")
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            ProjectSwitcherMenu { isShowingPopover = false }
        }
    }
}

private struct ProjectSwitcherMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
                .accessibilityAddTraits(.isHeader)
            if model.openProjects.isEmpty {
                Text("No projects are open.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(model.openProjects) { project in
                ProjectSwitcherRow(project: project, isCurrent: project.id == model.currentProject?.id, summary: model.statusSummary(of: project)) {
                    if let id = project.id { model.selection = .project(id) }
                    dismiss()
                } close: {
                    dismiss()
                    model.close(project)
                }
            }
            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            SwitcherActionRow(title: "Open…", shortcut: "⌘O") { perform { model.isOpenPanelPresented = true } }
            SwitcherActionRow(title: "Clone…") { perform { model.isClonePresented = true } }
            SwitcherActionRow(title: "New Project…") { perform { model.newProject() } }
            SwitcherActionRow(title: "All projects in Organizer", shortcut: "⇧⌘1") { perform { openWindow(id: WindowID.organizer) } }
        }
        .padding(6)
        .frame(width: 340)
    }

    private func perform(_ action: () -> Void) {
        dismiss()
        action()
    }
}

private struct ProjectSwitcherRow: View {
    let project: Project
    let isCurrent: Bool
    let summary: ProjectOutline.Summary
    let choose: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        let location = "Local · \(ProjectOutline.abbreviatedPath(project.path))"
        Button(action: choose) {
            HStack(spacing: 10) {
                ProjectTile(project: project, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer").font(.system(size: 9.5))
                        Text(location).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 6)
                Text(summary.text)
                    .font(.system(size: 11))
                    .foregroundStyle(summary.tone == .quiet ? Theme.secondaryText : summary.tone.color)
                    .lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.link)
                    .opacity(isCurrent ? 1 : 0)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isCurrent ? Theme.accent.opacity(0.2) : isHovered ? Theme.fillRaised : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("Close Project", action: close)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), \(location), \(summary.text)")
        .accessibilityHint("Switches to this project. More actions in the context menu")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SwitcherActionRow: View {
    let title: String
    var shortcut = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(shortcut).foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isHovered ? Theme.fillRaised : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SchemeSelector: View {
    @Environment(AppModel.self) private var model
    @State private var branches: [String] = []

    var body: some View {
        if let project = model.currentProject {
            let config = model.config(for: project)
            let preferences = config.preferences
            let workflow = config.workflow(preferences.defaultWorkflow ?? "") ?? config.workflows.first
            let base = preferences.baseBranch ?? model.state(for: project).branch ?? "main"
            Menu {
                Section("Workflow for new tasks") {
                    ForEach(config.workflows) { candidate in
                        Toggle("\(candidate.name) v\(candidate.version)", isOn: Binding(get: { candidate.id == workflow?.id }, set: { _ in
                            update(project) { $0.defaultWorkflow = candidate.id }
                        }))
                    }
                }
                Section("Base branch") {
                    ForEach(branches.isEmpty ? [base] : branches, id: \.self) { branch in
                        Toggle(branch, isOn: Binding(get: { branch == base }, set: { _ in
                            update(project) { $0.baseBranch = branch }
                        }))
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: ProjectTab.workflows.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text(workflow.map { "\($0.name) v\($0.version)" } ?? "No workflow")
                    Text("▸").foregroundStyle(Theme.secondaryText)
                    Text(base).font(.system(size: 11.5, design: .monospaced))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .padding(.leading, 5)
                .padding(.trailing, 10)
                .frame(height: 30)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .contentShape(.rect(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Workflow for new tasks, and base branch")
            .accessibilityLabel("Scheme: \(workflow?.name ?? "no workflow"), base \(base). Change")
            .task(id: project.id) { await loadBranches(project) }
        }
    }

    private func update(_ project: Project, _ change: (inout ProjectPreferences) -> Void) {
        var preferences = model.config(for: project).preferences
        change(&preferences)
        do {
            try ProjectConfigLoader.write(preferences, repository: project.url)
        } catch {
            model.alert = AppAlert(title: "Couldn’t save the project preferences", message: error.localizedDescription)
        }
        model.reloadConfig(for: project)
    }

    private func loadBranches(_ project: Project) async {
        guard let git = model.git,
              let output = try? await git.run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: project.url) else { return }
        let prefix = model.config(for: project).preferences.branchPrefix + "/"
        branches = output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(prefix) }
    }
}

private struct StartStopButtons: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let run = model.runToStop(in: state)
        HStack(spacing: 10) {
            Button { model.newTask() } label: { Image(systemName: "play.fill").font(.system(size: 13)) }
                .help("Start a task with this workflow (⌘R)")
                .accessibilityLabel("Start a task")
                .disabled(model.currentProject == nil)
            Button {
                guard let run else { return }
                Task { await model.performRunAction("Couldn’t stop the run") { try await model.engine.cancel(run) } }
            } label: { Image(systemName: "stop.fill").font(.system(size: 11)) }
                .help(run.map { "Stop \($0.displayTitle) (⌘.)" } ?? "No run to stop")
                .accessibilityLabel("Stop the current run")
                .disabled(run == nil)
        }
        .buttonStyle(ToolbarChipStyle(width: 34, fill: .white.opacity(0.08)))
    }
}

struct ToolbarChipStyle: ButtonStyle {
    var width: CGFloat?
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 0
    var cornerRadius: CGFloat = 8
    var fill: Color = .white.opacity(0.06)
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        ToolbarChip(configuration: configuration, style: self)
    }

    private struct ToolbarChip: View {
        let configuration: Configuration
        let style: ToolbarChipStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundStyle(style.foreground)
                .padding(.horizontal, style.horizontalPadding)
                .frame(width: style.width, height: style.height)
                .background(style.fill, in: .rect(cornerRadius: style.cornerRadius, style: .continuous))
                .overlay {
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).fill(Color.white.opacity(0.08))
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(.rect(cornerRadius: style.cornerRadius, style: .continuous))
        }
    }
}

private struct ActivityViewer: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPopover = false

    var body: some View {
        let runs = model.activeRunsInScope
        let agents = model.openProjects.flatMap { model.agentSessions(in: $0) }.filter { $0.agent.status == .working || model.agentNeedsYou($0.agent) }
        let cost = runs.reduce(0) { $0 + $1.costUSD }
        let lead = runs.first
        Button { isShowingPopover.toggle() } label: {
            let dotColor = lead.map { model.statusColor(of: $0) } ?? Theme.neutral
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(dotColor.opacity(0.25)).frame(width: 14, height: 14))
                if let lead {
                    Text(lead.displayTitle).fontWeight(.semibold).lineLimit(1)
                    Text(model.currentStepTitle(of: lead) ?? model.statusLabel(of: lead)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    if let timeline = model.timeline(for: lead) {
                        StageBar(stages: timeline.stages).frame(width: 88)
                    }
                } else {
                    Text("No runs going").foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 8)
                Text("\(runs.count) run\(runs.count == 1 ? "" : "s") · \(agents.count) agent\(agents.count == 1 ? "" : "s") · \(cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .frame(minWidth: 320, idealWidth: 520, maxWidth: 560, minHeight: 32, maxHeight: 32)
            .background(Color.black.opacity(0.28), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lead.map { "Activity: \($0.displayTitle) in \(model.currentStepTitle(of: $0) ?? model.statusLabel(of: $0)). \(runs.count) runs, \(agents.count) agents. Show all background work" } ?? "Activity: no runs going. Show background work")
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            ActivityPopover(runs: runs) { isShowingPopover = false }
        }
    }
}

struct StageBar: View {
    let stages: [RunTimeline.Stage]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(stages) { stage in
                Capsule().fill(stage.state.color).frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ActivityPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let runs: [Run]
    let dismiss: () -> Void

    var body: some View {
        let background = model.backgroundActivity
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            if runs.isEmpty {
                Text("No runs going.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(runs) { run in
                Button {
                    if let id = run.id { state.open(.run(id, in: run.projectId)) }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(run.displayTitle).fontWeight(.semibold)
                            Text(model.currentStepTitle(of: run) ?? model.statusLabel(of: run)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(run.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))).font(.system(size: 12, design: .monospaced))
                        }
                        .font(.system(size: 12.5))
                        if let timeline = model.timeline(for: run) {
                            StageBar(stages: timeline.stages)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Text("Background").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
            if background.isEmpty {
                Text("Nothing running in the background.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(background) { entry in
                ActivityEntryRow(entry: entry).padding(.horizontal, -12)
            }
        }
        .padding(12)
        .frame(width: 480)
    }
}

private struct AgentsStatusItem: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let sessions = model.openProjects.flatMap { model.agentSessions(in: $0) }
        let working = sessions.filter { $0.agent.status == .working }.count
        let needsYou = sessions.filter { model.agentNeedsYou($0.agent) }.count
        if working > 0 || needsYou > 0 {
            StatusButton(help: "Show agents") {
                state.navigatorTab = "agents"
                state.show(.navigator)
            } label: {
                Circle().fill(needsYou > 0 ? Theme.warning : Theme.success).frame(width: 7, height: 7)
                Text("\(working) agent\(working == 1 ? "" : "s") working" + (needsYou > 0 ? " · \(needsYou) need\(needsYou == 1 ? "s" : "") you" : ""))
            }
        }
    }
}

private struct ChecksStatusItem: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let runs = model.activeRunsInScope
        let board = ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs), holds: model.engine.holds)
        if let entry = board.first(where: { $0.state == .exhausted }) ?? board.first(where: { $0.state == .running }) ?? board.first(where: { $0.state == .failed }) ?? board.first {
            StatusButton(help: "Show check output") {
                state.bottomTab = "checks"
                state.show(.bottom)
            } label: {
                Text("Checks · round \(entry.round) · \(entry.state.statusWord)")
                    .foregroundStyle(entry.state == .passed ? Theme.successText : entry.state == .running ? Theme.link : Theme.danger)
            }
        }
    }
}

extension CheckBoardEntry.State {
    var statusWord: String {
        switch self {
        case .running: "running"
        case .passed: "green"
        case .failed: "failing"
        case .exhausted: "out of rounds"
        }
    }
}

private struct ProblemsStatusItem: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let problems = model.problems(scope: .all).map(\.problem)
        let errors = problems.filter { $0.severity == .error }.count
        let warnings = problems.count - errors
        if !problems.isEmpty {
            StatusButton(help: "Show problems") {
                state.navigatorTab = "problems"
                state.show(.navigator)
            } label: {
                if errors > 0 { Text("✕ \(errors)").foregroundStyle(Theme.danger) }
                if warnings > 0 { Text("! \(warnings)").foregroundStyle(Theme.warning) }
            }
            .accessibilityLabel("\(errors) errors, \(warnings) warnings")
        }
    }
}

private struct ClaudeStatusItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let claude = model.environment?.claude {
            StatusButton(help: claude.isOK ? "Claude Code CLI" : "Claude Code CLI isn’t working") {
                openSettings()
            } label: {
                Circle().fill(claude.isOK ? Theme.success : Theme.danger).frame(width: 7, height: 7)
                switch claude {
                case .found(_, let version):
                    Text("claude \(version)").font(.system(size: 11.5, design: .monospaced))
                    Text("healthy")
                case .missing:
                    Text("claude missing")
                case .broken:
                    Text("claude broken")
                }
            }
        }
    }
}

private struct PlanUsageStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let poller = model.planUsage
        if PlanUsageDisplay.isVisible(mode: model.providerMode, usage: poller.usage, needsSignIn: poller.needsSignIn) {
            if let usage = poller.usage, !poller.needsSignIn {
                let segments = PlanUsageDisplay.segments(usage)
                StatusButton(help: PlanUsageDisplay.help(usage), action: { model.selection = .usage }) {
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 { Text(" · ") }
                            Text("\(segment.title) ")
                            Text("\(segment.percent)%").foregroundStyle(segment.severity.color)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
                .accessibilityLabel("Claude plan usage: \(PlanUsageDisplay.label(usage))")
            } else {
                StatusButton(help: "Sign in to Claude Code again to see plan usage", action: { model.selection = .usage }) {
                    Text("Claude sign-in expired")
                }
            }
        }
    }
}

extension PlanUsageSeverity {
    var color: Color {
        switch self {
        case .normal: Theme.secondaryText
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }
}

private struct LimitsStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.openProjects.flatMap { model.agentSessions(in: $0) }
        let limited = sessions.compactMap { session -> Date? in
            guard let retry = session.apiRetry, retry.status == 429 || retry.error?.contains("rate_limit") == true else { return nil }
            return session.retryingAt ?? .now.addingTimeInterval(Double(retry.delayMS) / 1000)
        }
        HStack(spacing: 2) {
            if model.isOffline {
                StatusButton(help: "This Mac is offline; agents can’t reach Claude") {} label: {
                    Image(systemName: "wifi.slash").foregroundStyle(Theme.warning)
                    Text("Offline").foregroundStyle(Theme.warning)
                }
            }
            if let until = limited.max() {
                StatusButton(help: "Claude’s rate limit was hit; agents retry automatically") {} label: {
                    Text("Rate limited · retrying \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(Theme.warning)
                }
            }
        }
    }
}

@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()

    init(update: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in update(offline) }
        }
        monitor.start(queue: DispatchQueue(label: "app.ensemble.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
