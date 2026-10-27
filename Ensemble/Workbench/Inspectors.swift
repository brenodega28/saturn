import EnsembleCore
import EnsembleUI
import SwiftUI

extension EnvironmentValues {
    @Entry var isInWorkbench = false
}

extension WorkbenchRegistry {
    func registerInspectors() {
        register(InspectorTabSpec(id: "details", title: "Details", subject: .agent, order: 0) { AnyView(AgentInspectorHost(subject: $0, tab: .details)) })
        register(InspectorTabSpec(id: "context", title: "Context", subject: .agent, order: 1) { AnyView(AgentInspectorHost(subject: $0, tab: .context)) })
        register(InspectorTabSpec(id: "memory", title: "Memory", subject: .agent, order: 2) { AnyView(AgentInspectorHost(subject: $0, tab: .memory)) })
        register(InspectorTabSpec(id: "workspace", title: "Workspace", subject: .agent, order: 3) { AnyView(AgentInspectorHost(subject: $0, tab: .workspace)) })
        register(InspectorTabSpec(id: "cost", title: "Cost", subject: .agent, order: 4) { AnyView(AgentInspectorHost(subject: $0, tab: .cost)) })

        register(InspectorTabSpec(id: "summary", title: "Summary", subject: .run, order: 0) { AnyView(RunInspectorHost(subject: $0, tab: .summary)) })
        register(InspectorTabSpec(id: "budget", title: "Budget", subject: .run, order: 1) { AnyView(RunInspectorHost(subject: $0, tab: .budget)) })
        register(InspectorTabSpec(id: "branches", title: "Branches", subject: .run, order: 2) { AnyView(RunInspectorHost(subject: $0, tab: .branches)) })
        register(InspectorTabSpec(id: "outcome", title: "Outcome", subject: .run, order: 3) { AnyView(RunInspectorHost(subject: $0, tab: .outcome)) })

        register(InspectorTabSpec(id: "info", title: "Info", subject: .file, order: 0) { AnyView(FileInspectorHost(subject: $0, tab: .info)) })
        register(InspectorTabSpec(id: "history", title: "History", subject: .file, order: 1) { AnyView(FileInspectorHost(subject: $0, tab: .history)) })
        register(InspectorTabSpec(id: "pins", title: "Pins", subject: .file, order: 2) { AnyView(FileInspectorHost(subject: $0, tab: .pins)) })
        register(InspectorTabSpec(id: "risk", title: "Risk tier", subject: .file, order: 3) { AnyView(FileInspectorHost(subject: $0, tab: .risk)) })

        register(InspectorTabSpec(id: "step", title: "Step", subject: .step, order: 0) { AnyView(WorkflowStepInspector(subject: $0)) })
    }
}

struct InspectorFacts: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    Text(row.1).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct TokenBarRow: View {
    let title: String
    let value: Int
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(value.formatted(.number.notation(.compactName))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: maximum > 0 ? proxy.size.width * CGFloat(value) / CGFloat(maximum) : 0)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value) tokens")
    }
}

private enum AgentInspectorTab {
    case details
    case context
    case memory
    case workspace
    case cost
}

private struct AgentInspectorHost: View {
    @Environment(AppModel.self) private var model
    let subject: InspectorSubject
    let tab: AgentInspectorTab

