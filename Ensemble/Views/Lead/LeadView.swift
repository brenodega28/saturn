import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if let session = model.directChatSession(in: project) {
            DirectChatView(session: session, project: project)
                .id(session.id)
        } else {
            leadChat
        }
    }

    @ViewBuilder
    private var leadChat: some View {
        let requests = model.leadRequests(in: project)
        let selected = model.selectedRequest(in: project)
        GeometryReader { proxy in
            let showsList = !requests.isEmpty && proxy.size.width >= 860
            HStack(alignment: .top, spacing: 18) {
                if showsList {
                    LeadRequestList(project: project, requests: requests, selectedID: selected?.id)
                        .frame(width: 236)
                }
                VStack(spacing: 14) {
                    if !showsList, !requests.isEmpty {
                        CompactRequestPicker(project: project, requests: requests, selected: selected)
                    }
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
    }
}

private struct LeadRequestList: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let requests: [ProjectTask]
    let selectedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.startNewLeadRequest(in: project)
            } label: {
                Label("New request", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .help("Start a new conversation with the lead")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(requests) { request in
                        row(request)
                    }
                }
            }
        }
    }

    private func row(_ request: ProjectTask) -> some View {
        let isSelected = request.id == selectedID
        let run = model.latestRun(of: request)
        let detail = run.map { run in
            let state = run.isActive ? (model.currentStepTitle(of: run) ?? run.status.label) : run.status.label
            return "\(state) · \(run.costUSD.formatted(.currency(code: "USD")))"
        } ?? "Chat"
        return Button {
            model.showRequest(request)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(run?.status.color ?? Theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title.isEmpty ? "Request #\(request.id ?? 0)" : request.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.22) : Color.clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(request.title), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                EmptyState("No lead role", message: "A lead is a role with can_spawn: true. Add one in Settings › Roles, or pick a workflow that needs no lead.")
            } else {
                EmptyState("Talk to an agent", message: "Ask a question or describe what you need. The lead answers here, and proposes a run when there’s work to do.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompactRequestPicker: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let requests: [ProjectTask]
    let selected: ProjectTask?

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(requests) { request in
                    Button(request.title) { model.showRequest(request) }
                }
            } label: {
                Label(selected?.title ?? "Requests", systemImage: "list.bullet")
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.startNewLeadRequest(in: project)
            } label: {
                Label("New request", systemImage: "plus")
            }
            .buttonStyle(.pill)
            .fixedSize()
        }
    }
}
