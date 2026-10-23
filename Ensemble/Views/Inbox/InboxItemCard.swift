import EnsembleCore
import EnsembleUI
import SwiftUI

struct InboxItemCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem

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
            if !item.body.isEmpty && item.kind != .question {
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
            QuestionFormView(form: QuestionForm(item: item), recipient: nil, compact: true) { reply in
                model.answerInboxQuestion(item: item, text: reply)
            }
            .id(item.id)
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
