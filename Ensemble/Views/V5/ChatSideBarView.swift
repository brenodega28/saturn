import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatSideBar: View {
    static let width: CGFloat = 320

    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat

    var body: some View {
        @Bindable var pages = model.pages
        VStack(spacing: 0) {
            SideBarTabs(selection: $pages.sideBarTab)
            switch pages.sideBarTab {
            case .summary: ChatSummaryPane(project: project, chat: chat)
            case .log: ChatLogPane(project: project, chat: chat)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Tokens.card)
        .overlay(alignment: .leading) { Rectangle().fill(Tokens.hair2).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat side bar")
    }
}

private struct SideBarTabs: View {
    @Binding var selection: SideBarTab

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(SideBarTab.allCases, id: \.self) { tab in
                let isOn = selection == tab
                Button { selection = tab } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab == .summary ? "text.alignleft" : "list.bullet").font(.system(size: 11.5))
                        Text(tab.title)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn ? Tokens.text : Tokens.text2)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(isOn ? Tokens.card : Tokens.fill, in: TopRoundedRectangle(radius: 9))
                    .overlay { if isOn { TabOutline(radius: 9).stroke(Tokens.hair2) } }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .offset(y: 1)
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
                .accessibilityLabel("\(tab.title) tab")
            }
            Spacer()
            Text("This chat only")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.text2)
                .frame(height: 32)
        }
        .padding(.horizontal, 8)
        .frame(height: 40, alignment: .bottom)
        .background(alignment: .bottom) { Rectangle().fill(Tokens.hair2).frame(height: 1) }
        .zIndex(1)
    }
}

private struct ChatSummaryPane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat

    var body: some View {
        let stage = model.summary(of: chat)?.stage ?? .idle
        let workers = model.chatWorkers(chat, in: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Tokens.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        ProjectTile(project: project, size: 14)
                        Text(project.name).foregroundStyle(Tokens.text2)
                        HStack(spacing: 5) {
                            Circle().fill(stage.color).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(stage.title)
                        }
                        .foregroundStyle(stage.color)
                    }
                    .font(.system(size: 12))
                }
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10))
                ChatCardRows(project: project, chat: chat)
                if !workers.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workers")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                            .padding(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
                        ForEach(workers, id: \.agent.id) { worker in
                            SideBarWorkerRow(worker: worker, project: project)
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
                    .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
                    .padding(.top, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Workers on this chat")
                }
            }
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 12, trailing: 6))
        }
        .scrollIndicators(.never)
    }
}

private struct SideBarWorkerRow: View {
    @Environment(AppModel.self) private var model
    let worker: ChatWorker
    let project: Project
    @State private var isHovered = false

    var body: some View {
        let name = model.displayName(of: worker.agent, in: project)
        Button { model.openAgentSession(worker.agent, in: project) } label: {
            HStack(spacing: 9) {
                AgentAvatar(
                    size: 20, appearance: RoleAppearance(role: model.role(for: worker.agent, in: project)),
                    isFailing: worker.state == .failed || worker.state == .stuck
                )
                Text(name).foregroundStyle(Tokens.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(WorkerRow.label(worker.state))
                    .font(.system(size: 11.5))
                    .foregroundStyle(WorkerRow.color(worker.state))
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(name)’s session")
        .accessibilityLabel("\(name), \(WorkerRow.label(worker.state))")
    }
}

enum ChatLogFilter: String, CaseIterable {
    case all
    case needsYou
    case checks

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        case .checks: "Checks"
        }
    }

    func matches(_ entry: ChatLogEntry) -> Bool {
        switch self {
        case .all: true
        case .needsYou: entry.tone == .need || entry.tone == .stuck
        case .checks: entry.isCheck
        }
    }
}

private struct ChatLogPane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat
    @State private var filter = ChatLogFilter.all

    var body: some View {
        let entries = model.chatLog(for: chat, in: project).filter(filter.matches)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(ChatLogFilter.allCases, id: \.self) { option in
                    let isOn = filter == option
                    Button { filter = option } label: {
                        Text(option.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.text)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(isOn ? Tokens.selection : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(isOn ? Tokens.hair2 : Tokens.hair))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Tokens.live).frame(width: 6, height: 6)
                    Text("live")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.live)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Updates live")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        ChatLogRow(entry: entry, project: project)
                    }
                    if entries.isEmpty {
                        Text(filter == .all ? "Nothing has happened in this chat yet." : "No \(filter.title.lowercased()) events in this chat.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.text2)
                            .padding(.vertical, 12)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 16, trailing: 12))
            }
            .scrollIndicators(.never)
            .accessibilityLabel("Log for this chat")
        }
    }
}

