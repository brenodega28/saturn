import SaturnCore
import SaturnUI
import SwiftUI

struct ChatSideBar: View {
    static let width = Tokens.Size.sidebar

    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat
    @State private var logSeenAt: [Int64: Date] = [:]

    var body: some View {
        @Bindable var pages = model.pages
        let tab = pages.sideBarTab
        let stage = workspace.summary(of: chat)?.stage ?? .idle
        let log = workspace.chatLog(for: chat, in: project)
        VStack(spacing: 0) {
            SideBarHeader(selection: $pages.sideBarTab, news: news(stage: stage, log: log)) { pages.isSideBarOpen = false }
            switch tab {
            case .task: TaskPane(project: project, chat: chat, stage: stage)
            case .project: ProjectPane(project: project)
            case .log: LogPane(project: project, chat: chat, entries: log)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.side)
        .overlay(alignment: .leading) { Rectangle().fill(Tokens.hair).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat side bar")
        .onChange(of: tab, initial: true) { markLogSeen(force: tab == .log) }
        .onChange(of: chat.id) { markLogSeen(force: tab == .log) }
        .onChange(of: log.first?.date) { if tab == .log { markLogSeen(force: true) } }
    }

    private func news(stage: ChatStage, log: [ChatLogEntry]) -> [SideBarTab: Color] {
        var news: [SideBarTab: Color] = [:]
        if [.needsYou, .stuck, .inReview].contains(stage) { news[.task] = stage.color }
        if let id = chat.id, let seen = logSeenAt[id], let latest = log.first?.date, latest > seen { news[.log] = Tokens.accent }
        return news
    }

    private func markLogSeen(force: Bool) {
        guard let id = chat.id, force || logSeenAt[id] == nil else { return }
        logSeenAt[id] = .now
    }
}

private struct SideBarHeader: View {
    @Binding var selection: SideBarTab
    let news: [SideBarTab: Color]
    let hide: () -> Void
    @State private var isHideHovered = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SideBarTab.allCases, id: \.self) { tab in
                    segment(tab)
                }
            }
            .padding(3)
            .background(Tokens.fill, in: .rect(cornerRadius: 11, style: .continuous))
            Text(selection.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            Button(action: hide) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 30, height: 30)
                    .background(isHideHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHideHovered = $0 }
            .help("Hide side bar")
            .accessibilityLabel("Hide side bar")
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }

    private func segment(_ tab: SideBarTab) -> some View {
        let isOn = selection == tab
        let dot = isOn ? nil : news[tab]
        return Button { selection = tab } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Tokens.accent : Tokens.text2)
                .frame(width: 38, height: 30)
                .background(isOn ? Tokens.raised : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.accent.opacity(0.34))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Tokens.side, lineWidth: 2))
                            .padding(EdgeInsets(top: 5, leading: 0, bottom: 0, trailing: 7))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(dot == nil ? tab.title : "\(tab.title), new activity")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

private struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).accessibilityAddTraits(.isHeader)
            trailing
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Tokens.text2)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

private struct LinkButton: View {
    let title: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Tokens.link)
            .accessibilityLabel(label)
    }
}

