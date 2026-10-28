import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkspaceNavigator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let project = model.currentProject, let id = project.id {
            ProjectOutlineTree(project: project, projectID: id)
        } else {
            VStack(spacing: 12) {
                NavigatorEmpty(title: "No project open", message: "Open a folder or start a new project to see its chat, tasks and agents here.")
                HStack(spacing: 8) {
                    Button("Open…") { model.isOpenPanelPresented = true }
                        .buttonStyle(PillButtonStyle(.primary, height: 26))
                    Button("New Project…") { model.newProject() }
                        .buttonStyle(PillButtonStyle(height: 26))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension AppModel {
    func agentWorktrees(in project: Project) -> [Worktree] {
        let root = project.url.standardizedFileURL.path
        return state(for: project).worktrees.filter { $0.branch != nil && $0.path.standardizedFileURL.path != root }
    }
}

private extension ProjectTab {
    static let outlineOrder: [ProjectTab] = [.lead, .tasks, .agents, .workflows, .changes, .code, .settings]

    var outlineTitle: String {
        self == .code ? "Source" : title
    }
}

private struct ProjectOutlineTree: View {
    @Environment(AppModel.self) private var model
    @AppStorage("workspace.outline.expanded") private var storedExpansion: String?
    let project: Project
    let projectID: Int64

    var body: some View {
        let _ = model.engine.runs
        let waiting = model.inbox.items.filter { $0.projectId == projectID }
        let expanded = ProjectOutline.decodeExpanded(storedExpansion)
        let needsYouTaskIDs = model.needsYouTaskIDs()
        let requests = LeadRequest.partition(model.leadRequests(in: project)).open
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                OutlineProjectHeader(project: project)
                ForEach(ProjectTab.outlineOrder) { tab in
                    let isExpanded = expanded.contains(tab.rawValue)
                    OutlineSectionRow(
                        title: tab.outlineTitle,
                        systemImage: tab.systemImage,
                        badge: badge(for: tab, waiting: waiting, requests: requests, needsYouTaskIDs: needsYouTaskIDs),
                        isExpanded: isExpanded,
                        isSelected: isSelected(tab),
                        toggle: { withAnimation(.snappy(duration: 0.2)) { storedExpansion = ProjectOutline.toggling(tab.rawValue, in: storedExpansion) } },
                        open: { open(tab) }
                    )
                    if isExpanded {
                        children(of: tab, requests: requests, needsYouTaskIDs: needsYouTaskIDs)
                    }
                }
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 10, trailing: 8))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
    }

    @ViewBuilder
    private func children(of tab: ProjectTab, requests: [ProjectTask], needsYouTaskIDs: Set<Int64>) -> some View {
        switch tab {
        case .lead: OutlineRequestRows(project: project, projectID: projectID, requests: requests, needsYouTaskIDs: needsYouTaskIDs)
        case .tasks: OutlineRunRows(project: project, projectID: projectID)
        case .agents: OutlineAgentRows(project: project, projectID: projectID)
        case .workflows: OutlineWorkflowRows(project: project, projectID: projectID)
        case .changes: OutlineChangesRows(project: project, projectID: projectID)
        case .code: OutlineSourceRows(project: project, projectID: projectID)
        case .settings: OutlineSettingsRows(project: project, projectID: projectID)
        case .roles: EmptyView()
        }
    }

    private func open(_ tab: ProjectTab) {
        if tab == .lead {
            model.newChat(in: project)
            return
        }
        if tab == .agents { model.selectedAgents[projectID] = nil }
        model.sidebarDestination = .section(project: projectID, tab: tab)
    }

    private func isSelected(_ tab: ProjectTab) -> Bool {
        guard model.sidebarDestination == .section(project: projectID, tab: tab) else { return false }
        switch tab {
        case .agents:
            return model.selectedAgents[projectID] == nil
        case .changes:
            let runs = Set(model.openPins(in: project).compactMap(\.run.id))
            return model.changesRunSelections[projectID].map { !runs.contains($0) } ?? true
        case .settings:
            return !OutlineSettingsRows.childSections.contains(model.settingsSections[projectID] ?? .general)
        case .lead, .tasks, .workflows, .code, .roles:
            return true
        }
    }

    private func badge(for tab: ProjectTab, waiting: [InboxItem], requests: [ProjectTask], needsYouTaskIDs: Set<Int64>) -> ProjectOutline.Badge? {
        switch tab {
        case .lead:
            let needsYou = requests.contains { model.requestNeedsYou($0, latestRun: model.latestRun(of: $0), needsYouTaskIDs: needsYouTaskIDs) }
            return ProjectOutline.countBadge(requests.count, tone: needsYou ? .warning : .quiet)
        case .tasks:
            return ProjectOutline.tasksBadge(waiting: waiting)
        case .changes:
            return ProjectOutline.changesBadge(waiting: waiting)
        case .agents:
            return ProjectOutline.countBadge(model.agentSessions(in: project).count)
        case .workflows:
            return ProjectOutline.countBadge(model.config(for: project).workflows.count)
        case .code, .settings, .roles:
            return nil
        }
    }
}

private struct OutlineProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let branchLine = ProjectOutline.branchLine(branch: model.state(for: project).branch, worktrees: model.agentWorktrees(in: project).count)
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 14)
            ProjectTile(project: project, size: 16)
            Text(project.name)
                .fontWeight(.bold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(branchLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .font(.system(size: 12.5))
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: 26)
        .padding(.bottom, 2)
        .contentShape(.rect)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("Close Project") { model.close(project) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), \(branchLine)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct OutlineSectionRow: View {
    let title: String
    let systemImage: String
    let badge: ProjectOutline.Badge?
    let isExpanded: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(isExpanded ? .zero : .degrees(-90))
                    .frame(width: 14, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title)")
            Button(action: open) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Color.white : Theme.link)
                        .frame(width: 16)
                    Text(title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge {
                        Text("\(badge.count)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(badge.tone.color)
                    }
                }
                .padding(.leading, 3)
                .padding(.trailing, 6)
                .frame(height: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(badge.map { "\(title), \($0.count)" } ?? title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(isSelected ? [.isHeader, .isSelected] : .isHeader)
        }
        .font(.system(size: 12.5))
        .background(isSelected ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 5, style: .continuous))
    }
}

