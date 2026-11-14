import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatSidebar: View {
    static let tabKey = "sidebar.tab"

    @Environment(AppModel.self) private var model
    @AppStorage(ChatSidebar.tabKey, store: AppDefaults.store) private var tab = SidebarTab.chats

    var body: some View {
        @Bindable var model = model
        let summaries = model.chatSummaries()
        VStack(alignment: .leading, spacing: 12) {
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
            SidebarTabs(tab: $tab, badge: model.attentionCount(summaries.open))
            ScrollView {
                switch tab {
                case .chats:
                    ChatList(open: summaries.open, closed: summaries.closed)
                case .projects:
                    ProjectCards(summaries: summaries.open)
                }
            }
            .scrollIndicators(.never)
            ForEach(model.systemAlerts) { SidebarAlertCard(alert: $0) }
            SidebarFooter()
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
        .frame(width: Tokens.Size.sidebar)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.hair).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats with the Lead")
        .onChange(of: model.attentionCount(summaries.open), initial: true) { _, count in model.updateDockBadge(attention: count) }
    }
}

enum SidebarTab: String {
    case chats
    case projects
}

private struct SearchChatsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.openPalette() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("Search chats")
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
        .help("Search chats and commands (⌘K)")
    }
}

private struct SidebarTabs: View {
    @Binding var tab: SidebarTab
    let badge: Int

    var body: some View {
        HStack(spacing: 0) {
            segment(.chats, "Chats", badge: badge)
            segment(.projects, "Projects", badge: 0)
        }
        .padding(3)
        .background(Tokens.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private func segment(_ value: SidebarTab, _ title: String, badge: Int) -> some View {
        let isOn = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Tokens.need)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Tokens.needBackground, in: Capsule())
                }
            }
            .foregroundStyle(isOn ? Tokens.text : Tokens.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(isOn ? Tokens.tabOn : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(badge > 0 ? "\(badge) need you" : "")
    }
}

private struct ChatList: View {
    @Environment(AppModel.self) private var model
    let open: [ChatSummary]
    let closed: [ChatSummary]
    @AppStorage("sidebar.closedExpanded", store: AppDefaults.store) private var showsClosed = false

    var body: some View {
        if open.isEmpty && closed.isEmpty {
            SidebarEmptyState(
                title: model.openProjects.isEmpty ? "No projects yet" : "No chats yet",
                message: model.openProjects.isEmpty
                    ? "Add a folder on this Mac or on an SSH host. Chats and workers live inside a project."
                    : "Tell the Lead what you need. It writes a spec, starts the workers and brings the result back here.",
                action: model.openProjects.isEmpty ? "Add project" : "New chat"
            ) {
                if model.openProjects.isEmpty { model.isOpenPanelPresented = true } else { model.requestNewChat() }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(open) { ChatRow(summary: $0) }
                if !closed.isEmpty {
                    Button { showsClosed.toggle() } label: {
                        HStack(spacing: 6) {
                            Text("Closed \(closed.count)")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(showsClosed ? 0 : -90))
                            Spacer()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.text2)
                        .padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsClosed ? "expanded" : "collapsed")
                    if showsClosed {
                        ForEach(closed.prefix(Self.closedLimit)) { ClosedChatRow(summary: $0) }
                        if closed.count > Self.closedLimit {
                            Text("Older closed chats are in ⌘K search.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Tokens.text3)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    static let closedLimit = 24
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
    let summary: ChatSummary
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let isSelected = model.currentProject?.id == summary.project.id && model.selectedRequestID == summary.id && model.mainScreen.isChat
        Button { model.openChat(summary.chat) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if summary.isUnread {
                        Circle().fill(Tokens.accent).frame(width: 7, height: 7).accessibilityLabel("New activity")
                    }
                    if isRenaming {
                        TextField("Chat name", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .focused($renameFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(summary.chat.title)
                            .font(.system(size: 14, weight: summary.isUnread ? .bold : .semibold))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(ChatTime.label(summary.lastActivity))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text2)
                }
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(summary.stage.color).frame(width: 6, height: 6)
                        Text(summary.stage.title).lineLimit(1)
                    }
                    .foregroundStyle(summary.stage.color)
                    HStack(spacing: 5) {
                        ProjectTile(project: summary.project, size: 13)
                        Text(summary.project.name).lineLimit(1)
                    }
                    .foregroundStyle(Tokens.text2)
                    Spacer(minLength: 4)
                    WorkerStack(workers: summary.workers, project: summary.project)
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Tokens.selection : isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { ChatRowMenu(chat: summary.chat, rename: startRename) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.chat.title), \(summary.stage.title), \(summary.project.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func startRename() {
        draftTitle = summary.chat.title
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        isRenaming = false
        guard draftTitle.trimmingCharacters(in: .whitespaces) != summary.chat.title else { return }
        model.renameChat(summary.chat, to: draftTitle)
    }
}

struct ChatRowMenu: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let rename: () -> Void

    var body: some View {
        Button("Rename", action: rename)
        if !chat.isClosed, let project = model.project(withID: chat.projectId) {
            Button("Mark as done") { Task { await model.closeRequest(chat, as: .done, in: project) } }
            Button("Drop chat") { Task { await model.closeRequest(chat, as: .dropped, in: project) } }
        } else {
            Button("Reopen") { model.reopenChat(chat) }
        }
        Divider()
        Button("Copy link to chat") { model.copyChatLink(chat) }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingChatDeletion = chat }
    }
}

private struct ClosedChatRow: View {
    @Environment(AppModel.self) private var model
    let summary: ChatSummary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.openChat(summary.chat) } label: {
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
                Button("Reopen") { model.reopenChat(summary.chat) }
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
    let workers: [Agent]
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        if !workers.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    ForEach(workers.prefix(3), id: \.id) { agent in
                        AgentAvatar(size: size, appearance: RoleAppearance(role: model.role(for: agent, in: project)), isFailing: agent.status == .failed)
                            .background(Tokens.side, in: .rect(cornerRadius: size * 0.33))
                            .help(model.displayName(of: agent, in: project))
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
