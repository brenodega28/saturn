import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatSidebar: View {
    static let filterKey = "sidebar.projectFilter"

    @Environment(AppModel.self) private var model
    @AppStorage(ChatSidebar.filterKey, store: AppDefaults.store) private var projectFilter = ProjectFilterKey.all

    var body: some View {
        @Bindable var model = model
        let summaries = model.chatSummaries()
        let filter = ProjectFilterKey.resolve(projectFilter, among: model.allOpenProjects.map { ProjectFilterBar.key($0.workspace, $0.project) })
        let groups = ChatGroup.grouped(Self.only(filter, summaries.open), stage: \.stage, lastActivity: \.lastActivity)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                Spacer()
                AddProjectButton()
                Button { model.requestNewChat() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("New chat (⌘N)")
                .accessibilityLabel("New chat with the Lead")
                .popover(isPresented: $model.isNewChatPickerShown, arrowEdge: .bottom) {
                    NewChatPicker()
                }
            }
            .frame(height: 30)
            SearchChatsButton()
            if model.hasOpenProjects { ProjectFilterBar(filter: $projectFilter) }
            ScrollView {
                ChatList(groups: groups, isEmpty: summaries.open.isEmpty && summaries.closed.isEmpty)
            }
            .scrollIndicators(.never)
            FinishedPanel(finished: groups[.finished] ?? [], closed: Self.only(filter, summaries.closed))
            ForEach(model.systemAlerts) { SidebarAlertCard(alert: $0) }
            SidebarFooter()
        }
        .padding(EdgeInsets(top: 14, leading: 10, bottom: 10, trailing: 10))
        .frame(width: Tokens.Size.sidebar)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.hair).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats with the Lead")
        .onChange(of: model.attentionCount(summaries.open), initial: true) { _, count in model.updateDockBadge(attention: count) }
    }

    private static func only(_ filter: String, _ summaries: [ChatSummary]) -> [ChatSummary] {
        ProjectFilterKey.filter(summaries, by: filter) { ProjectFilterKey.make(daemon: $0.daemon, projectID: $0.project.id) }
    }
}

private struct SearchChatsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.openPalette() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("Search")
                Spacer()
                Text("⌘K").font(Tokens.mono(11))
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Tokens.text2)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Tokens.fill, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Search chats, projects and commands (⌘K)")
    }
}

private struct ChatList: View {
    @Environment(AppModel.self) private var model
    let groups: [ChatGroup: [ChatSummary]]
    let isEmpty: Bool

    var body: some View {
        if isEmpty {
            SidebarEmptyState(
                title: model.hasOpenProjects ? "No chats yet" : "No projects yet",
                message: !model.hasOpenProjects
                    ? "Add a folder on this Mac or on an SSH host. Chats and workers live inside a project."
                    : "Tell the Lead what you need. It writes a spec, starts the workers and brings the result back here.",
                action: model.hasOpenProjects ? "New chat" : "Add project"
            ) {
                if model.hasOpenProjects { model.requestNewChat() } else { model.isOpenPanelPresented = true }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach([ChatGroup.needsYou, .inProgress, .notStarted], id: \.self) { group in
                    StatusGroup(group: group, summaries: groups[group] ?? [])
                }
            }
        }
    }
}