private struct HoverRow<Content: View>: View {
    var radius: CGFloat = Tokens.Radius.row
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .background(isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: radius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private extension View {
    func sideCard() -> some View {
        background(Tokens.raised, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.hair))
    }

    func hairlineAbove(_ isShown: Bool = true) -> some View {
        overlay(alignment: .top) { if isShown { Rectangle().fill(Tokens.hair).frame(height: 1) } }
    }
}

enum ElapsedTime {
    static func label(since start: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private struct TaskPane: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat
    let stage: ChatStage
    @State private var diff: DiffInfo?

    var body: some View {
        let run = workspace.latestRun(of: chat)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TaskHeading(chat: chat, stage: stage)
                    StageBar(current: StageBar.current(stage, hasRun: run != nil), color: stage.color)
                    AppCard(project: project)
                    ChangesSection(project: project, diff: diff)
                    ChecksSection(project: project, chat: chat, run: run)
                    WorkersSection(project: project, chat: chat)
                }
                .padding(EdgeInsets(top: 18, leading: 16, bottom: 20, trailing: 16))
            }
            .scrollIndicators(.never)
            Button { workspace.open(.changes, in: project) } label: {
                Text("Review changes").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillStyle())
            .accessibilityLabel("Review changes")
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .hairlineAbove()
        }
        .task(id: ChangesRow.diffKey(run)) {
            if let run {
                diff = await workspace.diffInfo(run)
            } else {
                diff = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task")
    }
}

private struct TaskHeading: View {
    let chat: Chat
    let stage: ChatStage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(stage.color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(stage.title)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(stage.color)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(stage.background, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(stage.title)")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Started \(ChatTime.label(chat.createdAt, now: context.date)) · \(ElapsedTime.label(since: chat.createdAt, now: context.date))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                }
            }
            Text(chat.title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let goal = Self.goal(of: chat) {
                Text(goal)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func goal(of chat: Chat) -> String? {
        let body = chat.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body != chat.title else { return nil }
        return body
    }
}

struct StageBar: View {
    static let names = ["Plan", "Build", "Review", "Merge"]

    let current: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.names.enumerated()), id: \.offset) { index, name in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(bar(index)).frame(height: 4)
                    Text(name)
                        .font(.system(size: 11.5, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Tokens.text : index < current ? Tokens.text2 : Tokens.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(index < current ? "done" : index == current ? "current" : "not started")")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stages")
    }

    private func bar(_ index: Int) -> Color {
        index < current ? Tokens.done : index == current ? color : Tokens.fill2
    }

    static func current(_ stage: ChatStage, hasRun: Bool) -> Int {
        switch stage {
        case .idle, .dropped: 0
        case .needsYou, .stuck: hasRun ? 1 : 0
        case .building: 1
        case .inReview: 2
        case .finished, .done: names.count
        }
    }
}

private struct AppCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var isOutputOpen = false

    var body: some View {
        let lines = workspace.appOutput(in: project)
        VStack(alignment: .leading, spacing: 0) {
            WorktreeButton(project: project)
            RunRow(project: project, isFlat: true).hairlineAbove()
            OutputRow(project: project, isOpen: $isOutputOpen).hairlineAbove()
            if isOutputOpen {
                Group {
                    if lines.isEmpty {
                        Text("Nothing yet. Start the app to see its output.")
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        AppOutputLines(lines: lines).frame(height: 170)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .background(Tokens.code, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair))
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .font(.system(size: 13))
        .sideCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch and app")
    }
}

private struct ChangesSection: View {
    static let fileLimit = 8

    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let diff: DiffInfo?

    var body: some View {
        let paths = diff?.paths ?? []
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Changes") {
                if let diff, diff.lines > 0 {
                    Text("+\(diff.added.formatted())").font(Tokens.mono(12, weight: .medium)).foregroundStyle(Tokens.done)
                    Text("−\(diff.deleted.formatted())").font(Tokens.mono(12, weight: .medium)).foregroundStyle(Tokens.danger)
                }
                if !paths.isEmpty {
                    Text("· \(paths.count) file\(paths.count == 1 ? "" : "s")").fontWeight(.regular).foregroundStyle(Tokens.text3)
                }
                Spacer(minLength: 4)
                LinkButton(title: "Open diff", label: "Open diff in Changes") { workspace.open(.changes, in: project) }
            }
            if paths.isEmpty {
                Text("No changes yet.").font(.system(size: 12.5)).foregroundStyle(Tokens.text2)
            } else {
                VStack(spacing: 0) {
                    ForEach(paths.prefix(Self.fileLimit), id: \.self) { path in
                        HoverRow(radius: 0, action: { workspace.open(.changes, in: project) }) {
                            Text(path)
                                .font(Tokens.mono(11.5))
                                .foregroundStyle(Tokens.text)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        .help(path)
                        .accessibilityLabel("Open \(path) in Changes")
                    }
                    if paths.count > Self.fileLimit {
                        HoverRow(radius: 0, action: { workspace.open(.changes, in: project) }) {
                            Text("\(paths.count - Self.fileLimit) more")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.link)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        .accessibilityLabel("Show all \(paths.count) files in Changes")
                    }
                }
                .padding(.vertical, 4)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .sideCard()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
    }
}

private struct ChecksSection: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat
    let run: Run?
    @State private var isOpen = true

    var body: some View {
        let checks = workspace.chatChecks(for: chat, run: run)
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .heavy))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text("Checks")
                    Spacer(minLength: 4)
                    Text(ChecksRow.summary(checks.state)).fontWeight(.medium).foregroundStyle(ChecksRow.color(checks.state))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Checks, \(ChecksRow.summary(checks.state))")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checks.rows) { row in
                        CheckLine(row: row)
                    }
                    if checks.rows.isEmpty {
                        Text(ChecksRow.note(checks.state))
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                    if let run {
                        LinkButton(title: "Open run details →", label: "Open run details") { workspace.openRunDetail(run) }
                            .padding(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
                            .hairlineAbove(!checks.rows.isEmpty)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sideCard()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checks")
    }
}

private struct CheckLine: View {
    let row: ChatChecks.Row

    var body: some View {
        HStack(spacing: 10) {
            Text(ChecksRow.mark(row.status))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ChecksRow.color(row.status))
                .frame(width: 16, height: 16)
                .background(Self.background(row.status), in: Circle())
                .accessibilityHidden(true)
            Text(row.name).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(Self.result(row.status)).font(.system(size: 11.5)).foregroundStyle(Tokens.text2)
            Text(row.durationSeconds > 0 ? String(format: "%.1f s", row.durationSeconds) : "")
                .font(Tokens.mono(11))
                .foregroundStyle(Tokens.text3)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
    }

    static func result(_ status: ChatChecks.Row.Status) -> String {
        switch status {
        case .passed: "Passed"
        case .failed: "Failed"
        case .running: "Running"
        }
    }

    static func background(_ status: ChatChecks.Row.Status) -> Color {
        switch status {
        case .passed: Tokens.doneBackground
        case .failed: Tokens.stuckBackground
        case .running: Tokens.buildBackground
        }
    }
}

private struct WorkersSection: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat

    var body: some View {
        let workers = workspace.chatWorkers(chat, in: project)
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Workers") {
                if !workers.isEmpty { Text("\(workers.count)").fontWeight(.regular).foregroundStyle(Tokens.text3) }
            }
            .padding(.bottom, 4)
            if workers.isEmpty {
                Text("No workers on this chat yet.").font(.system(size: 12.5)).foregroundStyle(Tokens.text2)
            }
            ForEach(workers, id: \.agent.id) { worker in
                SideBarWorkerRow(worker: worker, project: project)
            }
            .padding(.horizontal, -6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workers on this chat")
    }
}

private struct SideBarWorkerRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let worker: ChatWorker
    let project: Project

    var body: some View {
        let name = workspace.displayName(of: worker.agent, in: project)
        let doing = Self.doing(worker.agent)
        HoverRow(action: { workspace.openAgentSession(worker.agent, in: project) }) {
            HStack(spacing: 10) {
                AgentAvatar(
                    size: 26, appearance: RoleAppearance(role: workspace.role(for: worker.agent, in: project)),
                    isFailing: worker.state == .failed || worker.state == .stuck
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13)).foregroundStyle(Tokens.text).lineLimit(1)
                    if let doing {
                        Text(doing).font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    if worker.state == .working { ProgressView().controlSize(.mini) }
                    Text(WorkerRow.label(worker.state))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(WorkerRow.color(worker.state))
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 40)
        }
        .help("Open \(name)’s session")
        .accessibilityLabel("\(name), \(WorkerRow.label(worker.state))\(doing.map { ", \($0)" } ?? "")")
    }

    static func doing(_ agent: Agent) -> String? {
        let task = agent.task.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if let task, !task.isEmpty { return task }
        return agent.branch
    }
}

private struct ProjectPane: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var facts: [RepositoryFact] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProjectIdentity(project: project)
                ProjectStats(project: project)
                ProjectAgents(project: project)
                if !facts.isEmpty { RepositoryCard(project: project, facts: facts) }
            }
            .padding(EdgeInsets(top: 18, leading: 16, bottom: 20, trailing: 16))
        }
        .scrollIndicators(.never)
        .task(id: project.id) { facts = await RepositoryFact.load(project, in: workspace) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project")
    }
}

