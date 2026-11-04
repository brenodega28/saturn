import EnsembleCore
import EnsembleUI
import SwiftUI

struct DirectChatView: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    @State private var sendCount = 0

    var body: some View {
        let role = model.role(for: session.agent, in: project)
        let name = model.displayName(of: session.agent, in: project)
        let messages = model.directMessages(with: session)
        let isWaitingForReply = messages.contains(where: \.awaitingReply) && (session.isRunning || session.isQueued)
        let held = model.heldSends(for: .direct(session.id))
        let userMessageCount = messages.count { $0.kind == .user }
        VStack(spacing: 14) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    DirectAgentCard(session: session, project: project, role: role)
                    Text(scopeNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    ForEach(messages) { message in
                        bubble(message, role: role, name: name)
                            .id(message.id)
                    }
                    ForEach(held) { send in
                        RequestBubble(held: send, onCancel: model.cancelHeldSend)
                            .id(send.id)
                    }
                    if isWaitingForReply {
                        ThinkingRow(role: role, name: name, session: session)
                    } else if session.agent.status == .failed, messages.contains(where: \.awaitingReply) {
                        FailedReplyRow(name: name, error: session.agent.lastError)
                            .padding(.leading, 42)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.top, for: .alignment)
            .followsBottom(
                of: FollowSignature(
                    messages: messages.map(\.id),
                    held: held.map(\.id),
                    isWaitingForReply: isWaitingForReply,
                    entry: isWaitingForReply ? session.transcript.liveEntry ?? session.transcript.entries.last : nil
                ),
                jumpingOn: sendCount,
                releasingOn: false
            )
            .onChange(of: held.map(\.id)) { old, new in
                if new.contains(where: { !old.contains($0) }) { sendCount += 1 }
            }
            .onChange(of: userMessageCount) { old, new in
                if new > old { sendCount += 1 }
            }
            DirectComposer(session: session, project: project)
                .frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct FollowSignature: Equatable {
        let messages: [Int64?]
        let held: [UUID]
        let isWaitingForReply: Bool
        let entry: TranscriptEntry?
    }

    private var scopeNote: String {
        let name = model.displayName(of: session.agent, in: project)
        return session.agent.runId == nil
            ? "Direct messages go only to \(name). They don’t start a run."
            : "Direct messages go only to \(name). They don’t start a run; the lead sees a summary."
    }

    @ViewBuilder
    private func bubble(_ message: DirectMessage, role: RoleDefinition?, name: String) -> some View {
        switch message.kind {
        case .user:
            RequestBubble(text: message.text, date: message.createdAt, attachments: message.storedAttachments)
        case .agent:
            LeadBubble(role: role, name: name, date: message.createdAt) {
                ChatText(message.text)
            }
        }
    }

}

private struct DirectAgentCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    let role: RoleDefinition?

    var body: some View {
        let agent = session.agent
        let status = model.displayStatus(of: agent)
        HStack(alignment: .center, spacing: 12) {
            AgentAvatar(size: 36, appearance: RoleAppearance(role: role))
            VStack(alignment: .leading, spacing: 2) {
                (Text(model.displayName(of: agent, in: project)).fontWeight(.semibold) + Text(" · \(role?.name ?? agent.role) · \(agent.model)").foregroundStyle(Theme.secondaryText))
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
                StatusDot(status.color)
                Text(status.label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.color)
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
    @State private var attachments: [ChatAttachment] = []
    @State private var isDropTargeted = false

    var body: some View {
        let sendTarget = PendingSendTarget.direct(session.id)
        composer
            .cancelsHeldSendOnEscape(for: sendTarget)
            .restoresReturnedSends(for: sendTarget, perform: restore)
    }

    private var composer: some View {
        let name = model.displayName(of: session.agent, in: project)
        return VStack(alignment: .leading, spacing: 10) {
            ChatComposerInput(
                text: $text,
                attachments: $attachments,
                isDropTargeted: $isDropTargeted,
                placeholder: "Message \(name)…",
                accessibilityLabel: "Message to \(name)",
                onSubmit: send
            )
            HStack(spacing: 8) {
                ChatRecipientChip(name: name, appearance: RoleAppearance(role: model.role(for: session.agent, in: project)))
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
        .chatAttachmentDrop($attachments, isTargeted: $isDropTargeted)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
        let message = PendingMessage(text: text, attachments: attachments)
        text = ""
        attachments = []
        model.holdDirectMessage(message, to: session)
    }

    private func restore(_ message: PendingMessage) {
        let merged = PendingMessage(text: text, attachments: attachments).appending(message)
        text = merged.text
        attachments = merged.attachments
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

struct ChatRecipientChip: View {
    let name: String
    let appearance: RoleAppearance

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatar(size: 22, appearance: appearance)
            Text("To \(name)").font(.system(size: 12)).lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
