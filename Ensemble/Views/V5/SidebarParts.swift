import EnsembleCore
import EnsembleUI
import SwiftUI

struct AddProjectButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Open Folder…") { model.isOpenPanelPresented = true }
            Button("Open SSH Folder…") { model.isRemoteFolderPresented = true }
            Button("Clone Repository…") { model.isClonePresented = true }
            Divider()
            Button("New Project…") { model.newProject() }
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add project")
        .accessibilityLabel("Add project")
    }
}

struct NewChatPicker: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = NewChatFilter.match(model.openProjects, filter: filter)
        VStack(alignment: .leading, spacing: 6) {
            Text("New chat in…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
            TextField("Filter projects", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Tokens.fill, in: .rect(cornerRadius: 8, style: .continuous))
                .focused($isFocused)
                .onSubmit { pick(matches) }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onChange(of: filter) { highlighted = 0 }
            if matches.isEmpty {
                Text("No project matches “\(filter)”. Check the spelling, or add it as a new project.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, project in
                Button { start(project) } label: {
                    HStack(spacing: 10) {
                        ProjectTile(project: project, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Tokens.text)
                            Text(project.isRemote ? project.location : (project.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if index == highlighted { Text("⏎").font(.system(size: 11)).foregroundStyle(Tokens.text3) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 42)
                    .background(index == highlighted ? Tokens.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Tokens.hair)
            Button("Add project…") {
                model.isNewChatPickerShown = false
                model.isOpenPanelPresented = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.link)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private func pick(_ matches: [Project]) {
        guard matches.indices.contains(highlighted) else { return }
        start(matches[highlighted])
    }

    private func start(_ project: Project) {
        model.isNewChatPickerShown = false
        model.startNewChat(in: project)
    }
}

enum NewChatFilter {
    static func match(_ projects: [Project], filter: String) -> [Project] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return projects }
        let prefix = projects.filter { $0.name.lowercased().hasPrefix(needle) }
        let other = projects.filter { !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle) }
        return prefix + other
    }
}

struct ProjectCards: View {
    @Environment(AppModel.self) private var model
    let summaries: [ChatSummary]
    @AppStorage("sidebar.openProject", store: AppDefaults.store) private var openProjectID = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.connections.count > 1 {
                FleetHeader(connection: model.connection, isActive: true)
            }
            ForEach(model.openProjects) { project in
                ProjectCard(
                    project: project,
                    summaries: summaries.filter { $0.project.id == project.id },
                    isOpen: openProjectID == Int(project.id ?? -2)
                ) {
                    openProjectID = openProjectID == Int(project.id ?? -2) ? -1 : Int(project.id ?? -1)
                }
            }
            Button("+ Add project") { model.isOpenPanelPresented = true }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.link)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.hair2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            ForEach(model.orderedConnections.filter { $0.id != model.connection.id }) { other in
                FleetHeader(connection: other, isActive: false)
                ForEach(model.projects(on: other)) { project in
                    Button { model.open(project, on: other) } label: {
                        HStack(spacing: 10) {
                            ProjectTile(project: project, size: 22)
                            Text(project.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Tokens.text)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(project.name) on \(model.displayName(of: other))")
                }
            }
        }
    }
}

private struct FleetHeader: View {
    @Environment(AppModel.self) private var model
    let connection: DaemonConnection
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connection.isRemote ? "server.rack" : "laptopcomputer").font(.system(size: 10))
            Text(model.displayName(of: connection)).font(.system(size: 11.5, weight: .semibold))
            if !connection.isConnected {
                Text("offline").font(.system(size: 10.5)).foregroundStyle(Tokens.text2)
            }
            Spacer()
        }
        .foregroundStyle(isActive ? Tokens.text : Tokens.text2)
        .padding(.top, isActive ? 0 : 8)
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let summaries: [ChatSummary]
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let need = summaries.count { $0.stage.needsAttention }
        VStack(alignment: .leading, spacing: 1) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    ProjectTile(project: project, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text)
                            Image(systemName: project.isRemote ? "cloud" : "laptopcomputer")
                                .font(.system(size: 10))
                                .foregroundStyle(project.isRemote ? Tokens.link : Tokens.text2)
                                .help(project.isRemote ? "SSH · \(project.location)" : "Local · \((project.path as NSString).abbreviatingWithTildeInPath)")
                        }
                        Text(meta(active: summaries.count, need: need))
                            .font(.system(size: 12))
                            .foregroundStyle(need > 0 ? Tokens.need : Tokens.text2)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Tokens.text2)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    section("Crew")
                    item("Agents", symbol: "person.2", tool: .agents, badge: model.agentSessions(in: project).count, badgeColor: Tokens.text2)
                    item("Workflows", symbol: "flowchart", tool: .workflows)
                    section("Review")
                    item("Changes", symbol: "plus.forwardslash.minus", tool: .changes, badge: ProjectOutline.changesBadge(waiting: model.requests.items.filter { $0.projectId == project.id })?.count ?? 0, badgeColor: Tokens.need)
                    item("Source", symbol: "chevron.left.forwardslash.chevron.right", tool: .code)
                    item("Settings", symbol: "gearshape", tool: .settings)
                }
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 8, trailing: 6))
            }
        }
        .background(isOpen ? Tokens.fill : .clear, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isOpen ? Tokens.hair : .clear))
        .contextMenu {
            Button("Project settings") { open(.settings) }
            if project.isRemote {
                Button("Copy SSH path") { model.copyToPasteboard("\(project.location):\(project.path)") }
            } else {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            }
            Button("New chat in this project") { model.startNewChat(in: project) }
            Divider()
            Button("Remove from Ensemble…", role: .destructive) { model.close(project) }
        }
    }

    private func meta(active: Int, need: Int) -> String {
        guard active > 0 else { return "No active chats" }
        return "\(active) active chat\(active == 1 ? "" : "s")" + (need > 0 ? " · \(need) need\(need == 1 ? "s" : "") you" : "")
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Tokens.text2)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 3, trailing: 8))
            .accessibilityAddTraits(.isHeader)
    }

    private func item(_ title: String, symbol: String, tool: MainTool, badge: Int = 0, badgeColor: Color = Tokens.text2) -> some View {
        Button { open(tool) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Tokens.text2).frame(width: 16)
                Text(title).font(.system(size: 13.5)).foregroundStyle(Tokens.text)
                Spacer()
                if badge > 0 { Text("\(badge)").font(Tokens.mono(11.5, weight: .bold)).foregroundStyle(badgeColor) }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func open(_ tool: MainTool) {
        model.selection = .project(project.id ?? -1)
        model.open(tool)
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showsBudget = false

    var body: some View {
        let spent = model.weeklySpend
        let limit = model.globalWeeklyBudget
        let ratio = limit.map { $0 > 0 ? spent / $0 : 0 } ?? 0
        HStack(spacing: 4) {
            footerButton("Usage", symbol: "chart.bar") { model.open(.usage) }
            footerButton("Settings (⌘,)", symbol: "gearshape") { openSettings() }
            Spacer()
            Button { showsBudget.toggle() } label: {
                HStack(spacing: 5) {
                    if ratio >= 0.8 { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
                    Text(BudgetLabel.text(spent: spent, limit: limit))
                        .font(Tokens.mono(11.5))
                }
                .foregroundStyle(ratio >= 1 ? Tokens.stuck : ratio >= 0.8 ? Tokens.review : Tokens.text2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Spend this week")
            .popover(isPresented: $showsBudget, arrowEdge: .top) { BudgetPopover(spent: spent, limit: limit) }
        }
        .padding(.horizontal, 4)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.text2)
                .frame(width: 34, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

enum BudgetLabel {
    static func text(spent: Double, limit: Double?) -> String {
        let spentText = "$\(Int(spent.rounded()))"
        guard let limit, limit > 0 else { return "\(spentText) wk" }
        return spent > limit ? "\(spentText) / \(Int(limit)) · over" : "\(spentText) / \(Int(limit)) wk"
    }
}

private struct BudgetPopover: View {
    @Environment(AppModel.self) private var model
    let spent: Double
    let limit: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spend").font(.system(size: 13, weight: .semibold))
            meter("This week", spent: spent, limit: limit)
            meter("This month", spent: model.monthlySpend, limit: model.globalMonthlyBudget)
            if let limit, spent > limit {
                Text("Over by $\(Int((spent - limit).rounded())). New workers wait until you raise the limit or the week resets.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.stuck).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Usage →") { model.open(.usage) }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.link)
                .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(width: 280)
    }

    private func meter(_ title: String, spent: Double, limit: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Tokens.text2)
                Spacer()
                Text(limit.map { String(format: "$%.0f / $%.0f", spent, $0) } ?? String(format: "$%.0f", spent)).font(Tokens.mono(11.5))
            }
            .font(.system(size: 12))
            ProgressView(value: min(spent, limit ?? spent), total: max(limit ?? spent, 1))
                .tint(limit.map { spent > $0 ? Tokens.stuck : Tokens.text2 } ?? Tokens.text2)
        }
    }
}