private struct ProjectIdentity: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ProjectTile(project: project, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    MachineLabel(workspace: workspace, size: 12, showsLocal: true).layoutPriority(1)
                    Text("·").foregroundStyle(Tokens.text3)
                    Text((project.path as NSString).abbreviatingWithTildeInPath)
                        .font(Tokens.mono(11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.location)
                }
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text2)
            }
        }
    }
}

struct ProjectStatCounts: Equatable {
    var active = 0
    var workersRunning = 0
    var needsYou = 0
    var finished = 0

    init(active: Int = 0, workersRunning: Int = 0, needsYou: Int = 0, finished: Int = 0) {
        self.active = active
        self.workersRunning = workersRunning
        self.needsYou = needsYou
        self.finished = finished
    }

    init(open: [ChatStage], closed: [ChatStage], workersRunning: Int) {
        self.active = open.count { $0 != .finished }
        self.workersRunning = workersRunning
        self.needsYou = open.count(where: \.needsAttention)
        self.finished = open.count { $0 == .finished } + closed.count { $0 == .done }
    }
}

private struct ProjectStats: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        let summaries = workspace.chatSummaries()
        let isMine = { (summary: ChatSummary) in summary.project.id == project.id }
        let running = workspace.agentSessions(in: project).count { $0.agent.kind != .lead && $0.isRunning }
        let counts = ProjectStatCounts(
            open: summaries.open.filter(isMine).map(\.stage), closed: summaries.closed.filter(isMine).map(\.stage), workersRunning: running
        )
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile(counts.active, "Active chats", Tokens.text)
                tile(counts.workersRunning, "Workers running", Tokens.build)
            }
            GridRow {
                tile(counts.needsYou, "Needs you", Tokens.need)
                tile(counts.finished, "Finished", Tokens.done)
            }
        }
    }

    private func tile(_ value: Int, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 20, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 11.5)).foregroundStyle(Tokens.text2)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sideCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct ProjectAgents: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        let types = workspace.agentTypes(in: project)
        let total = types.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Agents") {
                Text(types.isEmpty ? "0" : "\(types.count) · \(total) agents").fontWeight(.regular).foregroundStyle(Tokens.text3)
                Spacer(minLength: 4)
                LinkButton(title: "Manage", label: "Manage agents") { workspace.open(.agents, in: project) }
            }
            if types.isEmpty {
                Text("No agents yet. Runs start them when the work needs them.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(types) { type in
                    ProjectAgentTypeRow(type: type, project: project)
                }
            }
            .padding(.horizontal, -6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents in this project")
    }
}

