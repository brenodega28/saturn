import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatRequestCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let item: ChatRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.kind.tint)
                    .accessibilityHidden(true)
                Text(RequestNotifier.kindTitle(item.kind))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.kind.tint)
                if let runTitle = workspace.runTitle(for: item), !runTitle.isEmpty {
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
            if item.status == .open {
                actions
            } else {
                Text(item.status == .answered ? "Done" : item.status == .expired ? "Expired" : "Dismissed")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: 760, alignment: .leading)
        .card(cornerRadius: 14)
        .opacity(item.status == .open ? 1 : 0.75)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack {
            Spacer()
            if item.kind == .pinReview {
                Button("Open in Changes") { workspace.openRequest(item) }
                    .buttonStyle(PillButtonStyle(height: 28))
                    .help("Review the pins in Changes")
            }
            Button("Dismiss") { workspace.dismissRequest(item) }
                .buttonStyle(PillButtonStyle(height: 28))
                .help("Mark this as handled")
        }
    }
}

extension ChatRequestKind {
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
        case .gate: "exclamationmark.shield"
        case .permission: "hand.raised"
        }
    }

    var tint: Color {
        switch self {
        case .question, .planApproval, .approval, .permission: Theme.warning
        case .pinReview: Theme.info
        case .failure, .budget, .loopLimit, .gate: Theme.danger
        case .notice: Theme.neutral
        }
    }
}
