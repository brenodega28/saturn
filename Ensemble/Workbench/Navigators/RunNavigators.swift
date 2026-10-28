import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunsNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var expanded: Set<Int64> = []

    var body: some View {
        let _ = model.engine.runs
        let _ = model.engine.holds
        let _ = model.inbox.items
        let projects = model.navigatorProjects(state.navigatorScope)
        let runs = model.runs(in: projects).reversed()
        let waiting = runs.filter { model.runNeedsYou($0) }
        let running = runs.filter { ProjectSignals.activeStatuses.contains($0.status) && !model.runNeedsYou($0) }
        let finished = runs.filter { $0.status == .succeeded }.prefix(15)
        let failed = runs.filter { $0.status == .failed || $0.status == .cancelled }.prefix(15)
        if runs.isEmpty {
            NavigatorEmpty(title: "No runs yet", message: "Describe a task in Chat and the lead starts a run.")
        } else {
            NavigatorList {
                group("Running", Array(running), showsProject: projects.count > 1)
                group("Waiting on you", Array(waiting), showsProject: projects.count > 1)
                group("Finished", Array(finished), showsProject: projects.count > 1)
                group("Failed", Array(failed), showsProject: projects.count > 1)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ runs: [Run], showsProject: Bool) -> some View {
        if !runs.isEmpty {
            NavigatorSection(title: title, count: runs.count) {
                ForEach(runs) { run in
                    RunNavigatorRow(run: run, showsProject: showsProject, isExpanded: Binding(
                        get: { run.id.map(expanded.contains) ?? false },
                        set: { isOn in
                            guard let id = run.id else { return }
                            if isOn { expanded.insert(id) } else { expanded.remove(id) }
                        }
                    ))
                }
            }
        }
    }
}

private struct RunNavigatorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let run: Run
    let showsProject: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        let item = run.id.map { EditorItem.run($0, in: run.projectId) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityLabel(isExpanded ? "Hide steps" : "Show steps")
                NavigatorRow(title: run.displayTitle, detail: detail, isSelected: item == state.active) {
                    if let item { state.open(item) }
                } leading: {
                    StateGlyph(systemImage: glyph, color: model.statusColor(of: run))
                }
            }
            if isExpanded, let timeline = model.timeline(for: run) {
                ForEach(timeline.stages) { stage in
                    HStack(spacing: 8) {
                        Circle().fill(stage.state.color).frame(width: 7, height: 7)
                        Text(stage.title).font(.system(size: 12))
                        Spacer(minLength: 0)
                        Text(stage.state.label).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                    .padding(EdgeInsets(top: 3, leading: 44, bottom: 3, trailing: 8))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .contextMenu { if let id = run.id { ContextCommands(groups: ContextCommands.run, target: .run(project: run.projectId, run: id)) } }
    }

    private var detail: String {
        var parts: [String] = []
        if showsProject, let project = model.project(withID: run.projectId) { parts.append(project.name) }
        parts.append(model.runNeedsYou(run) ? model.statusLabel(of: run) : (model.currentStepTitle(of: run) ?? model.statusLabel(of: run)))
        parts.append(run.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
        return parts.joined(separator: " · ")
    }

    private var glyph: String {
        if model.runNeedsYou(run) { return "exclamationmark" }
        switch run.status {
        case .succeeded: return "checkmark"
        case .failed, .cancelled: return "xmark"
        case .paused: return "pause.fill"
        default: return "ellipsis"
        }
    }
}


struct AgentsNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let projects = model.navigatorProjects(state.navigatorScope)
        let entries = projects.flatMap { project in model.agentSessions(in: project).map { (project, $0) } }
        if entries.isEmpty {
            NavigatorEmpty(title: "No agents yet", message: "Workflows start agents when a run needs them, or spawn a builder or checker with ⇧⌘A.")
        } else {
            let runIDs = Array(Set(entries.compactMap { $0.1.agent.runId }))
            let runs = Dictionary(uniqueKeysWithValues: ((try? model.database.runs(withIDs: runIDs)) ?? []).compactMap { run in run.id.map { ($0, run) } })
            let groups = Dictionary(grouping: entries) { $0.1.agent.runId }
            let order = groups.keys.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (nil, _): false
                case (_, nil): true
                case let (left?, right?): left > right
                }
            }
            NavigatorList {
                ForEach(order, id: \.self) { runID in
                    let title = runID.flatMap { runs[$0]?.displayTitle } ?? "Not in a run"
                    NavigatorSection(title: title) {
                        ForEach(groups[runID] ?? [], id: \.1.id) { project, session in
                            AgentNavigatorRow(project: project, session: session, showsProject: projects.count > 1)
                        }
                    }
                }
            }
        }
    }
}

