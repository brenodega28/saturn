import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectOverview: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let select: (ProjectPageSection) -> Void

    var body: some View {
        let chats = workspace.chatSummaries(in: project)
        let active = chats.open.filter { $0.stage != .finished }
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(active.filter(\.stage.needsAttention)) { summary in
                    NeedsYouBanner(summary: summary)
                }
                if !active.isEmpty {
                    ActiveChats(summaries: Array(active.prefix(6))) { select(.chats) }
                }
                RecentActivity(project: project, chats: Array((chats.open + chats.closed).prefix(6).map(\.chat)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 22) {
                ProjectStats(project: project, active: active)
                WeekSpendCard(project: project)
                AgentsStrip(project: project) { select(.agents) }
                RepositoryFacts(project: project)
            }
            .frame(width: 320)
        }
    }
}

private struct NeedsYouBanner: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let summary: ChatSummary

    var body: some View {
        let chat = summary.chat
        HStack(spacing: 14) {
            AgentAvatar(size: 34, appearance: RoleAppearance(role: workspace.leadRole(in: summary.project)))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(summary.statusTitle) · \(ChatTime.label(summary.lastActivity))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(summary.stage.color)
                Text(chat.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(2)
                Text(workspace.subtitle(of: summary)).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if workspace.hasOpenProposal(chat) {
                Button("Approve spec") { workspace.approveSpec(for: chat) }
                    .buttonStyle(SmallPillStyle(isPrimary: true))
            }
            Button("Open chat") { workspace.openChat(chat) }
                .buttonStyle(SmallPillStyle())
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(summary.stage.background, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(summary.stage == .stuck ? Tokens.stuckLine : Tokens.needLine))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(summary.stage.title): \(chat.title)")
    }
}

private struct ActiveChats: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let summaries: [ChatSummary]
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectSectionHeading(title: "Active chats") { ProjectLinkButton(title: "All chats", action: showAll) }
            VStack(spacing: 0) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 { Rectangle().fill(Tokens.hair).frame(height: 1) }
                    ActiveChatRow(summary: summary)
                }
            }
            .padding(.vertical, 4)
            .projectCard()
        }
    }
}

private struct ActiveChatRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let summary: ChatSummary
    @State private var isHovered = false

    var body: some View {
        Button { workspace.openChat(summary.chat) } label: {
            HStack(spacing: 12) {
                Circle().fill(summary.stage.color).frame(width: 8, height: 8)
                Text(summary.chat.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WorkerStack(workers: summary.workers, project: summary.project, size: 20)
                Text(summary.statusTitle).font(.system(size: 12)).foregroundStyle(summary.stage.color).frame(width: 92, alignment: .leading).lineLimit(1)
                Text(ChatTime.label(summary.lastActivity)).font(.system(size: 12)).foregroundStyle(Tokens.text3).frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(isHovered ? Tokens.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(summary.chat.title), \(summary.stage.title)")
    }
}

private struct RecentActivity: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chats: [Chat]

    var body: some View {
        let entries = recentEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ProjectSectionHeading(title: "Recent activity")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.id) { item in
                        Button { workspace.openChat(item.chat) } label: {
                            HStack(spacing: 12) {
                                Text(item.entry.date.formatted(date: .omitted, time: .shortened))
                                    .font(Tokens.mono(11.5))
                                    .foregroundStyle(Tokens.text3)
                                    .frame(width: 64, alignment: .leading)
                                Circle().fill(item.entry.tone.color).frame(width: 7, height: 7)
                                (Text(item.entry.who).fontWeight(.semibold) + Text(" · \(item.entry.text)"))
                                    .foregroundStyle(Tokens.text)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.chat.title).font(.system(size: 12)).foregroundStyle(Tokens.text3).lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
                            }
                            .font(.system(size: 13))
                            .frame(height: 32)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentEntries: [(id: String, entry: ChatLogEntry, chat: Chat)] {
        chats.flatMap { chat in
            workspace.chatLog(for: chat, in: project).prefix(7).map { (id: "\(chat.id ?? 0)-\($0.id)", entry: $0, chat: chat) }
        }
        .sorted { $0.entry.date > $1.entry.date }
        .prefix(7)
        .map(\.self)
    }
}

private struct ProjectStats: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let active: [ChatSummary]

    var body: some View {
        let running = workspace.liveAgents(in: project).count { $0.agent.kind != .lead && $0.isRunning }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            stat("\(active.count)", "Active chats", Tokens.text)
            stat("\(running)", "Workers running", Tokens.build)
            stat("\(active.count(where: \.stage.needsAttention))", "Needs you", Tokens.need)
            stat("\(mergedThisWeek)", "Merged this week", Tokens.done)
        }
    }

    private var mergedThisWeek: Int {
        guard let id = project.id, let start = UsagePeriod.week.start(at: .now) else { return 0 }
        _ = workspace.connection.revision
        return ((try? workspace.database.runs(projectId: id)) ?? []).count { ($0.mergedAt ?? .distantPast) >= start }
    }

    private func stat(_ value: String, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold)).tracking(-0.4).foregroundStyle(color)
            Text(title).font(.system(size: 12)).foregroundStyle(Tokens.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .projectCard(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct WeekSpendCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let days = spendByDay
        let total = days.reduce(0, +)
        if total > 0 {
            let peak = days.max() ?? 1
            let today = todayIndex
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("This week").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.text2)
                    Spacer()
                    Text(total.formatted(.currency(code: "USD").precision(.fractionLength(2)))).font(.system(size: 18, weight: .semibold))
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days.indices, id: \.self) { index in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(index == today ? Tokens.accent : Tokens.fill2)
                                .frame(height: max(3, 40 * days[index] / peak))
                            Text(dayLetter(index)).font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                        }
                        .frame(maxWidth: .infinity)
                        .help(days[index].formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    }
                }
                .frame(height: 54, alignment: .bottom)
                .accessibilityHidden(true)
            }
            .padding(14)
            .projectCard(radius: 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Spend this week")
        }
    }

    private var spendByDay: [Double] {
        _ = workspace.connection.usageRevision
        guard let id = project.id, let start = UsagePeriod.week.start(at: .now) else { return [] }
        let costs = (try? workspace.database.usageCosts(projectId: id, since: start)) ?? []
        return WeekSpend.byDay(costs, weekOf: .now)
    }

    private var todayIndex: Int {
        guard let start = UsagePeriod.week.start(at: .now) else { return -1 }
        return Calendar.current.dateComponents([.day], from: start, to: .now).day ?? -1
    }

    private func dayLetter(_ index: Int) -> String {
        let calendar = Calendar.current
        guard let start = UsagePeriod.week.start(at: .now), let day = calendar.date(byAdding: .day, value: index, to: start) else { return "" }
        return calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
    }
}

