import EnsembleCore
import EnsembleUI
import Network
import SwiftUI

extension WorkbenchRegistry {
    func registerToolbarItems() {
        register(ToolbarItemSpec(id: "scheme", placement: .leading, order: 10) { AnyView(SchemeSelector()) })
        register(ToolbarItemSpec(id: "start", placement: .leading, order: 20) { AnyView(StartStopButtons()) })
        register(ToolbarItemSpec(id: "activity", placement: .center, order: 0) { AnyView(ActivityViewer()) })

        register(StatusItemSpec(id: "agents", placement: .leading, order: 10) { AnyView(AgentsStatusItem()) })
        register(StatusItemSpec(id: "checks", placement: .leading, order: 20) { AnyView(ChecksStatusItem()) })
        register(StatusItemSpec(id: "problems", placement: .leading, order: 30) { AnyView(ProblemsStatusItem()) })
        register(StatusItemSpec(id: "claude", placement: .trailing, order: 0) { AnyView(ClaudeStatusItem()) })
        register(StatusItemSpec(id: "limits", placement: .trailing, order: 10) { AnyView(LimitsStatusItem()) })

        register(WorkbenchCommand(id: "run.start", title: "Start Task", menu: "Run", section: 0, order: 0, shortcut: KeyboardShortcut("r"),
                                  isEnabled: { $0.model.currentProject != nil }) { context in
            context.model.newTask()
        })
        register(WorkbenchCommand(id: "run.stop", title: "Stop Run", menu: "Run", section: 0, order: 1, shortcut: KeyboardShortcut("."),
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
                Section("Project") {
                    ForEach(model.openProjects) { other in
                        Toggle(other.name, isOn: Binding(get: { other.id == project.id }, set: { _ in
                            if let id = other.id { model.selection = .project(id) }
                        }))
                    }
                }
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
                HStack(spacing: 6) {
                    Text(String(project.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(LinearGradient(colors: [Color(hex: 0x4A90FF), Color(hex: 0x1F5FD1)], startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 6, style: .continuous))
                    Text(project.name).fontWeight(.semibold)
                    Text("▸").foregroundStyle(Theme.secondaryText)
                    Text(workflow.map { "\($0.name) v\($0.version)" } ?? "No workflow")
                    Text("▸").foregroundStyle(Theme.secondaryText)
                    Text(base).font(.system(size: 11.5, design: .monospaced))
                }
                .font(.system(size: 12.5))
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Project, workflow for new tasks, and base branch")
            .accessibilityLabel("Scheme: \(project.name), \(workflow?.name ?? "no workflow"), base \(base). Change")
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
        HStack(spacing: 6) {
            Button { model.newTask() } label: { Image(systemName: "play.fill") }
                .help("Start a task with this workflow (⌘R)")
                .accessibilityLabel("Start a task")
                .disabled(model.currentProject == nil)
            Button {
                guard let run else { return }
                Task { await model.performRunAction("Couldn’t stop the run") { try await model.engine.cancel(run) } }
            } label: { Image(systemName: "stop.fill") }
                .help(run.map { "Stop \($0.displayTitle) (⌘.)" } ?? "No run to stop")
                .accessibilityLabel("Stop the current run")
                .disabled(run == nil)
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
            HStack(spacing: 10) {
                Circle()
                    .fill(lead.map { model.statusColor(of: $0) } ?? Theme.neutral)
                    .frame(width: 8, height: 8)
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
            .frame(minWidth: 320, idealWidth: 520, maxWidth: 560, minHeight: 28)
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
