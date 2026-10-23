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
        let requests = LeadRequest.partition(model.leadRequests(in: project))
        let hasRequests = !requests.open.isEmpty || !requests.closed.isEmpty
        let selected = model.selectedRequest(in: project)
        GeometryReader { proxy in
            let showsList = hasRequests && proxy.size.width >= 860
            HStack(alignment: .top, spacing: 18) {
                if showsList {
                    LeadRequestList(project: project, open: requests.open, closed: requests.closed, selectedID: selected?.id)
                        .frame(width: 236)
                }
                VStack(spacing: 14) {
                    if !showsList, hasRequests {
                        CompactRequestPicker(project: project, open: requests.open, closed: requests.closed, selected: selected)
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
    let open: [ProjectTask]
    let closed: [ProjectTask]
    let selectedID: Int64?
    @State private var showsClosed = false

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
                    ForEach(open) { request in
                        row(request)
                    }
                    if !closed.isEmpty {
                        closedToggle
                        if showsClosed {
                            ForEach(closed) { request in
                                row(request)
                            }
                        }
                    }
                }
            }
        }
    }

    private var closedToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsClosed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(showsClosed ? 90 : 0))
                    .accessibilityHidden(true)
                Text("Closed").font(.system(size: 12, weight: .semibold))
                Text("\(closed.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(showsClosed ? "Hide closed requests" : "Show closed requests")
        .accessibilityLabel("Closed requests, \(closed.count)")
        .accessibilityValue(showsClosed ? "Expanded" : "Collapsed")
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
                if let reason = request.closeReason {
                    CloseReasonBadge(reason: reason)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.22) : Color.clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
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
        .accessibilityLabel([request.title, detail, request.closeReason.map { "Closed as \($0.title)" }].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let open: [ProjectTask]
    let closed: [ProjectTask]
    let selected: ProjectTask?

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(open) { request in
                    Button(request.title) { model.showRequest(request) }
                }
                if !closed.isEmpty {
                    Divider()
                    Menu("Closed (\(closed.count))") {
                        ForEach(closed) { request in
                            Button([request.title, request.closeReason?.title].compactMap(\.self).joined(separator: " · ")) { model.showRequest(request) }
                        }
                    }
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