    var body: some View {
        if case .agent(let projectID, let agentID) = subject, let project = model.project(withID: projectID),
           let session = model.agentSessions(in: project).first(where: { $0.id == agentID }) {
            VStack(alignment: .leading, spacing: 12) {
                header(session, project: project)
                switch tab {
                case .details: details(session, project: project)
                case .context: context(session, project: project)
                case .memory:
                    if session.agent.isPinned {
                        MemoryPanel(session: session, project: project)
                    } else {
                        Text("Only pinned agents keep memory between runs. Pin this agent to have it write down what it learns.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                case .workspace: WorkspacePanel(session: session)
                case .cost: cost(session, project: project)
                }
            }
        } else {
            Text("This agent no longer exists.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func header(_ session: AgentSession, project: Project) -> some View {
        let agent = session.agent
        let role = model.role(for: agent, in: project)
        let status = model.displayStatus(of: agent)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentAvatar(size: 34, appearance: RoleAppearance(role: role))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName(of: agent, in: project)).font(.system(size: 13.5, weight: .semibold))
                    Text([role?.name, AgentModel(rawValue: agent.model)?.title ?? agent.model].compactMap(\.self).joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(session.isQueued ? "Queued" : status.label).font(.system(size: 12)).foregroundStyle(status.color)
            }
        }
    }

    private func details(_ session: AgentSession, project: Project) -> some View {
        let agent = session.agent
        let run = agent.runId.flatMap(model.run(withID:))
        return InspectorFacts(rows: [
            ("Task", agent.task.isEmpty ? "None" : agent.task),
            ("Run", run?.displayTitle ?? "Not in a run"),
            ("Branch", agent.branch ?? "No branch"),
            ("Worktree", agent.worktreePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? (agent.readOnly ? "Reads other worktrees" : "None")),
            ("Port", agent.port.map(String.init) ?? "None"),
            ("Created", agent.createdAt.formatted(date: .abbreviated, time: .shortened)),
        ])
    }

    private func context(_ session: AgentSession, project: Project) -> some View {
        let agent = session.agent
        let role = model.role(for: agent, in: project)
        let memoryTokens = agent.isPinned ? TokenEstimate.of((try? String(contentsOf: AgentMemory(repository: project.url, agentName: agent.name).url, encoding: .utf8)) ?? "") : 0
        let context = role.map { RoleContext.build(role: $0, config: model.config(for: project), repository: project.url, pluginSkills: model.pluginSkills(for: project)) }
        let rows = (context?.sections ?? []).map { ($0.source ?? $0.title, $0.tokens) } + (memoryTokens > 0 ? [("Memory", memoryTokens)] : [])
        let total = rows.reduce(0) { $0 + $1.1 }
        let maximum = rows.map(\.1).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context loaded").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(total.formatted(.number.notation(.compactName))) tokens").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            if rows.isEmpty {
                Text("This role loads no prompt, documents or skills.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                TokenBarRow(title: row.0, value: row.1, maximum: maximum)
            }
            ForEach(context?.warnings ?? []) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private func cost(_ session: AgentSession, project: Project) -> some View {
        let agent = session.agent
        let role = model.role(for: agent, in: project)
        let run = agent.runId.flatMap(model.run(withID:))
        return InspectorFacts(rows: [
            ("Spent", agent.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))),
            ("Input tokens", agent.inputTokens.formatted()),
            ("Output tokens", agent.outputTokens.formatted()),
            ("Cache reads", agent.cacheReadTokens.formatted()),
            ("Role budget per run", role?.budgetPerRun.map { $0.formatted(.currency(code: "USD")) } ?? "None"),
            ("Run total", run.map { $0.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))) } ?? "Not in a run"),
        ])
    }
}

private enum RunInspectorTab {
    case summary
    case budget
    case branches
    case outcome
}

