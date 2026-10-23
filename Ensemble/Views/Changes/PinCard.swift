import EnsembleCore
import EnsembleUI
import SwiftUI

struct PinCard: View {
    @Environment(AppModel.self) private var model
    let pin: Pin
    let author: Agent?
    let appearance: RoleAppearance
    let compact: Bool
    let holdsApproval: Bool

    @State private var composer: Composer?
    @State private var draft = ""
    @State private var confirmation: String?

    enum Composer {
        case requestChange
        case ask
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(pin.explanation)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if pin.status == .changeRequested, let response = pin.response, !response.isEmpty {
                Label(response, systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
            if let composer {
                composerView(composer)
            }
            if let confirmation {
                Label(confirmation, systemImage: "paperplane")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 12 : 14)
        .frame(maxWidth: 760, alignment: .leading)
        .background(DiffPalette.pinCard, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DiffPalette.pin.opacity(0.35)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
        .padding(EdgeInsets(top: 12, leading: compact ? 70 : 52, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffPalette.pin.opacity(0.05))
        .overlay(alignment: .top) { Rectangle().fill(DiffPalette.pin.opacity(0.25)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DiffPalette.pin.opacity(0.25)).frame(height: 1) }
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
            Image(systemName: "pin.fill")
                .foregroundStyle(DiffPalette.pin)
                .accessibilityHidden(true)
            Text(pin.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DiffPalette.pinTitle)
            if !compact {
                ForEach(pin.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiffPalette.pinTitle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DiffPalette.pin.opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private var byline: some View {
        HStack(spacing: 6) {
            AgentAvatar(size: 18, appearance: appearance).shadow(radius: 0)
            Text("Pinned by \(authorName) · lines \(pin.lineLabel)")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
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
                    model.setPin(pin, status: .approved)
                    composer = nil
                }
                .buttonStyle(PinPrimaryButtonStyle())
                .help("Approve this pin")
            }
            if pin.status == .changeRequested {
                Text("Change requested")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.warning.opacity(0.15), in: Capsule())
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
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
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
            model.setPin(pin, status: .changeRequested, response: text.isEmpty ? nil : text)
            confirmation = holdsApproval ? nil : "Saved. It goes back to \(authorName) when the run reaches your approval."
        case .ask:
            guard !text.isEmpty else { return }
            confirmation = model.askAgent(about: pin, question: text) ? "Sent to \(authorName)." : "Couldn’t reach \(authorName)."
        }
        self.composer = nil
        draft = ""
    }
}

struct PinPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color(hex: 0x2A2300))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(DiffPalette.pin, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
