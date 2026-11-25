import SaturnCore
import SaturnUI
import SwiftUI

struct PinCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let pin: Pin
    let author: Agent?
    let appearance: RoleAppearance
    let compact: Bool
    let holdsApproval: Bool

    @State private var composer: Composer?
    @State private var draft = ""
    @State private var confirmation: String?
    @State private var isEditingComment = false

    enum Composer {
        case requestChange
        case ask
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if pin.byUser && isEditingComment {
                LineCommentComposer(
                    text: pin.response ?? pin.explanation,
                    saveTitle: "Save",
                    onSave: { text in
                        workspace.editComment(pin, text: text)
                        isEditingComment = false
                    },
                    onCancel: { isEditingComment = false }
                )
            } else {
                Text(pin.explanation)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !pin.byUser, pin.status == .changeRequested, let response = pin.response, !response.isEmpty {
                Label(response, systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pin.byUser {
                commentActions
            } else {
                actions
            }
            if let composer {
                composerView(composer)
            }
            if let confirmation {
                Label(confirmation, systemImage: "paperplane")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 760, alignment: .leading)
        .background(DiffPalette.pinCard, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DiffPalette.pinLine))
        .padding(EdgeInsets(top: 6, leading: 64, bottom: 8, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fontDesign(.default)
        .textSelection(.disabled)
    }

    private var authorName: String { author?.name ?? "an agent" }
    private var authorStep: String? { author?.step }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                titleRow
                Spacer(minLength: 8)
                byline
            }
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                byline
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            AgentAvatar(size: 22, appearance: pin.byUser ? .reviewer : appearance).shadow(radius: 0)
            Text(pin.title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Tokens.text)
            if !compact {
                ForEach(pin.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.review)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DiffPalette.pin.opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private var byline: some View {
        HStack(spacing: 6) {
            Text(pin.byUser ? "Comment by you · lines \(pin.sideLineLabel)" : "Pinned by \(authorName) · lines \(pin.sideLineLabel)")
        }
        .font(.system(size: 12))
        .foregroundStyle(Tokens.text2)
    }

    private var commentActions: some View {
        HStack(spacing: 8) {
            changeRequestedTag
            if !isEditingComment {
                Button("Edit") {
                    confirmation = nil
                    isEditingComment = true
                }
                .buttonStyle(PillButtonStyle(height: 30))
                .help("Change the text of your comment")
            }
            Button("Delete") { workspace.deleteComment(pin) }
                .buttonStyle(PillButtonStyle(height: 30))
                .help("Withdraw this comment")
            if let author {
                Text(holdsApproval ? "Goes to \(author.name) when you send changes back" : "Goes to \(author.name) when the run reaches your approval")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12.5))
    }

    private var changeRequestedTag: some View {
        Text("Change requested")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.warning.opacity(0.15), in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch pin.status {
            case .approved:
                Label("Approved by you", systemImage: "checkmark")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.successText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.success.opacity(0.15), in: Capsule())
            case .open, .changeRequested:
                Button("Looks right") {
                    workspace.setPin(pin, status: .approved)
                    composer = nil
                }
                .buttonStyle(PinPrimaryButtonStyle())
                .help("Approve this pin")
            }
            if pin.status == .changeRequested {
                changeRequestedTag
            }
            Button(requestTitle) { toggle(.requestChange) }
                .buttonStyle(PillButtonStyle(height: 30))
                .help("Sends this back to the author’s step in the workflow when the run reaches your approval")
            if !compact {
                Button("Ask \(authorName)") { toggle(.ask) }
                    .buttonStyle(PillButtonStyle(height: 30))
                    .disabled(author == nil)
                    .help(author == nil ? "The agent that made this pin is gone" : "Send \(authorName) a question about this pin")
            }
        }
        .font(.system(size: 12.5))
    }

    private var requestTitle: String {
        let target = [authorName, authorStep.map(\.capitalized)].compactMap(\.self).joined(separator: " · ")
        return "Request change → \(target)"
    }

    private func composerView(_ composer: Composer) -> some View {
        HStack(spacing: 8) {
            TextField(composer == .ask ? "Ask \(authorName) about this…" : "What should change?", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Tokens.window, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
                .onSubmit { submit(composer) }
            Button(composer == .ask ? "Send" : "Request change") { submit(composer) }
                .buttonStyle(PillButtonStyle(.primary, height: 30))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer == .ask)
            Button("Cancel") { self.composer = nil }
                .buttonStyle(PillButtonStyle(height: 30))
        }
    }

    private func toggle(_ target: Composer) {
        confirmation = nil
        if composer == target {
            composer = nil
        } else {
            composer = target
            draft = target == .requestChange ? (pin.response ?? "") : ""
        }
    }

    private func submit(_ composer: Composer) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch composer {
        case .requestChange:
            workspace.setPin(pin, status: .changeRequested, response: text.isEmpty ? nil : text)
            confirmation = holdsApproval ? nil : "Saved. It goes back to \(authorName) when the run reaches your approval."
        case .ask:
            guard !text.isEmpty else { return }
            confirmation = workspace.askAgent(about: pin, question: text) ? "Sent to \(authorName)." : "Couldn’t reach \(authorName)."
        }
        self.composer = nil
        draft = ""
    }
}

extension RoleAppearance {
    static let reviewer = RoleAppearance(palette: .neutral, symbol: "person.fill")
}

struct PinPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Tokens.primaryForeground)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Tokens.primaryBackground, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