private struct AgentNavigatorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let project: Project
    let session: AgentSession
    let showsProject: Bool

    var body: some View {
        let status = model.displayStatus(of: session.agent)
        let item = project.id.map { EditorItem.agent(session.id, in: $0) }
        NavigatorRow(
            title: model.displayName(of: session.agent, in: project),
            detail: detail,
            badge: session.isQueued ? "Queued" : status.label,
            badgeColor: status.color,
            isSelected: item == state.active
        ) {
            if let item { state.open(item) }
        } leading: {
            AgentAvatar(size: 26, appearance: RoleAppearance(role: model.role(for: session.agent, in: project)))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(status.color).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.sidebarBackground, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
        }
        .contextMenu { if let id = project.id { ContextCommands(groups: ContextCommands.agent, target: .agent(project: id, agent: session.id)) } }
    }

    private var detail: String {
        var parts: [String] = []
        if showsProject { parts.append(project.name) }
        if let branch = session.agent.branch { parts.append(branch) }
        parts.append(session.agent.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
        return parts.joined(separator: " · ")
    }
}


struct PinsNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let _ = model.engine.runs
        let projects = model.navigatorProjects(state.navigatorScope)
        let runs = model.runs(in: projects).filter { $0.status != .cancelled }.reversed()
        let groups = runs.compactMap { run -> (Run, [Pin])? in
            guard let id = run.id else { return nil }
            let pins = ((try? model.database.pins(runId: id)) ?? []).filter { $0.status == .open }
            return pins.isEmpty ? nil : (run, pins)
        }
        if groups.isEmpty {
            NavigatorEmpty(title: "No open pins", message: "Pins left by agents and the AI reviewer show up here until you resolve them.")
        } else {
            NavigatorList {
                ForEach(groups, id: \.0.id) { run, pins in
                    NavigatorSection(title: run.displayTitle, count: pins.count) {
                        ForEach(pins) { pin in
                            PinNavigatorRow(run: run, pin: pin)
                        }
                    }
                }
            }
        }
    }
}

private struct PinNavigatorRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let run: Run
    let pin: Pin

    var body: some View {
        NavigatorRow(title: pin.title, detail: "\(origin) · \(location)") {
            open()
        } leading: {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 2)
        }
        .contextMenu {
            Button("Open in Changes", action: open)
            Button("Open File") { state.open(.file(pin.file, in: run.projectId)) }
            Divider()
            if let id = pin.id { ContextCommands(groups: ContextCommands.pin, target: .pin(project: run.projectId, pin: id)) }
        }
    }

    private func open() {
        guard let id = run.id else { return }
        model.focusedPinIDs[run.projectId] = pin.id
        model.changesRunSelections[run.projectId] = id
        state.open(.section(.changes, in: run.projectId))
    }

    private var origin: String {
        if pin.byUser { return "Your comment" }
        if pin.category == "test-change" || pin.tags.contains("test") { return "Test change" }
        if let confidence = pin.confidence { return "AI review \(confidence.formatted(.number.precision(.fractionLength(2))))" }
        return "Agent pin"
    }

    private var location: String {
        let file = (pin.file as NSString).lastPathComponent
        return pin.startLine == pin.endLine ? "\(file):\(pin.startLine)" : "\(file):\(pin.startLine)–\(pin.endLine)"
    }

    private var color: Color {
        if pin.byUser { return Theme.memory }
        if pin.confidence != nil { return Theme.info }
        return Theme.warning
    }
}

