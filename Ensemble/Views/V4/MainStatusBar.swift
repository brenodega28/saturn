import EnsembleCore
import EnsembleUI
import SwiftUI

struct MainStatusBar: View {
    var body: some View {
        HStack(spacing: 2) {
            AgentsStatusItem()
            ChecksStatusItem()
            ProblemsStatusItem()
            Spacer(minLength: 8)
            ClaudeStatusItem()
            PlanUsageStatusItem()
            LimitsStatusItem()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(V4.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(V4.logFill)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }
}

private struct StatusButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(isHovered ? Color.white.opacity(0.08) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct StatusText<Label: View>: View {
    let help: String
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 6) { label }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .help(help)
            .accessibilityElement(children: .combine)
    }
}

private struct AgentsStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sessions = model.openProjects.flatMap { model.agentSessions(in: $0) }
        let working = sessions.filter { $0.agent.status == .working }.count
        let needsYou = sessions.filter { model.agentNeedsYou($0.agent) }.count
        if working > 0 || needsYou > 0 {
            StatusButton(help: "Show agents") {
                model.open(.agents)
            } label: {
                Circle().fill(needsYou > 0 ? V4.orange : V4.green).frame(width: 7, height: 7)
                Text("\(working) agent\(working == 1 ? "" : "s") working" + (needsYou > 0 ? " · \(needsYou) need\(needsYou == 1 ? "s" : "") you" : ""))
            }
        }
    }
}

private struct ChecksStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runs = model.activeRunsInScope
        let board = ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs), holds: model.engine.holds)
        if let entry = board.first(where: { $0.state == .exhausted }) ?? board.first(where: { $0.state == .running }) ?? board.first(where: { $0.state == .failed }) ?? board.first {
            StatusButton(help: "Show check output") {
                guard let run = runs.first(where: { $0.id == entry.runId }) else { return }
                model.mainWindow.spec = nil
                model.openRunDetail(run)
            } label: {
                Text("Checks · round \(entry.round) · \(entry.state.statusWord)")
                    .foregroundStyle(entry.state.color)
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

    fileprivate var color: Color {
        switch self {
        case .passed: V4.greenText
        case .running: V4.link
        case .failed, .exhausted: V4.denied
        }
    }
}

private struct ProblemsStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.problems()
        let errors = entries.filter { $0.problem.severity == .error }.count
        let warnings = entries.count - errors
        if !entries.isEmpty {
            StatusButton(help: "Show problems") {
                let ranked = entries.filter { $0.problem.severity == .error } + entries.filter { $0.problem.severity != .error }
                if let target = ranked.first(where: { $0.problem.runId != nil }) ?? ranked.first {
                    model.open(target.problem, in: target.project)
                }
            } label: {
                if errors > 0 { Text("✕ \(errors)").foregroundStyle(V4.denied) }
                if warnings > 0 { Text("! \(warnings)").foregroundStyle(V4.orangeText) }
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
                Circle().fill(claude.isOK ? V4.green : V4.denied).frame(width: 7, height: 7)
                switch claude {
                case .found(_, let version):
                    Text("claude \(version)").font(V4.monospaced(11.5))
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
                StatusButton(help: PlanUsageDisplay.help(usage), action: { model.open(.usage) }) {
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 { Text(" · ") }
                            Text("\(segment.title) ")
                            Text("\(segment.percent)%").foregroundStyle(segment.severity.color)
                        }
                    }
                    .font(V4.monospaced(11.5))
                }
                .accessibilityLabel("Claude plan usage: \(PlanUsageDisplay.label(usage))")
            } else {
                StatusButton(help: "Sign in to Claude Code again to see plan usage", action: { model.open(.usage) }) {
                    Text("Claude sign-in expired")
                }
            }
        }
    }
}

extension PlanUsageSeverity {
    var color: Color {
        switch self {
        case .normal: V4.secondary
        case .warning: V4.orangeText
        case .danger: V4.denied
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
                StatusText(help: "This Mac is offline; agents can’t reach Claude") {
                    Image(systemName: "wifi.slash")
                    Text("Offline")
                }
                .foregroundStyle(V4.orangeText)
            }
            if let until = limited.max() {
                StatusText(help: "Claude’s rate limit was hit; agents retry automatically") {
                    Text("Rate limited · retrying \(until.formatted(date: .omitted, time: .shortened))")
                }
                .foregroundStyle(V4.orangeText)
            }
        }
    }
}

extension AppModel {
    var activeRunsInScope: [Run] {
        engine.runs.values.filter { run in openProjects.contains { $0.id == run.projectId } }.sorted { $0.startedAt > $1.startedAt }
    }

    func steps(of runs: [Run]) -> [Int64: [RunStep]] {
        Dictionary(uniqueKeysWithValues: runs.compactMap { run in
            run.id.map { ($0, (try? database.runSteps(runId: $0)) ?? []) }
        })
    }

    func problems() -> [(project: Project, problem: ProjectProblem)] {
        _ = engine.runs
        let holds = engine.holds
        return openProjects.flatMap { project -> [(project: Project, problem: ProjectProblem)] in
            let runs = runs(in: [project])
            let config = config(for: project)
            let installed = SkillLibrary.installedSkills(in: project.url).union((skillPlugins[project.id ?? -1] ?? []).flatMap(\.skills))
            return ProjectSignals.problems(
                runs: runs, steps: steps(of: runs.filter { ProjectSignals.activeStatuses.contains($0.status) }), holds: holds,
                configIssues: ConfigValidator.validate(config), agents: agentSessions(in: project).map(\.agent), installedSkills: installed
            ).map { (project, $0) }
        }
    }

    func open(_ problem: ProjectProblem, in project: Project) {
        guard let id = project.id else { return }
        if let run = problem.runId {
            mainWindow.spec = nil
            openRunDetail(runID: run, in: id)
            return
        }
        switch problem.category {
        case .configErrors, .failingChecks, .gateFindings:
            openSettings(.checks, in: project)
        case .missingSkills:
            openSettings(.skills, in: project)
        }
    }
}