private struct ProjectAgentTypeRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let type: AgentType
    let project: Project
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HoverRow(radius: 10, action: open) {
                HStack(spacing: 11) {
                    AgentAvatar(size: 38, appearance: RoleAppearance(role: type.role), isFailing: type.sessions.contains { $0.agent.status == .failed })
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(type.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                            if let model = type.sharedModel {
                                Text(model).font(Tokens.mono(10.5)).foregroundStyle(Tokens.text3).lineLimit(1)
                            }
                        }
                        Text(type.summary).font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if type.count > 1 {
                        Button(isExpanded ? "Hide" : "Show all \(type.count)") { isExpanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Tokens.link)
                            .accessibilityLabel(isExpanded ? "Hide \(type.title) instances" : "Show all \(type.count) \(type.title) instances")
                    }
                    Circle().fill(type.status.color).frame(width: 6, height: 6)
                        .help(type.status.label)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 48)
            }
            .help(type.count == 1 ? "Open the session" : isExpanded ? "Hide instances" : "Show all \(type.count) instances")
            .accessibilityLabel("\(type.title), \(type.summary), \(type.status.label)")
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(type.sessions) { session in
                        ProjectAgentRow(session: session, project: project)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func open() {
        if type.count == 1, let session = type.sessions.first {
            workspace.openAgentSession(session.agent, in: project)
        } else {
            isExpanded.toggle()
        }
    }
}

