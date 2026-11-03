import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadView: View {
    let project: Project

    var body: some View {
        ChatColumn(project: project)
    }
}

struct RequestCloseMenu: View {
    @Environment(AppModel.self) private var model
    let request: ProjectTask
    let project: Project

    var body: some View {
        Button("Copy Link") { model.copyLink(to: request) }
        if !request.isClosed {
            Divider()
            let hasActiveRun = model.requestHasActiveRun(request)
            ForEach(RequestCloseReason.allCases, id: \.self) { reason in
                Button("Close as \(reason.title)") {
                    Task { await model.closeRequest(request, as: reason, in: project) }
                }
                .disabled(hasActiveRun)
            }
            if hasActiveRun {
                Divider()
                Text(RequestCloseReason.blockedHelp)
            }
        }
    }
}

struct CloseReasonBadge: View {
    let reason: RequestCloseReason

    var body: some View {
        Chip(text: reason.title, foreground: reason.color, background: reason.color.opacity(0.14))
    }
}

extension RequestCloseReason {
    static let blockedHelp = "Finish or cancel the run before closing this request."

    var color: Color {
        switch self {
        case .done: Theme.successText
        case .dropped: Theme.neutral
        }
    }
}

struct NewRequestHeldSends: View {
    @Environment(AppModel.self) private var model
    let held: [HeldSend]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(held) { send in
                    RequestBubble(held: send, onCancel: model.cancelHeldSend)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 150, trailing: 28))
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NewRequestIntro: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let config = model.config(for: project)
        Group {
            if config.workflows.isEmpty {
                EmptyState("No workflows yet", message: "The lead starts a workflow from .ensemble/workflows/. Add the defaults to get Feature delivery and Small task.") {
                    Button("Add Default Workflows") { model.installDefaultConfig(in: project) }
                        .buttonStyle(.primaryPill)
                }
            } else {
                EmptyState("Talk to the Lead", message: "Ask a question or describe what you need. The Lead answers here, proposes a run when there’s work to do, then plans and reviews it.")
            }
        }
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