private struct AgentsStrip: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let manage: () -> Void

    var body: some View {
        let types = workspace.agentTypes(in: project)
        if !types.isEmpty {
            let total = types.reduce(0) { $0 + $1.count }
            let working = types.reduce(0) { $0 + $1.workingCount }
            VStack(alignment: .leading, spacing: 10) {
                ProjectSectionHeading(title: "Agents", detail: "\(types.count) types · \(total) agents · \(working) working") {
                    ProjectLinkButton(title: "Manage") {
                        workspace.setAgentTypeFilter(nil, in: project)
                        manage()
                    }
                }
                FlowLayout(spacing: 8) {
                    ForEach(types) { type in
                        avatar(type)
                    }
                }
            }
        }
    }

    private func avatar(_ type: AgentType) -> some View {
        let label = "\(type.title) ×\(type.count), \(type.status.label)"
        return Button { workspace.openAgentType(type.roleID, in: project) } label: {
            AgentAvatar(size: 32, appearance: RoleAppearance(role: type.role), isFailing: type.sessions.contains { $0.agent.status == .failed })
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(type.status.color).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Tokens.window, lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if type.count > 1 { countBadge(type.count) }
                }
        }
        .buttonStyle(.plain)
        .help("\(type.title) · \(type.summary)")
        .accessibilityLabel(label)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 9.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Tokens.fill2, in: Capsule())
            .overlay(Capsule().stroke(Tokens.window, lineWidth: 2))
            .offset(x: 5, y: -4)
    }
}

private struct RepositoryFacts: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var remote: String?
    @State private var instructions: String?

    var body: some View {
        let facts = rows
        VStack(alignment: .leading, spacing: 10) {
            ProjectSectionHeading(title: "Repository")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.title) { index, fact in
                    if index > 0 { Divider().overlay(Tokens.hair) }
                    GridRow {
                        Text(fact.title).foregroundStyle(Tokens.text2).frame(width: 88, alignment: .leading)
                        value(fact)
                    }
                    .padding(.vertical, 9)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .projectCard(radius: 12)
        }
        .task(id: project.id) { await loadFiles() }
    }

    @ViewBuilder
    private func value(_ fact: Fact) -> some View {
        if let open = fact.open {
            Button(fact.value, action: open).buttonStyle(.plain).foregroundStyle(Tokens.link)
        } else {
            Text(fact.value)
                .font(fact.isCode ? Tokens.mono(11.5) : .system(size: 12.5))
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rows: [Fact] {
        let config = workspace.config(for: project)
        var facts: [Fact] = []
        if let base = config.preferences.baseBranch { facts.append(Fact(title: "Default branch", value: base)) }
        if let remote { facts.append(Fact(title: "Remote", value: remote)) }
        let run = project.settings.runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !run.isEmpty { facts.append(Fact(title: "Run command", value: run)) }
        facts.append(Fact(title: "Worktrees", value: "\(WorktreeManager.directoryName)/"))
        if let instructions {
            facts.append(Fact(title: "Instructions", value: instructions, isCode: false) { workspace.openFile(instructions, in: project) })
        }
        return facts
    }

    private func loadFiles() async {
        let root = project.filesRoot
        let found = await Task.detached {
            let config = try? String(contentsOf: root.appending(path: ".git/config"), encoding: .utf8)
            let origin = config.flatMap(GitRemote.origin(inConfig:)).map(GitRemote.displayName)
            let file = ["CLAUDE.md", "AGENTS.md"].first { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
            return (origin, file)
        }.value
        remote = found.0
        instructions = found.1
    }

    private struct Fact {
        let title: String
        let value: String
        var isCode = true
        var open: (() -> Void)?
    }
}

extension AgentStatus {
    var projectColor: Color {
        switch self {
        case .working: Tokens.build
        case .reviewing: Tokens.review
        case .needsInput, .interrupted: Tokens.need
        case .failed: Tokens.stuck
        case .takenOver: Tokens.accent
        case .idle, .waiting, .paused, .stopped: Tokens.idle
        }
    }
}