struct ChecksNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let _ = model.engine.runs
        let holds = model.engine.holds
        let projects = model.navigatorProjects(state.navigatorScope)
        let runs = model.runs(in: projects)
        let board = ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs.filter { ProjectSignals.activeStatuses.contains($0.status) }), holds: holds)
        if board.isEmpty {
            NavigatorEmpty(title: "No checks running", message: "Each builder’s checks show up here while a run is active.")
        } else {
            NavigatorList {
                VStack(spacing: 8) {
                    ForEach(board) { entry in
                        CheckBoardCard(entry: entry, run: runs.first { $0.id == entry.runId })
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct CheckBoardCard: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let entry: CheckBoardEntry
    let run: Run?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.branch ?? entry.agentName ?? entry.runTitle)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.state == .exhausted || entry.state == .failed, let run {
                    Button("Rerun") {
                        model.performRunAction("Couldn’t run the checks again") { try model.engine.resolveFailure(run, retry: true) }
                    }
                    .buttonStyle(PillButtonStyle(height: 22))
                }
            }
            HStack(spacing: 4) {
                ForEach(entry.results) { result in
                    CheckChip(title: result.kind.initial, passed: result.passed, isRunning: false)
                }
                if entry.state == .running { CheckChip(title: "Running", passed: false, isRunning: true) }
                Spacer(minLength: 4)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            if let message = entry.message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.danger).lineLimit(3)
            }
        }
        .padding(10)
        .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture {
            state.open(.run(entry.runId, in: run?.projectId ?? -1))
        }
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        switch entry.state {
        case .running: "round \(entry.round) · running"
        case .passed: "round \(entry.round) · green"
        case .failed: "round \(entry.round) · failing"
        case .exhausted: "out of rounds"
        }
    }
}

private struct CheckChip: View {
    let title: String
    let passed: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isRunning ? "ellipsis" : passed ? "checkmark" : "xmark").font(.system(size: 8, weight: .bold))
            Text(title)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color.opacity(0.18), in: .capsule)
        .accessibilityLabel("\(title) \(isRunning ? "running" : passed ? "passed" : "failed")")
    }

    private var color: Color {
        isRunning ? Theme.info : passed ? Theme.successText : Theme.danger
    }
}

extension CheckKind {
    var initial: String {
        String(rawValue.prefix(1)).uppercased()
    }
}

struct ProblemsNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let problems = model.problems(scope: state.navigatorScope)
        if problems.isEmpty {
            NavigatorEmpty(title: "No problems", message: "Failing checks, gate findings, config errors and missing skills show up here.")
        } else {
            NavigatorList {
                ForEach(ProjectProblem.Category.allCases, id: \.self) { category in
                    let matching = problems.filter { $0.problem.category == category }
                    if !matching.isEmpty {
                        NavigatorSection(title: category.title, count: matching.count) {
                            ForEach(matching, id: \.problem.id) { project, problem in
                                ProblemRow(project: project, problem: problem, showsProject: model.openProjects.count > 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ProblemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let project: Project
    let problem: ProjectProblem
    let showsProject: Bool

    var body: some View {
        NavigatorRow(title: problem.title, detail: showsProject ? "\(problem.location) · \(project.name)" : problem.location) {
            model.open(problem, in: project, workbench: state)
        } leading: {
            Image(systemName: problem.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(problem.severity == .error ? Theme.danger : Theme.warning)
                .padding(.top, 1)
        }
    }
}

extension AppModel {
    func problems(scope: NavigatorScope) -> [(project: Project, problem: ProjectProblem)] {
        _ = engine.runs
        let holds = engine.holds
        return navigatorProjects(scope).flatMap { project -> [(project: Project, problem: ProjectProblem)] in
            let runs = runs(in: [project])
            let config = config(for: project)
            let installed = SkillLibrary.installedSkills(in: project.url).union((skillPlugins[project.id ?? -1] ?? []).flatMap(\.skills))
            return ProjectSignals.problems(
                runs: runs, steps: steps(of: runs.filter { ProjectSignals.activeStatuses.contains($0.status) }), holds: holds,
                configIssues: ConfigValidator.validate(config), agents: agentSessions(in: project).map(\.agent), installedSkills: installed
            ).map { (project, $0) }
        }
    }

    func open(_ problem: ProjectProblem, in project: Project, workbench: WorkbenchState) {
        guard let id = project.id else { return }
        switch problem.category {
        case .failingChecks:
            if let run = problem.runId { workbench.open(.run(run, in: id)) }
        case .gateFindings:
            if let file = problem.file {
                codeBrowser(for: project).open(file, line: problem.line)
                workbench.open(.file(file, in: id))
            } else if let run = problem.runId {
                workbench.open(.run(run, in: id))
            }
        case .configErrors:
            openSettings(.checks, in: project)
        case .missingSkills:
            openSettings(.skills, in: project)
        }
    }
}
