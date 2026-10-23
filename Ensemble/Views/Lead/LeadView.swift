import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if model.isShowingRequestPage(in: project) {
            RequestListView(project: project)
        } else if let session = model.directChatSession(in: project) {
            DirectChatView(session: session, project: project)
                .id(session.id)
        } else {
            leadChat
        }
    }

    @ViewBuilder
    private var leadChat: some View {
        let selected = model.selectedRequest(in: project)
        VStack(spacing: 14) {
            LeadChatHeader(project: project, request: selected)
            if let selected {
                RequestChat(task: selected, project: project)
                    .id(selected.id)
            } else {
                NewRequestIntro(project: project)
            }
            LeadComposer(project: project, request: selected)
                .frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LeadChatHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let request: ProjectTask?

    var body: some View {
        let title = request.map { $0.title.isEmpty ? "Request #\($0.id ?? 0)" : $0.title } ?? "New request"
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if let reason = request?.closeReason {
                CloseReasonBadge(reason: reason)
            }
            Spacer(minLength: 8)
            Button {
                model.startNewLeadRequest(in: project)
            } label: {
                Label("New request", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(height: 26))
            .fixedSize()
            .help("Start a new conversation with the lead")
        }
    }
}

struct RequestCloseMenu: View {
    @Environment(AppModel.self) private var model
    let request: ProjectTask
    let project: Project

    var body: some View {
        if !request.isClosed {
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

private struct NewRequestIntro: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let config = model.config(for: project)
        Group {
            if config.workflows.isEmpty {
                EmptyState("No workflows yet", message: "The lead starts a workflow from .ensemble/workflows/. Add the defaults to get Feature delivery and Small task.") {
                    Button("Add Default Roles and Workflows") { model.installDefaultConfig(in: project) }
                        .buttonStyle(.primaryPill)
                }
            } else if model.leadRoles(in: project).isEmpty {
                EmptyState("No lead role", message: "A lead is a role with can_spawn: true. Add one in Crew › Roles, or pick a workflow that needs no lead.")
            } else {
                EmptyState("Talk to an agent", message: "Ask a question or describe what you need. The lead answers here, and proposes a run when there’s work to do.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