private struct ChatLogRow: View {
    @Environment(AppModel.self) private var model
    let entry: ChatLogEntry
    let project: Project

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                AgentAvatar(size: 20, appearance: RoleAppearance(role: entry.agent.flatMap { model.role(for: $0, in: project) } ?? model.leadRole(in: project)))
                Rectangle().fill(Tokens.hair).frame(width: 2).frame(minHeight: 8, maxHeight: .infinity)
            }
            .frame(width: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.who).fontWeight(.semibold).foregroundStyle(Tokens.text).lineLimit(1)
                    Text(entry.tag).fontWeight(.semibold).foregroundStyle(entry.tone.color).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(Tokens.mono(10.5))
                        .foregroundStyle(Tokens.text3)
                }
                .font(.system(size: 11.5))
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChatLogEntry: Identifiable, Hashable {
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
            case .idle: Tokens.text2
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
    var isCheck = false
}

extension AppModel {
    func chatLog(for chat: Chat, in project: Project) -> [ChatLogEntry] {
        guard let chatID = chat.id else { return [] }
        _ = connection.revision
        _ = leadChatRevision
        let lead = leadSession(for: chat)?.agent
        var entries = [ChatLogEntry(id: "chat", date: chat.createdAt, who: "Lead", agent: lead, tag: "Started", tone: .idle, text: "Chat opened in \(project.name)")]
        let runs = (try? database.runs(taskId: chatID)) ?? []
        var agentsByID: [Int64: Agent] = [:]
        for run in runs {
            guard let runID = run.id else { continue }
            let agents = (try? database.agents(inRun: runID)) ?? []
            for agent in agents { if let id = agent.id { agentsByID[id] = agent } }
            entries.append(ChatLogEntry(id: "run-\(runID)", date: run.startedAt, who: "Lead", agent: lead, tag: "Started", tone: .build, text: "\(run.displayTitle) started"))
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
                agent: agent ?? lead, tag: RequestNotifier.kindTitle(request.kind), tone: tone, text: request.title
            ))
        }
        for worker in chatWorkers(chat, in: project) {
            let agent = worker.agent
            entries.append(ChatLogEntry(
                id: "worker-\(agent.id ?? 0)", date: agent.createdAt, who: displayName(of: agent, in: project), agent: agent,
                tag: "Started", tone: .build, text: agent.branch.map { "Working on \($0)" } ?? "Started on this chat"
            ))
            if let id = agent.id { agentsByID[id] = agent }
        }
        let runIDs = Set(runs.compactMap(\.id))
        for log in activityLog.entries where log.level >= .warning && (log.runId.map(runIDs.contains) == true || log.agentId.map { agentsByID[$0] != nil } == true) {
            let agent = log.agentId.flatMap { agentsByID[$0] }
            entries.append(ChatLogEntry(
                id: "log-\(log.id)", date: log.date, who: agent.map { displayName(of: $0, in: project) } ?? log.source,
                agent: agent ?? lead, tag: log.level == .error ? "Error" : "Warning", tone: log.level == .error ? .stuck : .need, text: log.message
            ))
        }
        return entries.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
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
            text: run.lastError ?? run.outcome.map(RunTimeline.title(forOutcome:)) ?? run.displayTitle
        )
    }

    private func logEntry(for step: RunTimeline.Entry, agent: Agent?, lead: Agent?) -> ChatLogEntry {
        let isCheck = step.type == .check
        let tag = isCheck ? Self.checkTag(step.status) : step.title
        let status = step.outcomeTitle ?? Self.statusTitle(step.status)
        return ChatLogEntry(
            id: "step-\(step.id)", date: step.endedAt ?? step.startedAt, who: agent.map { displayName(of: $0) } ?? "Ensemble",
            agent: agent ?? lead, tag: tag, tone: ChatLogEntry.Tone(step.status),
            text: step.summary ?? (isCheck ? "\(step.title) · \(status)" : status), isCheck: isCheck
        )
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