private struct RunInspectorHost: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let subject: InspectorSubject
    let tab: RunInspectorTab

    var body: some View {
        let _ = model.engine.runs
        if case .run(let projectID, let runID) = subject, let run = model.run(withID: runID), let project = model.project(withID: projectID) {
            VStack(alignment: .leading, spacing: 12) {
                Text(run.displayTitle).font(.system(size: 13.5, weight: .semibold))
                if let timeline = model.timeline(for: run) {
                    HStack(spacing: 3) {
                        ForEach(timeline.stages) { stage in
                            RoundedRectangle(cornerRadius: 3).fill(stage.state.color).frame(height: 6)
                                .help("\(stage.title): \(stage.state.label)")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(timeline.stages.map { "\($0.title) \($0.state.label)" }.joined(separator: ", "))
                }
                switch tab {
                case .summary: summary(run)
                case .budget: budget(run)
                case .branches: branches(run, project: project)
                case .outcome: outcome(run)
                }
            }
        } else {
            Text("This run no longer exists.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func summary(_ run: Run) -> some View {
        let agents = model.agents(inRun: run)
        let needsYou = agents.filter { model.agentNeedsYou($0) }.count
        let plan = model.timeline(for: run)?.approvedPlan
        return InspectorFacts(rows: [
            ("Status", [model.statusLabel(of: run), model.currentStepTitle(of: run)].compactMap(\.self).joined(separator: " · ")),
            ("Workflow", [run.snapshotWorkflow?.name ?? run.workflow, run.workflowVersion.map { "v\($0)" }].compactMap(\.self).joined(separator: " ")),
            ("Plan", plan.map { "\($0.tasks.count) task\($0.tasks.count == 1 ? "" : "s")" } ?? "No plan"),
            ("Agents", needsYou > 0 ? "\(agents.count) · \(needsYou) need\(needsYou == 1 ? "s" : "") you" : "\(agents.count)"),
            ("Started", run.startedAt.formatted(date: .abbreviated, time: .shortened)),
            ("Elapsed", run.elapsedDescription),
        ])
    }

    private func budget(_ run: Run) -> some View {
        let steps = (try? model.database.runSteps(runId: run.id ?? -1)) ?? []
        let byStep = Dictionary(grouping: steps, by: \.stepId).mapValues { $0.reduce(0) { $0 + $1.costUSD } }
        let workflow = run.snapshotWorkflow
        return VStack(alignment: .leading, spacing: 10) {
            InspectorFacts(rows: [
                ("Spent", run.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))),
                ("Run budget", run.budgetUSD.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) } ?? "No cap"),
            ])
            if let cap = run.budgetUSD, cap > 0 {
                ProgressView(value: min(run.costUSD, cap), total: cap).tint(run.costUSD >= cap ? Theme.danger : Theme.accent)
            }
            Text("By step").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            ForEach(byStep.sorted { $0.value > $1.value }, id: \.key) { stepID, cost in
                HStack {
                    Text(workflow.map { RunTimeline.title(ofStep: stepID, in: $0) } ?? stepID).font(.system(size: 12))
                    Spacer()
                    Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))).font(.system(size: 11.5, design: .monospaced))
                }
            }
        }
    }

    private func branches(_ run: Run, project: Project) -> some View {
        let agents = model.agents(inRun: run).filter { $0.branch != nil }
        return VStack(alignment: .leading, spacing: 8) {
            if let delivery = run.deliveryBranch {
                InspectorFacts(rows: [("Delivery branch", delivery), ("Base", run.baseBranch ?? "main")])
            }
            if agents.isEmpty {
                Text("No agent branches yet.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(agents) { agent in
                Button {
                    if let id = agent.id { state.open(.agent(id, in: run.projectId)) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        AgentAvatar(size: 20, appearance: RoleAppearance(role: model.role(for: agent, in: project)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName(of: agent, in: project)).font(.system(size: 12, weight: .semibold))
                            Text(agent.branch ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func outcome(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorFacts(rows: [
                ("Outcome", run.outcome ?? (ProjectSignals.activeStatuses.contains(run.status) ? "Still running" : run.status.label)),
                ("When it ends", run.endAction ?? run.snapshotWorkflow?.end.action.rawValue ?? "Default"),
                ("Changed", run.linesChanged.map { "\($0) lines in \(run.filesChanged ?? 0) files" } ?? "Not measured yet"),
                ("Merged", run.mergedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not merged"),
            ])
            if let error = run.lastError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger).lineLimit(6)
            }
            if let url = run.pullRequestURL.flatMap(URL.init(string:)) {
                Link("Open pull request", destination: url).font(.system(size: 12))
            }
        }
    }
}

private enum FileInspectorTab {
    case info
    case history
    case pins
    case risk
}

private struct FileInspectorHost: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let subject: InspectorSubject
    let tab: FileInspectorTab
    @State private var history: [GitCommitInfo] = []

    var body: some View {
        if case .file(let projectID, let path) = subject, let project = model.project(withID: projectID) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent).font(.system(size: 13.5, weight: .semibold))
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                }
                switch tab {
                case .info: info(path, project: project)
                case .history: historyList(path, project: project)
                case .pins: pins(path, project: project)
                case .risk: risk(path, project: project)
                }
            }
        }
    }

    private func info(_ path: String, project: Project) -> some View {
        let browser = model.codeBrowser(for: project)
        let url = project.url.appending(path: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return InspectorFacts(rows: [
            ("Lines", browser.lines(path).count.formatted()),
            ("Size", size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unknown"),
            ("Viewing", browser.source?.title ?? "Project checkout"),
            ("Change", browser.change(for: path).map { change in "\(change.status.rawValue.capitalized), \(change.lines.reduce(0) { $0 + $1.count }) lines" } ?? "Unchanged"),
        ])
    }

    private func historyList(_ path: String, project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.isEmpty {
                Text("No commits touch this file yet.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(history) { commit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("\(commit.author) · \(commit.date) · \(commit.hash)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .task(id: path) {
            guard let git = model.git,
                  let log = try? await git.run(["log", "--all", "-n", "20", "--format=%h\t%s\t%an\t%cr", "--", path], in: project.url) else { return }
            history = log.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return parts.count >= 4 ? GitCommitInfo(hash: parts[0], subject: parts[1], author: parts[2], date: parts[3]) : nil
            }
        }
    }

    private func pins(_ path: String, project: Project) -> some View {
        let runs = model.runs(in: [project]).filter { ProjectSignals.activeStatuses.contains($0.status) }
        let pins = runs.flatMap { run in ((try? model.database.pins(runId: run.id ?? -1)) ?? []).filter { $0.file == path }.map { (run, $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            if pins.isEmpty {
                Text("No pins on this file in active runs.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(pins, id: \.1.id) { run, pin in
                Button {
                    model.codeBrowser(for: project).focus(pin.startLine)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pin.title).font(.system(size: 12, weight: .semibold))
                        Text("Lines \(pin.startLine)–\(pin.endLine) · \(run.displayTitle) · \(pin.status.rawValue)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func risk(_ path: String, project: Project) -> some View {
        let tiers = model.config(for: project).review.riskTiers
        let tier = tiers.tier(of: path)
        return VStack(alignment: .leading, spacing: 8) {
            Text(tier.rawValue.capitalized).font(.system(size: 15, weight: .semibold)).foregroundStyle(tier == .core ? Theme.warning : tier == .low ? Theme.successText : Color.white)
            Text(tier.explanation).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Button("Edit risk tiers") { model.openSettings(.checks, in: project) }.buttonStyle(PillButtonStyle(height: 26))
        }
    }
}

extension RiskTier {
    var explanation: String {
        switch self {
        case .core: "Core files get the strictest review: the AI reviewer always runs and you approve every change line by line."
        case .standard: "Standard review: checks, gates and the AI reviewer, then your approval."
        case .low: "Low-risk files, like docs and copy, get a lighter review."
        }
    }
}

private struct WorkflowStepInspector: View {
    @Environment(AppModel.self) private var model
    let subject: InspectorSubject

    var body: some View {
        if case .step(let projectID, _, _) = subject, let project = model.project(withID: projectID), let editor = model.workflowEditors[projectID] {
            let config = model.config(for: project)
            WorkflowInspector(
                editor: editor,
                roles: config.roles,
                checks: config.checks?.checks ?? [],
                issues: model.workflowIssues(editor, config: config),
                activeRuns: editor.saved.map { model.activeRuns(ofWorkflow: $0.id, in: project) } ?? [],
                suggestedLabels: model.suggestedWorkflowLabels(config, project: project)
            )
            .padding(-12)
        }
    }
}

extension AppModel {
    func workflowIssues(_ editor: WorkflowEditor, config: ProjectConfig) -> [ConfigIssue] {
        var draft = editor.draft
        if editor.isNew {
            draft.id = ProjectConfigLoader.newWorkflowID(for: draft.name, existing: config.workflows)
        }
        var issues = ConfigValidator.validate(ProjectConfig(roles: config.roles, workflows: [draft]))
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ConfigIssue(file: "", message: "a workflow needs a name"))
        }
        return issues
    }

    func suggestedWorkflowLabels(_ config: ProjectConfig, project: Project) -> [String] {
        let labels = config.workflows.flatMap(\.trigger.labels) + project.settings.githubMappings.map(\.label)
        return Array(Set(labels)).sorted()
    }
}