private struct ProjectAgentRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let session: LiveAgentSession
    let project: Project

    var body: some View {
        let agent = session.agent
        let name = workspace.displayName(of: agent, in: project)
        let role = workspace.role(for: agent, in: project)
        let state = AgentState(status: agent.status, isQueued: session.isQueued)
        HoverRow(radius: 10, action: { workspace.openAgentSession(agent, in: project) }) {
            HStack(spacing: 11) {
                AgentAvatar(size: 38, appearance: RoleAppearance(role: role), isFailing: agent.status == .failed)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                        Text(agent.model).font(Tokens.mono(10.5)).foregroundStyle(Tokens.text3).lineLimit(1)
                    }
                    Text(role?.name ?? agent.role).font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.label)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(state.color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(minHeight: 48)
        }
        .help("Open \(name)’s session")
        .accessibilityLabel("\(name), \(role?.name ?? agent.role), \(agent.model), \(state.label)")
    }
}

private struct AgentState {
    let label: String
    let color: Color

    init(status: AgentStatus, isQueued: Bool) {
        if isQueued {
            self.label = "Queued"
            self.color = Tokens.idle
            return
        }
        self.label = status.label
        self.color = switch status {
        case .working: Tokens.build
        case .needsInput: Tokens.need
        case .reviewing: Tokens.review
        case .failed, .interrupted: Tokens.stuck
        case .takenOver: Tokens.accent
        case .idle, .waiting, .paused: Tokens.idle
        case .stopped: Tokens.text2
        }
    }
}

private struct RepositoryFact: Hashable {
    let title: String
    let value: String
    var path: String?

    @MainActor
    static func load(_ project: Project, in workspace: DaemonWorkspace) async -> [RepositoryFact] {
        var facts: [RepositoryFact] = []
        let git = workspace.git(for: project)
        if let branch = try? await git?.baseBranch(of: project.url), !branch.isEmpty {
            facts.append(RepositoryFact(title: "Default branch", value: branch))
        }
        if let remote = try? await git?.run(["remote", "get-url", "origin"], in: project.url) {
            let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { facts.append(RepositoryFact(title: "Remote", value: shortRemote(trimmed))) }
        }
        if let command = workspace.runCommand(for: project) {
            facts.append(RepositoryFact(title: "Run command", value: command.command))
        }
        if let file = [AgentInstructions.fileName, AgentInstructions.claudeFileName].first(where: {
            FileManager.default.fileExists(atPath: project.filesRoot.appending(path: $0).path)
        }) {
            facts.append(RepositoryFact(title: "Instructions", value: file, path: file))
        }
        return facts
    }

