import EnsembleCore
import EnsembleUI
import SwiftUI

struct InboxItemCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.kind.tint)
                    .accessibilityHidden(true)
                Text(InboxNotifier.kindTitle(item.kind))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.kind.tint)
                if let runTitle = model.runTitle(for: item), !runTitle.isEmpty {
                    Text("· \(runTitle)").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer()
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: 760, alignment: .leading)
        .card(cornerRadius: 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        switch item.kind {
        case .question:
            HStack(spacing: 8) {
                TextField("Reply…", text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("Answer to \(item.title)")
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(PillButtonStyle(.primary, height: 28))
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(item.agentId == nil ? "Answer and close this question" : "Send the answer to the agent that asked")
            }
        case .notice:
            HStack {
                Spacer()
                Button("Dismiss") { model.dismissInboxItem(item) }
                    .buttonStyle(PillButtonStyle(height: 28))
                    .help("Remove this notice from the Inbox")
            }
        case .pinReview:
            openButton(help: "Review the pins in the Changes tab")
        case .planApproval, .approval, .loopLimit, .budget, .failure:
            openButton(help: "Decide in the project’s Lead tab")
        }
    }

    private func openButton(help: String) -> some View {
        HStack {
            Spacer()
            Button("Open") { model.openInboxItem(item) }
                .buttonStyle(PillButtonStyle(.primary, height: 28))
                .help(help)
        }
    }

    private func send() {
        let text = reply
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.answerInboxQuestion(item: item, text: text)
        reply = ""
    }
}

extension InboxKind {
    var symbol: String {
        switch self {
        case .question: "questionmark.bubble"
        case .planApproval: "list.bullet.clipboard"
        case .pinReview: "pin"
        case .approval: "checkmark.seal"
        case .failure: "exclamationmark.triangle"
        case .notice: "info.circle"
        case .loopLimit: "arrow.triangle.2.circlepath"
        case .budget: "dollarsign.circle"
        }
    }

    var tint: Color {
        switch self {
        case .question, .planApproval, .approval: Theme.warning
        case .pinReview: Theme.info
        case .failure, .budget, .loopLimit: Theme.danger
        case .notice: Theme.neutral
        }
    }
}
