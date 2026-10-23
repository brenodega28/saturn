import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedProjectID: Int64?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarDestination) {
            InboxSidebarRow()
                .tag(SidebarDestination.inbox)

            Section {
                ForEach(model.openProjects) { project in
                    if let id = project.id {
                        ProjectSidebarGroup(
                            project: project,
                            projectID: id,
                            isExpanded: Binding(
                                get: { expandedProjectID == id },
                                set: { expandedProjectID = $0 ? id : nil }
                            )
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Menu {
                        Button("Open Folder…") { model.isOpenPanelPresented = true }
                        Button("Clone Repository…") { model.isClonePresented = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Add project")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onAppear { expandedProjectID = model.selectedProject?.id }
        .onChange(of: model.selectedProject?.id) { _, id in
            if let id { expandedProjectID = id }
        }
        .safeAreaInset(edge: .top) {
            Button {
                model.isPalettePresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text("Search or run…").frame(maxWidth: .infinity, alignment: .leading)
                    Text("⌘K").font(.system(size: 11))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            SpendCard()
                .padding(10)
        }
        .background(Theme.sidebarBackground)
    }
}

private struct SidebarGroup: Identifiable {
    let title: String
    let tabs: [ProjectTab]

    var id: String { title }

    static let all = [
        SidebarGroup(title: "Work", tabs: [.lead, .tasks]),
        SidebarGroup(title: "Crew", tabs: [.agents, .workflows]),
        SidebarGroup(title: "Review", tabs: [.changes, .code]),
    ]

    static let lastTab = all.last?.tabs.last
}

private enum ProjectCardSlice {
    case top
    case middle
    case bottom
}

private extension View {
    func projectCard(_ slice: ProjectCardSlice?) -> some View {
        listRowBackground(
            Group {
                if let slice {
                    let radius: CGFloat = 12
                    UnevenRoundedRectangle(
                        topLeadingRadius: slice == .top ? radius : 0,
                        bottomLeadingRadius: slice == .bottom ? radius : 0,
                        bottomTrailingRadius: slice == .bottom ? radius : 0,
                        topTrailingRadius: slice == .top ? radius : 0,
                        style: .continuous
                    )
                    .fill(Theme.fill)
                    .padding(.horizontal, 10)
                }
            }
        )
    }
}

private struct SidebarBadge {
    let count: Int
    let color: Color
}

private struct ProjectSidebarGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64
    @Binding var isExpanded: Bool

    var body: some View {
        let waiting = model.inbox.items.filter { $0.projectId == projectID }
        ProjectHeaderRow(project: project, projectID: projectID, attention: attentionColor(waiting), isExpanded: $isExpanded)
            .projectCard(isExpanded ? .top : nil)
        if isExpanded {
            ForEach(SidebarGroup.all) { group in
                Text(group.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                    .projectCard(.middle)
                ForEach(group.tabs) { tab in
                    SectionRow(tab: tab, badge: badge(for: tab, waiting: waiting))
                        .tag(SidebarDestination.section(project: projectID, tab: tab))
                        .projectCard(tab == SidebarGroup.lastTab ? .bottom : .middle)
                    if tab == .tasks {
                        SidebarRunRows(project: project, projectID: projectID)
                    }
                }
            }
        }
    }

    private func attentionColor(_ waiting: [InboxItem]) -> Color? {
        if waiting.contains(where: { $0.kind == .failure }) { return Theme.danger }
        return waiting.isEmpty ? nil : Theme.warning
    }

    private func badge(for tab: ProjectTab, waiting: [InboxItem]) -> SidebarBadge? {
        switch tab {
        case .tasks:
            let items = waiting.filter { $0.kind != .pinReview }
            guard !items.isEmpty else { return nil }
            return SidebarBadge(count: items.count, color: attentionColor(items) ?? Theme.warning)
        case .changes:
            let pins = waiting.filter { $0.kind == .pinReview }.count
            return pins > 0 ? SidebarBadge(count: pins, color: Theme.warning) : nil
        case .agents:
            let agents = model.agentSessions(in: project).count
            return agents > 0 ? SidebarBadge(count: agents, color: Theme.tertiaryText) : nil
        case .lead, .workflows, .settings, .code:
            return nil
        }
    }
}

private struct ProjectHeaderRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64
    let attention: Color?
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ProjectTile(project: project)
                    Text(project.name)
                        .fontWeight(isExpanded ? .bold : .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !isExpanded, let attention {
                        StatusDot(attention, size: 6)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(isExpanded ? .zero : .degrees(-90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(project.name)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(attention == nil ? "" : "Has items waiting on you")

            if isExpanded {
                let isSettingsSelected = model.sidebarDestination == .section(project: projectID, tab: .settings)
                Button {
                    model.sidebarDestination = .section(project: projectID, tab: .settings)
                } label: {
                    Image(systemName: ProjectTab.settings.systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(isSettingsSelected ? Color.white : Theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(isSettingsSelected ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Project Settings")
                .accessibilityLabel("\(project.name) settings")
                .accessibilityAddTraits(isSettingsSelected ? .isSelected : [])
            }
        }
        .padding(.top, 2)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("Close Project") { model.close(project) }
        }
    }
}

private struct ProjectTile: View {
    let project: Project

    private static let palette: [(top: UInt32, bottom: UInt32)] = [
        (0x4A90FF, 0x1F5FD1),
        (0xB57BFF, 0x7B3FD9),
        (0x5AD8C4, 0x1A8F80),
        (0xFFB547, 0xD9822B),
        (0xFF7A9A, 0xD13F63),
    ]

    var body: some View {
        let colors = Self.palette[Int(abs(project.id ?? 0) % Int64(Self.palette.count))]
        Text(project.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                LinearGradient(colors: [Color(hex: colors.top), Color(hex: colors.bottom)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct SectionRow: View {
    let tab: ProjectTab
    let badge: SidebarBadge?

    var body: some View {
        Label {
            HStack {
                Text(tab.title)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(badge.color)
                }
            }
        } icon: {
            Image(systemName: tab.systemImage)
        }
        .accessibilityLabel(badge.map { "\(tab.title), \($0.count)" } ?? tab.title)
    }
}

private struct SidebarRunRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let projectID: Int64

    var body: some View {
        ForEach(model.activeLeadRuns(in: project)) { run in
            if let runID = run.id {
                let step = model.currentStepTitle(of: run) ?? run.status.label
                HStack(spacing: 8) {
                    StatusDot(run.status.color, size: 6)
                    Text(run.title.isEmpty ? "Run #\(runID)" : run.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.leading, 24)
                .tag(SidebarDestination.run(project: projectID, run: runID))
                .projectCard(.middle)
                .contextMenu {
                    Button("Show Run Details") { model.openRunDetail(run) }
                    Button("Open in Chat") { model.openRunInLead(run) }
                }
                .help("\(run.title) — \(run.status.label), \(step)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Run \(run.title), \(run.status.label), step \(step)")
                .accessibilityHint("Shows the run’s details")
            }
        }
    }
}

private struct SpendCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let weekly = model.weeklySpend.formatted(.currency(code: "USD"))
        let isSelected = model.selection == .usage
        Button {
            model.sidebarDestination = .usage
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("This week").fontWeight(.semibold)
                    Spacer()
                    Text(weekly).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                }
                if let budget = model.globalMonthlyBudget {
                    let monthly = model.monthlySpend
                    HStack {
                        Text("This month").foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text("\(monthly.formatted(.currency(code: "USD"))) / \(budget.formatted(.currency(code: "USD")))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ProgressView(value: min(monthly / budget, 1))
                        .progressViewStyle(.linear)
                        .tint(monthly >= budget ? Theme.danger : Theme.secondaryText)
                }
            }
            .font(.system(size: 12))
            .padding(12)
            .background(isSelected ? Theme.accent.opacity(0.28) : Color.white.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(weekly: weekly))
    }

    private func accessibilityLabel(weekly: String) -> String {
        guard let budget = model.globalMonthlyBudget else { return "Usage, this week \(weekly)" }
        let monthly = model.monthlySpend.formatted(.currency(code: "USD"))
        return "Usage, this week \(weekly), this month \(monthly) of \(budget.formatted(.currency(code: "USD")))"
    }
}