    static func shortRemote(_ url: String) -> String {
        var value = url
        for prefix in ["https://", "http://", "ssh://", "git@"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value.replacingOccurrences(of: ":", with: "/")
    }
}

private struct RepositoryCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let facts: [RepositoryFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Repository")
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element) { index, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(fact.title).foregroundStyle(Tokens.text2).frame(width: 104, alignment: .leading)
                        value(fact)
                    }
                    .font(.system(size: 12.5))
                    .padding(.vertical, 8)
                    .hairlineAbove(index > 0)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .sideCard()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository")
    }

    @ViewBuilder
    private func value(_ fact: RepositoryFact) -> some View {
        if let path = fact.path {
            Button(fact.value) { workspace.openFile(path, in: project) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.link)
                .accessibilityLabel("Open \(fact.value)")
            Spacer(minLength: 0)
        } else {
            Text(fact.value)
                .font(Tokens.mono(11.5))
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum ChatLogFilter: String, CaseIterable {
    case all
    case lead
    case workers
    case tools

    var title: String {
        switch self {
        case .all: "All"
        case .lead: "Lead"
        case .workers: "Workers"
        case .tools: "Tools"
        }
    }

    func matches(_ entry: ChatLogEntry) -> Bool {
        switch self {
        case .all: true
        case .lead: entry.kind == .lead
        case .workers: entry.kind == .worker
        case .tools: entry.kind == .tool
        }
    }
}

private struct LogPane: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat
    let entries: [ChatLogEntry]
    @State private var filter = ChatLogFilter.all

    var body: some View {
        let shown = entries.filter(filter.matches)
        VStack(spacing: 0) {
            LogFilterBar(filter: $filter)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        ChatLogRow(entry: entry, project: project, hasRail: index < shown.count - 1)
                    }
                    if shown.isEmpty {
                        Text("Nothing logged for this filter yet.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.text2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
            }
            .scrollIndicators(.never)
            .accessibilityLabel("Chat progress")
            LogMeter(chat: chat, entries: shown.count, workers: workspace.chatWorkers(chat, in: project).count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Log")
    }
}

private struct LogFilterBar: View {
    @Binding var filter: ChatLogFilter
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ChatLogFilter.allCases, id: \.self) { option in
                let isOn = filter == option
                Button { filter = option } label: {
                    Text(option.title)
                        .font(.system(size: 12))
                        .foregroundStyle(isOn ? Tokens.accent : Tokens.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(isOn ? Tokens.selection : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? Tokens.accent.opacity(0.34) : Tokens.hair))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(option.title.lowercased()) entries")
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Circle()
                    .fill(Tokens.done)
                    .frame(width: 6, height: 6)
                    .opacity(isPulsing ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear { isPulsing = true }
                Text("Live")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Tokens.text2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Updates live")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }
}

private struct LogMeter: View {
    let chat: Chat
    let entries: Int
    let workers: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 14) {
                metric(ElapsedTime.label(since: chat.createdAt, now: context.date), "elapsed")
                metric("\(entries)", entries == 1 ? "entry" : "entries")
                if workers > 0 { metric("\(workers)", workers == 1 ? "worker" : "workers") }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Tokens.text2)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .hairlineAbove()
        .accessibilityElement(children: .combine)
    }

    private func metric(_ value: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(Tokens.mono(11.5)).foregroundStyle(Tokens.text)
            Text(title)
        }
    }
}

private struct ChatLogRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let entry: ChatLogEntry
    let project: Project
    let hasRail: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar.frame(width: 23, height: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.who).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                    Text(entry.tag)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(entry.tone.color)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(entry.tone.background, in: .rect(cornerRadius: 5, style: .continuous))
                    Spacer(minLength: 4)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Tokens.mono(11))
                        .foregroundStyle(Tokens.text3)
                }
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let detail = entry.detail {
                    Text(detail)
                        .font(Tokens.mono(11))
                        .lineSpacing(2)
                        .foregroundStyle(entry.tone == .stuck ? Tokens.stuck : Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.code, in: .rect(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.hair))
                }
            }
        }
        .padding(.bottom, 14)
        .background(alignment: .topLeading) {
            if hasRail {
                Rectangle().fill(Tokens.hair2).frame(width: 1).frame(maxHeight: .infinity).padding(EdgeInsets(top: 26, leading: 11, bottom: 0, trailing: 0))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatar: some View {
        if entry.kind == .tool {
            Image(systemName: entry.isCheck ? "checkmark.seal" : "wrench.and.screwdriver")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(entry.tone.color)
                .frame(width: 23, height: 23)
                .background(entry.tone.background, in: .rect(cornerRadius: 7, style: .continuous))
        } else {
            AgentAvatar(size: 23, appearance: RoleAppearance(role: entry.agent.flatMap { workspace.role(for: $0, in: project) } ?? workspace.leadRole(in: project)))
        }
    }
}

struct ChatLogEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case lead
        case worker
        case tool
    }

    enum Tone: Hashable {
        case need
        case stuck
        case build
        case done
        case idle

        var color: Color {
            switch self {
            case .need: Tokens.need
            case .stuck: Tokens.stuck
            case .build: Tokens.build
            case .done: Tokens.done
            case .idle: Tokens.idle
            }
        }

        var background: Color {
            switch self {
            case .need: Tokens.needBackground
            case .stuck: Tokens.stuckBackground
            case .build: Tokens.buildBackground
            case .done: Tokens.doneBackground
            case .idle: Tokens.fill
            }
        }

        init(_ status: RunStepStatus) {
            switch status {
            case .running: self = .build
            case .waitingOnYou: self = .need
            case .succeeded: self = .done
            case .failed: self = .stuck
            case .cancelled, .interrupted: self = .idle
            }
        }
    }

    let id: String
    let date: Date
    let who: String
    var agent: Agent?
    let tag: String
    let tone: Tone
    let text: String
    let kind: Kind
    var detail: String?
    var isCheck = false
}

