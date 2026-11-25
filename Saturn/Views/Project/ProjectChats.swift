import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectChats: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var filter: ChatGroup?
    @State private var text = ""

    var body: some View {
        let chats = workspace.chatSummaries(in: project)
        let groups = ChatGroup.grouped(chats.open + chats.closed, stage: \.stage, lastActivity: \.lastActivity)
        VStack(alignment: .leading, spacing: 18) {
            heading
            HStack(spacing: 6) {
                chip(nil, count: ChatGroup.allCases.reduce(0) { $0 + (groups[$1]?.count ?? 0) })
                ForEach(ChatGroup.allCases, id: \.self) { group in
                    chip(group, count: groups[group]?.count ?? 0)
                }
                Spacer(minLength: 12)
                filterField
            }
            ChatTable(groups: visible(groups))
        }
    }

    private var heading: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chats").font(.system(size: 22, weight: .semibold)).tracking(-0.3).accessibilityAddTraits(.isHeader)
                Text("Every chat in \(project.name). Each one has a Lead, its own workers and its own branch.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text2)
            }
            Spacer()
            Button { workspace.startNewChat(in: project) } label: { Label("New chat", systemImage: "square.and.pencil") }
                .buttonStyle(SmallPillStyle(isPrimary: true))
        }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            TextField("Filter chats", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text)
        }
        .foregroundStyle(Tokens.text2)
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(Tokens.fill, in: .rect(cornerRadius: 9, style: .continuous))
    }

    private func chip(_ group: ChatGroup?, count: Int) -> some View {
        let isOn = filter == group
        return Button { filter = group } label: {
            HStack(spacing: 6) {
                Text(group?.title ?? "All")
                Text("\(count)").foregroundStyle(Tokens.text3)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(isOn ? Tokens.accent : Tokens.text2)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(isOn ? Tokens.selection : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Tokens.accent.opacity(0.34) : Tokens.hair2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    private func visible(_ groups: [ChatGroup: [ChatSummary]]) -> [(group: ChatGroup, chats: [ChatSummary])] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return ChatGroup.allCases.compactMap { group in
            guard filter == nil || filter == group else { return nil }
            let chats = (groups[group] ?? []).filter { needle.isEmpty || $0.chat.title.localizedCaseInsensitiveContains(needle) || $0.chat.body.localizedCaseInsensitiveContains(needle) }
            return chats.isEmpty ? nil : (group, chats)
        }
    }
}

private enum ChatTableWidth {
    static let status: CGFloat = 130
    static let workers: CGFloat = 110
    static let branch: CGFloat = 120
    static let changes: CGFloat = 110
    static let updated: CGFloat = 80
}

private struct ChatTable: View {
    let groups: [(group: ChatGroup, chats: [ChatSummary])]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Status").frame(width: ChatTableWidth.status, alignment: .leading)
                Text("Chat").frame(maxWidth: .infinity, alignment: .leading)
                Text("Workers").frame(width: ChatTableWidth.workers, alignment: .leading)
                Text("Branch").frame(width: ChatTableWidth.branch, alignment: .leading)
                Text("Changes").frame(width: ChatTableWidth.changes, alignment: .leading)
                Text("Updated").frame(width: ChatTableWidth.updated, alignment: .trailing)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
            if groups.isEmpty {
                Text("No chats match.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text2)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            ForEach(Array(groups.enumerated()), id: \.element.group) { index, entry in
                if index > 0 { Rectangle().fill(Tokens.hair).frame(height: 1) }
                HStack(spacing: 5) {
                    Text(entry.group.title).foregroundStyle(entry.group.tableColor)
                    Text("\(entry.chats.count)").fontWeight(.regular).foregroundStyle(Tokens.text3)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))
                .accessibilityAddTraits(.isHeader)
                ForEach(entry.chats) { summary in
                    ChatTableRow(summary: summary)
                }
            }
        }
        .projectCard()
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }
}

private struct ChatTableRow: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let summary: ChatSummary
    @State private var diff: DiffInfo?
    @State private var isHovered = false

    var body: some View {
        let run = workspace.latestRun(of: summary.chat)
        Button { workspace.openChat(summary.chat) } label: {
            HStack(spacing: 12) {
                ChatStatusPill(stage: summary.stage).frame(width: ChatTableWidth.status, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.chat.title).font(.system(size: 13.5)).foregroundStyle(Tokens.text).lineLimit(1)
                    Text(workspace.subtitle(of: summary)).font(.system(size: 12)).foregroundStyle(Tokens.text2).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WorkerStack(workers: summary.workers, project: summary.project, size: 20)
                    .padding(.leading, 6)
                    .frame(width: ChatTableWidth.workers, alignment: .leading)
                Text(workspace.branch(of: summary) ?? "—")
                    .font(Tokens.mono(11.5))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: ChatTableWidth.branch, alignment: .leading)
                changes.frame(width: ChatTableWidth.changes, alignment: .leading)
                Text(ChatTime.label(summary.lastActivity))
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text3)
                    .frame(width: ChatTableWidth.updated, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: 50)
            .background(isHovered ? Tokens.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { ChatRowMenu(chat: summary.chat, rename: {}) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.chat.title), \(summary.stage.title)")
        .task(id: run.map { "\($0.id ?? 0)-\($0.status.rawValue)-\($0.currentStep ?? "")" } ?? "none") {
            diff = if let run { await workspace.diffInfo(run) } else { nil }
        }
    }

    @ViewBuilder
    private var changes: some View {
        if let diff, diff.lines > 0 {
            HStack(spacing: 6) {
                Text("+\(diff.added.formatted())").foregroundStyle(Tokens.done)
                Text("−\(diff.deleted.formatted())").foregroundStyle(Tokens.danger)
            }
            .font(Tokens.mono(12))
        } else {
            Text("")
        }
    }
}

private struct ChatStatusPill: View {
    let stage: ChatStage

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(stage.color).frame(width: 6, height: 6)
            Text(stage == .stuck ? "Stuck" : stage == .idle ? "Not started" : stage.title).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(stage.color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(stage.background, in: Capsule())
    }
}

private extension ChatGroup {
    var tableColor: Color {
        switch self {
        case .needsYou: Tokens.need
        case .inProgress: Tokens.build
        case .notStarted: Tokens.idle
        case .finished: Tokens.done
        }
    }
}