private struct OutlineChildRow<Leading: View>: View {
    let title: String
    var meta: String = ""
    var metaColor: Color = Theme.tertiaryText
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading
                    .frame(width: 14)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(metaColor)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 18 + 14 + 3)
            .padding(.trailing, 6)
            .frame(height: 22)
            .background(isSelected ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 5, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension OutlineChildRow where Leading == StatusDot {
    init(title: String, meta: String = "", metaColor: Color = Theme.tertiaryText, dot: Color, isSelected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, meta: meta, metaColor: metaColor, isSelected: isSelected, action: action) {
            StatusDot(dot, size: 6)
        }
    }
}

private func metaColor(for dot: Color) -> Color {
    dot == Theme.warning || dot == Theme.danger ? dot : Theme.tertiaryText
}

private struct OutlineRequestRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64
    let requests: [ProjectTask]
    let needsYouTaskIDs: Set<Int64>

    var body: some View {
        ForEach(requests) { request in
            if let requestID = request.id {
                let run = model.latestRun(of: request)
                let title = request.title.isEmpty ? "Request #\(requestID)" : request.title
                let status = model.requestStatusLabel(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
                let dot = model.statusColor(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
                let destination = SidebarDestination.request(project: projectID, request: requestID)
                OutlineChildRow(title: title, meta: status, metaColor: metaColor(for: dot), dot: dot, isSelected: model.sidebarDestination == destination) {
                    model.sidebarDestination = destination
                }
                .contextMenu { RequestCloseMenu(request: request, project: project) }
                .help("\(title) — \(status)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Request \(title), \(status)")
                .accessibilityHint("Opens the request in chat")
            }
        }
        let showMore = SidebarDestination.requests(project: projectID)
        OutlineChildRow(title: "Show more", isSelected: model.sidebarDestination == showMore) {
            model.sidebarDestination = showMore
        } leading: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .help("Show all open and closed requests")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show more requests")
        .accessibilityHint("Opens the list of all requests")
    }
}

private struct OutlineRunRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64

    var body: some View {
        ForEach(model.activeLeadRuns(in: project)) { run in
            if let runID = run.id {
                let status = model.statusLabel(of: run)
                let step = model.currentStepTitle(of: run) ?? status
                let dot = model.statusColor(of: run)
                let destination = SidebarDestination.run(project: projectID, run: runID)
                OutlineChildRow(title: run.title.isEmpty ? "Run #\(runID)" : run.title, meta: step, metaColor: metaColor(for: dot), dot: dot, isSelected: model.sidebarDestination == destination) {
                    model.sidebarDestination = destination
                }
                .contextMenu {
                    Button("Show Run Details") { model.openRunDetail(run) }
                    Button("Open in Chat") { model.openRunInLead(run) }
                }
                .help("\(run.title) — \(status), \(step)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Run \(run.title), \(status), step \(step)")
                .accessibilityHint("Shows the run’s details")
            }
        }
    }
}

private struct OutlineAgentRows: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let project: Project
    let projectID: Int64

    var body: some View {
        ForEach(model.agentSessions(in: project), id: \.id) { session in
            let status = model.displayStatus(of: session.agent)
            let name = model.displayName(of: session.agent, in: project)
            let label = session.isQueued ? "Queued" : status.label
            let isSelected = model.sidebarDestination == .section(project: projectID, tab: .agents) && model.selectedAgents[projectID] == session.id
            OutlineChildRow(title: name, meta: label, metaColor: metaColor(for: status.color), dot: status.color, isSelected: isSelected) {
                state.open(.agent(session.id, in: projectID))
            }
            .contextMenu { ContextCommands(groups: ContextCommands.agent, target: .agent(project: projectID, agent: session.id)) }
            .help("\(name) — \(label)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent \(name), \(label)")
            .accessibilityHint("Opens the agent’s session")
        }
    }
}