extension DaemonWorkspace {
    func chatLog(for chat: Chat, in project: Project) -> [ChatLogEntry] {
        guard let chatID = chat.id else { return [] }
        _ = connection.revision
        _ = leadChatRevision
        let lead = leadSession(for: chat)?.agent
        var entries = [ChatLogEntry(id: "chat", date: chat.createdAt, who: "Lead", agent: lead, tag: "Started", tone: .idle, text: "Chat opened in \(project.name)", kind: .lead)]
        let runs = (try? database.runs(taskId: chatID)) ?? []
        var agentsByID: [Int64: Agent] = [:]
        for run in runs {
            guard let runID = run.id else { continue }
            let agents = (try? database.agents(inRun: runID)) ?? []
            for agent in agents { if let id = agent.id { agentsByID[id] = agent } }
            entries.append(ChatLogEntry(id: "run-\(runID)", date: run.startedAt, who: "Lead", agent: lead, tag: "Started", tone: .build, text: "\(run.displayTitle) started", kind: .lead))
            if let ended = run.endedAt {
                entries.append(runEnd(run, at: ended, lead: lead))
            }
            for step in timeline(for: run)?.entries ?? [] {
                entries.append(logEntry(for: step, agent: agents.first { $0.runStepId == step.id }, lead: lead))
            }
        }
        for request in (try? database.chatRequests(taskId: chatID)) ?? [] {
            let agent = request.agentId.flatMap { agentsByID[$0] ?? self.agent(id: $0) }
            let isOpen = request.status == .open
            let tone: ChatLogEntry.Tone = request.kind == .failure ? .stuck : isOpen && Self.needsYouKinds.contains(request.kind) ? .need : .idle
            entries.append(ChatLogEntry(
                id: "request-\(request.id ?? 0)", date: request.createdAt, who: agent.map { displayName(of: $0, in: project) } ?? "Lead",
                agent: agent ?? lead, tag: RequestNotifier.kindTitle(request.kind), tone: tone, text: request.title,
                kind: agent == nil || agent?.kind == .lead ? .lead : .worker, detail: Self.detail(request.body)
            ))
        }
        for worker in chatWorkers(chat, in: project) {
            let agent = worker.agent
            entries.append(ChatLogEntry(
                id: "worker-\(agent.id ?? 0)", date: agent.createdAt, who: displayName(of: agent, in: project), agent: agent,
                tag: "Started", tone: .build, text: "Started on this chat", kind: .worker, detail: agent.branch
            ))
            if let id = agent.id { agentsByID[id] = agent }
        }
        let runIDs = Set(runs.compactMap(\.id))
        for log in app.activityLog.entries where log.level >= .warning && (log.runId.map(runIDs.contains) == true || log.agentId.map { agentsByID[$0] != nil } == true) {
            let agent = log.agentId.flatMap { agentsByID[$0] }
            let lines = log.message.split(separator: "\n", maxSplits: 1)
            entries.append(ChatLogEntry(
                id: "log-\(log.id)", date: log.date, who: agent.map { displayName(of: $0, in: project) } ?? log.source,
                agent: agent ?? lead, tag: log.level == .error ? "Error" : "Warning", tone: log.level == .error ? .stuck : .need,
                text: lines.first.map(String.init) ?? log.message, kind: .tool, detail: lines.count > 1 ? Self.detail(String(lines[1])) : nil
            ))
        }
        return entries.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    private static func detail(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
    }

    private func runEnd(_ run: Run, at date: Date, lead: Agent?) -> ChatLogEntry {
        let (tag, tone): (String, ChatLogEntry.Tone) = switch run.status {
        case .succeeded: ("Finished", .done)
        case .failed: ("Failed", .stuck)
        case .cancelled, .interrupted: ("Stopped", .idle)
        default: ("Ended", .idle)
        }
        return ChatLogEntry(
            id: "run-end-\(run.id ?? 0)", date: date, who: "Lead", agent: lead, tag: tag, tone: tone,
            text: run.outcome.map(RunTimeline.title(forOutcome:)) ?? run.displayTitle, kind: .lead, detail: run.lastError.flatMap(Self.detail)
        )
    }

    private func logEntry(for step: RunTimeline.Entry, agent: Agent?, lead: Agent?) -> ChatLogEntry {
        let isCheck = step.type == .check || step.type == .gates
        let tag = isCheck ? Self.checkTag(step.status) : step.title
        let status = step.outcomeTitle ?? Self.statusTitle(step.status)
        let showsDetail = isCheck && step.status == .failed
        return ChatLogEntry(
            id: "step-\(step.id)", date: step.endedAt ?? step.startedAt, who: agent.map { displayName(of: $0) } ?? "Saturn",
            agent: agent ?? lead, tag: tag, tone: ChatLogEntry.Tone(step.status),
            text: showsDetail ? "\(step.title) · \(status)" : step.summary ?? (isCheck ? "\(step.title) · \(status)" : status),
            kind: Self.kind(of: step, agent: agent), detail: showsDetail ? step.summary.flatMap(Self.detail) : nil, isCheck: isCheck
        )
    }

    static func kind(of step: RunTimeline.Entry, agent: Agent?) -> ChatLogEntry.Kind {
        if agent?.kind == .lead || step.type == .approval { return .lead }
        if agent != nil || step.type == .agent || step.type == .spawn { return .worker }
        return .tool
    }

    private static func checkTag(_ status: RunStepStatus) -> String {
        switch status {
        case .succeeded: "Checks ✓"
        case .failed: "Checks ✕"
        default: "Checks"
        }
    }

    private static func statusTitle(_ status: RunStepStatus) -> String {
        switch status {
        case .running: "Running"
        case .waitingOnYou: "Waiting for you"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous).path(in: rect)
    }
}

struct TabOutline: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        path.move(to: CGPoint(x: inset.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + radius))
        path.addQuadCurve(to: CGPoint(x: inset.minX + radius, y: inset.minY), control: CGPoint(x: inset.minX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX - radius, y: inset.minY))
        path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.minY + radius), control: CGPoint(x: inset.maxX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        return path
    }
}
