import EnsembleCore
import EnsembleUI
import SwiftUI

struct DirectChatView: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project

    var body: some View {
        let role = model.role(for: session.agent, in: project)
        let messages = model.directMessages(with: session)
        let isWaitingForReply = messages.contains(where: \.awaitingReply) && (session.isRunning || session.isQueued)
        VStack(spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        DirectAgentCard(session: session, project: project, role: role)
                        Text(scopeNote)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        ForEach(messages) { message in
                            bubble(message, role: role)
                                .id(message.id)
                        }
                        if isWaitingForReply {
                            ThinkingRow(role: role, name: session.agent.name)
                                .id(Self.thinkingID)
                        } else if session.agent.status == .failed, messages.contains(where: \.awaitingReply) {
                            FailedReplyRow(name: session.agent.name, error: session.agent.lastError)
                                .padding(.leading, 42)
                        }
                    }
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: messages.last?.id) { scrollToEnd(proxy, waiting: isWaitingForReply, last: messages.last?.id) }
                .onChange(of: isWaitingForReply) { scrollToEnd(proxy, waiting: isWaitingForReply, last: messages.last?.id) }
            }
            DirectComposer(session: session, project: project)
                .frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let thinkingID: Int64 = -1

    private var scopeNote: String {
        let name = session.agent.name
        return session.agent.runId == nil
            ? "Direct messages go only to \(name). They don’t start a run."
            : "Direct messages go only to \(name). They don’t start a run; the lead sees a summary."
    }

    @ViewBuilder
    private func bubble(_ message: DirectMessage, role: RoleDefinition?) -> some View {
        switch message.kind {
        case .user:
            RequestBubble(text: message.text, date: message.createdAt)
        case .agent:
            LeadBubble(role: role, name: session.agent.name, date: message.createdAt) {
                ChatText(message.text)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, waiting: Bool, last: Int64?) {
        guard let target = waiting ? Self.thinkingID : last else { return }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: .bottom) }
    }
}

private struct DirectAgentCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    let role: RoleDefinition?

    var body: some View {
        let agent = session.agent
        HStack(alignment: .center, spacing: 12) {
            AgentAvatar(size: 36, appearance: RoleAppearance(role: role))
            VStack(alignment: .leading, spacing: 2) {
                (Text(agent.name).fontWeight(.semibold) + Text(" · \(role?.name ?? agent.role) · \(agent.model)").foregroundStyle(Theme.secondaryText))
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                if !agent.task.isEmpty {
                    Text(agent.task)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                Text(workspace(agent))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                StatusDot(agent.status.color)
                Text(agent.status.label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(agent.status.color)
            .fixedSize()
            Button("Open Session") { model.openAgentSession(agent, in: project) }
                .buttonStyle(.pill)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.fill, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func workspace(_ agent: Agent) -> String {
        let run = agent.runId.flatMap(model.liveRun(id:))
        let place = agent.branch.map { "worktree \($0)" } ?? "read-only"
        return [run.map { $0.title.isEmpty ? "Run #\($0.id ?? 0)" : $0.title }, place].compactMap(\.self).joined(separator: " · ")
    }
}

private struct DirectComposer: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    @State private var text = ""

    var body: some View {
        let name = session.agent.name
        VStack(alignment: .leading, spacing: 10) {
            TextField("Message", text: $text, prompt: Text("Message \(name)…"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...8)
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    send()
                    return .handled
                }
                .accessibilityLabel("Message to \(name)")
            HStack(spacing: 8) {
                ChatTargetPicker(project: project, style: .chip)
                Text("Direct message · no new run")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.fill, in: Capsule())
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to \(name) (⌘↩)")
                .accessibilityLabel("Send to \(name)")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 12))
        .background(Color(white: 0.19).opacity(0.7), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        if model.sendDirectMessage(text, to: session) {
            text = ""
        }
    }
}

private struct FailedReplyRow: View {
    let name: String
    let error: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) couldn’t reply").font(.system(size: 13, weight: .semibold))
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.danger.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
