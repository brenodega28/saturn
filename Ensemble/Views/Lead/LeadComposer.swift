import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadComposer: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let request: Chat?
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
        VStack(alignment: .leading, spacing: 8) {
            ChatComposerInput(
                text: $text,
                attachments: $attachments,
                isDropTargeted: $isDropTargeted,
                placeholder: placeholder(leadName: leadName),
                accessibilityLabel: request == nil ? "New request for the lead" : "Message \(leadName)",
                onSubmit: { send(lead: lead) }
            )
            HStack(spacing: 8) {
                Spacer()
                Button(action: { send(lead: lead) }) {
                    V4Icon(glyph: .send, size: 15, lineWidth: 2.4)
                        .frame(width: 34, height: 34)
                        .background(V4.blue, in: Circle())
                        .foregroundStyle(.white)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend(lead: lead))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to \(leadName) (⌘↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 12))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(red: 48 / 255, green: 48 / 255, blue: 54 / 255).opacity(0.86))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
        .chatAttachmentDrop($attachments, isTargeted: $isDropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message \(leadName)")
    }

    private func placeholder(leadName: String) -> String {
        if request?.isClosed == true { return "Send a message to reopen…" }
        return "Describe a change, or reply to \(leadName)…"
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