private struct SidebarEmptyState: View {
    let title: String
    let message: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tokens.text)
            Text(message).font(.system(size: 13)).foregroundStyle(Tokens.text2).fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform).buttonStyle(PrimaryPillStyle()).padding(.top, 4)
        }
        .padding(14)
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let summary: ChatSummary
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let isSelected = summary.chat.id.map { model.activePage?.kind.shows(chat: $0, on: summary.daemon) == true } ?? false
        Button { workspace.openChat(summary.chat) } label: {
            HStack(alignment: .top, spacing: 9) {
                StageGlyph(stage: summary.stage).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if summary.isUnread {
                            Circle().fill(Tokens.accent).frame(width: 7, height: 7).accessibilityLabel("New activity")
                        }
                        if isRenaming {
                            TextField("Chat name", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13.5, weight: .semibold))
                                .focused($renameFocused)
                                .onSubmit(commitRename)
                                .onExitCommand { isRenaming = false }
                        } else {
                            Text(summary.chat.title)
                                .font(.system(size: 13.5, weight: titleWeight))
                                .foregroundStyle(Tokens.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(ChatTime.label(summary.lastActivity))
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    HStack(spacing: 6) {
                        ProjectTile(project: summary.project, size: 13)
                        Text(summary.project.name).lineLimit(1).layoutPriority(1)
                        Text("·").foregroundStyle(Tokens.text3)
                        MachineLabel(workspace: workspace, size: 12, showsLocal: true)
                        Spacer(minLength: 4)
                        WorkerStack(workers: summary.workers, project: summary.project, size: 16)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text2)
                }
            }
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
            .background(isSelected ? Tokens.selection : isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { ChatRowMenu(chat: summary.chat, rename: startRename) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.chat.title), \(summary.stage.title), \(summary.project.name)\(workspace.isRemote ? ", on \(workspace.displayName)" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleWeight: Font.Weight {
        summary.isUnread ? .bold : summary.stage == .finished ? .medium : .semibold
    }

    private func startRename() {
        draftTitle = summary.chat.title
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        isRenaming = false
        guard draftTitle.trimmingCharacters(in: .whitespaces) != summary.chat.title else { return }
        workspace.renameChat(summary.chat, to: draftTitle)
    }
}

struct ChatRowMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let chat: Chat
    let rename: () -> Void

    var body: some View {
        Button("Rename", action: rename)
        if !chat.isClosed, let project = workspace.project(withID: chat.projectId) {
            if !chat.isFinished { Button("Mark as finished") { workspace.finishChat(chat) } }
            Button("Resolve") { Task { await workspace.closeRequest(chat, as: .done, in: project) } }
            Button("Close") { Task { await workspace.closeRequest(chat, as: .dropped, in: project) } }
        }
        if chat.isClosed || chat.isFinished {
            Button("Reopen") { workspace.reopenChat(chat) }
        }
        Divider()
        Button("Copy link to chat") { workspace.copyLink(to: chat) }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingChatDeletion = DaemonChat(daemon: workspace.id, chat: chat) }
    }
}

struct ClosedChatRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let summary: ChatSummary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button { workspace.openChat(summary.chat) } label: {
                HStack(spacing: 6) {
                    Text(summary.chat.title).lineLimit(1).foregroundStyle(Tokens.text2)
                    Text("· \(summary.chat.closeReason?.title ?? "Closed") · \((summary.chat.closedAt ?? summary.lastActivity).formatted(.dateTime.month(.abbreviated).day()))")
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isHovered {
                Button("Reopen") { workspace.reopenChat(summary.chat) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.link)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu { ChatRowMenu(chat: summary.chat, rename: {}) }
    }
}

struct WorkerStack: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let workers: [Agent]
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        if !workers.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    ForEach(workers.prefix(3), id: \.id) { agent in
                        AgentAvatar(size: size, appearance: RoleAppearance(role: workspace.role(for: agent, in: project)), isFailing: agent.status == .failed)
                            .background(Tokens.side, in: .rect(cornerRadius: size * 0.33))
                            .help(workspace.displayName(of: agent, in: project))
                    }
                }
                if workers.count > 3 {
                    Text("+\(workers.count - 3)").font(Tokens.mono(10.5)).foregroundStyle(Tokens.text2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(workers.count) worker\(workers.count == 1 ? "" : "s")")
        }
    }
}

struct ProjectTile: View {
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Self.gradient(for: project.name))
            .frame(width: size, height: size)
            .overlay {
                Text(project.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    static let palettes: [(UInt32, UInt32)] = [(0x4A90FF, 0x1F5FD1), (0xB57BFF, 0x7B3FD9), (0x5AD8C4, 0x1A8F80), (0x3FD487, 0x1E8F55), (0xFFB547, 0xD9740A), (0xE58A69, 0xB0532F)]

    static func gradient(for name: String) -> LinearGradient {
        let index = Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }) % palettes.count
        let (top, bottom) = palettes[index]
        return LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom)
    }
}

enum ChatTime {
    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Tokens.primaryForeground)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Tokens.primaryBackground.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .overlay(Capsule().strokeBorder(Tokens.hair2))
            .background(configuration.isPressed ? Tokens.hover : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}

private struct WorkspaceScope: ViewModifier {
    @Environment(AppModel.self) private var model
    let daemon: DaemonID?

    func body(content: Content) -> some View {
        if let workspace = daemon.flatMap(model.workspace(for:)) {
            content.environment(workspace)
        } else {
            content
        }
    }
}

extension View {
    func inWorkspace(_ daemon: DaemonID?) -> some View {
        modifier(WorkspaceScope(daemon: daemon))
    }
}
