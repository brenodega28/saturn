import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadComposer: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let request: ProjectTask?
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var isDropTargeted = false

    var body: some View {
        let lead = model.chatLeadRole(in: project)
        let leadName = request.flatMap { model.leadSession(for: $0).map { model.displayName(of: $0.agent, in: project) } } ?? lead?.name ?? "the lead"
        let sendTarget = model.leadSendTarget(for: request, in: project)
        composer(lead: lead, leadName: leadName)
            .cancelsHeldSendOnEscape(for: sendTarget)
            .restoresReturnedSends(for: sendTarget, perform: restore)
    }

    private func composer(lead: RoleDefinition?, leadName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatComposerInput(
                text: $text,
                attachments: $attachments,
                isDropTargeted: $isDropTargeted,
                placeholder: placeholder(leadName: leadName),
                accessibilityLabel: request == nil ? "New request for the lead" : "Message to \(leadName)",
                onSubmit: { send(lead: lead) }
            )
            HStack(spacing: 8) {
                ChatRecipientChip(name: lead?.name ?? leadName, appearance: RoleAppearance(role: lead))
                Spacer()
                Button(action: { send(lead: lead) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSend(lead: lead))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to \(leadName) (⌘↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 12))
        .background(Color(white: 0.19).opacity(0.7), in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .chatAttachmentDrop($attachments, isTargeted: $isDropTargeted)
    }

    private func placeholder(leadName: String) -> String {
        guard let request else { return "Ask or describe what you need. The lead replies and proposes a run when it’s time." }
        return request.isClosed ? "Send a message to reopen…" : "Message \(leadName)"
    }

    private func canSend(lead: RoleDefinition?) -> Bool {
        (lead != nil || request.flatMap(model.leadSession(for:)) != nil)
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send(lead: RoleDefinition?) {
        guard canSend(lead: lead) else { return }
        let message = PendingMessage(text: text, attachments: attachments)
        text = ""
        attachments = []
        model.holdLeadMessage(message, lead: lead, to: request, in: project)
    }

    private func restore(_ message: PendingMessage) {
        let merged = PendingMessage(text: text, attachments: attachments).appending(message)
        text = merged.text
        attachments = merged.attachments
    }
}
