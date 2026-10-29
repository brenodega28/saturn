import EnsembleCore
import EnsembleUI
import SwiftUI

extension AppModel {
    func chatInspectorSubject(for item: EditorItem) -> InspectorSubject? {
        guard let project = project(of: item), let projectID = project.id, !isShowingRequestPage(in: project),
              directChatSession(in: project) == nil, let requestID = selectedRequest(in: project)?.id else { return nil }
        return .chat(project: projectID, request: requestID)
    }

    func permissionCards(forRequest requestID: Int64) -> [LeadMessage] {
        ((try? database.leadMessages(taskId: requestID)) ?? []).filter { $0.kind == .permission }
    }

    func revealChatInspector(in project: Project) {
        guard let projectID = project.id, let workbench = activeWorkbench,
              workbench.active == .section(.lead, in: projectID), !workbench.isShowing(.inspector) else { return }
        workbench.show(.inspector)
    }
}

struct ChatPermission: Identifiable {
    let card: LeadMessage
    let request: PermissionRequest?
    let agent: Agent?

    var id: Int64 { card.id ?? 0 }
    var isPending: Bool { card.permissionStatus == .pending }
    var answeredAt: Date { request?.answeredAt ?? card.createdAt }
}

struct ChatInspector: View {
    @Environment(AppModel.self) private var model
    let subject: InspectorSubject
    @State private var cards: [LeadMessage] = []
    @State private var permissions: [ChatPermission] = []
    @State private var spec: SpecFile?
    @State private var hasLoaded = false