private struct OutlineWorkflowRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64

    var body: some View {
        let config = model.config(for: project)
        let defaultID = config.workflow(config.preferences.defaultWorkflow ?? "")?.id ?? config.workflows.first?.id
        ForEach(config.workflows) { workflow in
            let title = "\(workflow.name) v\(workflow.version)"
            let isDefault = workflow.id == defaultID
            OutlineChildRow(title: title, meta: isDefault ? "default" : "", dot: Theme.neutral) {
                model.sidebarDestination = .section(project: projectID, tab: .workflows)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workflow \(title)\(isDefault ? ", default" : "")")
            .accessibilityHint("Opens Workflows")
        }
    }
}

private struct OutlineChangesRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64

    var body: some View {
        let pins = model.openPins(in: project)
        let runs = pins.reduce(into: [Run]()) { runs, entry in
            if !runs.contains(where: { $0.id == entry.run.id }) { runs.append(entry.run) }
        }
        ForEach(runs) { run in
            if let runID = run.id {
                let count = pins.filter { $0.run.id == runID }.count
                let pinsLabel = ProjectOutline.pinsLabel(count)
                let isSelected = model.sidebarDestination == .section(project: projectID, tab: .changes) && model.changesRunSelections[projectID] == runID
                OutlineChildRow(title: run.displayTitle, meta: pinsLabel, dot: Theme.paused, isSelected: isSelected) {
                    model.changesRunSelections[projectID] = runID
                    model.sidebarDestination = .section(project: projectID, tab: .changes)
                }
                .help("\(run.displayTitle) — \(pinsLabel) to review")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(run.displayTitle), \(pinsLabel) to review")
                .accessibilityHint("Opens the run in Changes")
            }
        }
    }
}

private struct OutlineSourceRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64
    @State private var ahead: [String: Int] = [:]

    var body: some View {
        let base = model.config(for: project).preferences.baseBranch ?? model.state(for: project).branch ?? "main"
        let worktrees = model.agentWorktrees(in: project)
        OutlineChildRow(title: base, meta: "base", dot: Theme.neutral, action: openSource)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Base branch \(base)")
            .accessibilityHint("Opens Source")
            .task(id: worktrees.map(\.id) + [base]) { await loadAhead(of: worktrees, base: base) }
        ForEach(worktrees) { worktree in
            let branch = worktree.branch ?? ""
            let title = "\(worktree.agent) · \(branch.split(separator: "/").last.map(String.init) ?? branch)"
            let count = ahead[worktree.id] ?? 0
            OutlineChildRow(title: title, meta: count > 0 ? "↑\(count)" : "", dot: Theme.success, action: openSource)
                .help(branch)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Branch \(branch)\(count > 0 ? ", \(count) commits ahead" : "")")
                .accessibilityHint("Opens Source")
        }
    }

    private func openSource() {
        model.sidebarDestination = .section(project: projectID, tab: .code)
    }

    private func loadAhead(of worktrees: [Worktree], base: String) async {
        guard let git = model.git else { return }
        var counts: [String: Int] = [:]
        for worktree in worktrees {
            guard let branch = worktree.branch,
                  let output = try? await git.run(["rev-list", "--count", "\(base)..\(branch)"], in: project.url),
                  let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            counts[worktree.id] = count
        }
        ahead = counts
    }
}

private struct OutlineSettingsRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64

    static let childSections: Set<SettingsSection> = [.checks, .agents]

    var body: some View {
        let config = model.config(for: project)
        let roles = SidebarDestination.section(project: projectID, tab: .roles)
        OutlineChildRow(title: "Roles", meta: config.roles.isEmpty ? "" : "\(config.roles.count)", dot: Theme.neutral, isSelected: model.sidebarDestination == roles) {
            model.sidebarDestination = roles
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Roles, \(config.roles.count)")
        settingsRow("Checks", section: .checks, count: config.checks?.checks.count ?? 0)
        settingsRow("Budgets", section: .agents, count: 0)
    }

    private func settingsRow(_ title: String, section: SettingsSection, count: Int) -> some View {
        let isSelected = model.sidebarDestination == .section(project: projectID, tab: .settings) && model.settingsSections[projectID] == section
        return OutlineChildRow(title: title, meta: count > 0 ? "\(count)" : "", dot: Theme.neutral, isSelected: isSelected) {
            model.settingsSections[projectID] = section
            model.sidebarDestination = .section(project: projectID, tab: .settings)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityHint("Opens \(title) settings")
    }
}