    var body: some View {
        if case .chat(let projectID, let requestID) = subject, let project = model.project(withID: projectID) {
            VStack(alignment: .leading, spacing: 12) {
                PermissionRequestsSection(permissions: permissions, project: project)
                Divider().overlay(Theme.hairline)
                SpecfileSection(spec: spec, project: project, isLoading: !hasLoaded)
            }
            .task(id: subject) {
                hasLoaded = false
                while !Task.isCancelled {
                    reload(requestID)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onChange(of: model.leadChatRevision) { reload(requestID) }
        } else {
            Text("This request no longer exists.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func reload(_ requestID: Int64) {
        let latestCards = model.permissionCards(forRequest: requestID)
        if latestCards != cards || !hasLoaded {
            cards = latestCards
            permissions = latestCards.map { card in
                let request = card.permissionRequestId.flatMap { try? model.database.permissionRequest(id: $0) }
                return ChatPermission(card: card, request: request, agent: request.flatMap { try? model.database.agent(id: $0.agentId) })
            }
        }
        let latestSpec = (try? model.database.task(id: requestID)).flatMap(model.specDraft(for:))
        if latestSpec != spec { spec = latestSpec }
        hasLoaded = true
    }
}

private struct PermissionRequestsSection: View {
    let permissions: [ChatPermission]
    let project: Project

    var body: some View {
        let pending = permissions.filter(\.isPending)
        let answered = permissions.filter { !$0.isPending }.sorted { $0.answeredAt < $1.answeredAt }.suffix(6)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Permission requests").font(.system(size: 12, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !pending.isEmpty {
                    Text("\(pending.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xFF9A5C))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color(hex: 0xFF7A2F).opacity(0.2), in: .capsule)
                        .accessibilityLabel("\(pending.count) waiting")
                }
            }
            if permissions.isEmpty {
                Text("No agent in this chat has asked for permission.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pending.isEmpty {
                Text("Nothing waiting for you.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(pending) { permission in
                PendingPermissionCard(permission: permission, project: project)
            }
            ForEach(Array(answered)) { permission in
                AnsweredPermissionRow(permission: permission)
            }
        }
    }
}

private struct PendingPermissionCard: View {
    @Environment(AppModel.self) private var model
    let permission: ChatPermission
    let project: Project

    var body: some View {
        let card = permission.card
        let name = card.title ?? "Agent"
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AgentAvatar(size: 18, appearance: RoleAppearance(role: permission.agent.flatMap { model.role(for: $0, in: project) }))
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let capability = card.capability {
                    Chip(text: capability.title, foreground: capability.color, background: capability.color.opacity(0.16))
                }
            }
            Text(card.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x111114), in: .rect(cornerRadius: 7, style: .continuous))
            if let capability = card.capability {
                Text("\(name) asks to \(capability.describe(card.text)). This needs your OK to \(capability.title.lowercased()).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(context)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            HStack(spacing: 5) {
                Button("Allow once") { model.answerPermission(card, decision: .allowOnce) }
                    .buttonStyle(PillButtonStyle(.primary, height: 26))
                    .help("Let the agent run this exact command one more time")
                Button("Allow for this run") { model.answerPermission(card, decision: .allowForRun) }
                    .buttonStyle(PillButtonStyle(height: 26))
                    .help("Let every agent in this run use `\(PermissionPolicy.commandName(of: card.text))` until the run ends")
                Button("Deny") { model.answerPermission(card, decision: .deny) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(hex: 0xFF8A80))
                    .padding(.horizontal, 6)
                    .help("Tell the agent to find another way")
            }
            .font(.system(size: 11.5))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private var context: String {
        let run = permission.card.runId.flatMap(model.run(withID:))?.displayTitle
        return [run, permission.card.createdAt.formatted(.relative(presentation: .named))].compactMap(\.self).joined(separator: " · ")
    }
}

private struct AnsweredPermissionRow: View {
    let permission: ChatPermission

    var body: some View {
        let card = permission.card
        let isDenied = card.permissionStatus == .denied
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isDenied ? "✕" : "✓")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(isDenied ? Color(hex: 0xFF8A80) : Theme.successText)
                .accessibilityHidden(true)
            Text([card.permissionStatus?.title, card.title, card.text].compactMap(\.self).joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(permission.answeredAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SpecfileSection: View {
    @Environment(AppModel.self) private var model
    let spec: SpecFile?
    let project: Project
    let isLoading: Bool

    var body: some View {
        let document = spec?.document
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Specfile").font(.system(size: 12, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let status = document?.status {
                    Chip(text: status.title, foreground: status.color, background: status.color.opacity(0.16))
                }
            }
            if let spec {
                if let path = spec.relativePath {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let document {
                    sections(document)
                } else {
                    Text("Ensemble can’t read this spec. Open it to fix the front matter.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { model.openSpec(spec, in: project) } label: {
                    Text("Open in editor").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(height: 28))
                .font(.system(size: 12))
                .help(document?.status == .draft ? "Open the draft in the editor to read and edit it" : "Open the spec")
            } else if !isLoading {
                Text("This request has no spec yet. The lead writes one when the work needs it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func sections(_ document: SpecDocument) -> some View {
        SpecFact(title: "Title", lines: [document.title])
        if !document.summary.isEmpty {
            SpecFact(title: "Summary", lines: [document.summary])
        }
        if !document.interfaces.isEmpty {
            SpecFact(title: "Interfaces", lines: document.interfaces, isMonospaced: true)
        }
        if !document.outOfScope.isEmpty {
            SpecFact(title: "Out of scope", lines: document.outOfScope)
        }
        if !document.acceptanceCriteria.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                SpecFactTitle(title: "Acceptance criteria · \(document.checkedCount)/\(document.acceptanceCriteria.count)")
                ForEach(Array(document.acceptanceCriteria.enumerated()), id: \.offset) { _, criterion in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: criterion.checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10.5))
                            .foregroundStyle(criterion.checked ? Theme.successText : Theme.tertiaryText)
                            .accessibilityHidden(true)
                        Text(criterion.text)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(criterion.checked ? "Checked" : "Not checked")
                }
            }
        }
        if !document.verification.isEmpty {
            SpecFact(title: "Verification", lines: [document.verification])
        }
    }
}

private struct SpecFactTitle: View {
    let title: String

    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
    }
}

private struct SpecFact: View {
    let title: String
    let lines: [String]
    var isMonospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SpecFactTitle(title: title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: isMonospaced ? 11 : 11.5, design: isMonospaced ? .monospaced : .default))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension PermissionCardStatus {
    var title: String {
        switch self {
        case .pending: "Waiting for you"
        case .allowedOnce: "Allowed once"
        case .allowedForRun: "Allowed for this run"
        case .denied: "Denied"
        }
    }
}

extension PermissionCapability {
    var color: Color {
        switch self {
        case .editFiles: Theme.link
        case .runShell: Theme.paused
        case .network: Theme.info
        case .installPackages: Theme.warning
        case .gitPush: Color(hex: 0xFF8A80)
        }
    }
}
