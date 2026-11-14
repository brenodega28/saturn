import EnsembleCore
import EnsembleUI
import SwiftUI

extension PermissionCardStatus {
    var title: String {
        switch self {
        case .pending: "Waiting for you"
        case .allowed: "Allowed for this chat"
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
        case .gitPush, .riskyCommands: Color(hex: 0xFF8A80)
        }
    }
}

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let card: LeadMessage
    let project: Project
    @State private var agent: Agent?
    @State private var rules: [String] = []

    var body: some View {
        let name = agent.map { model.displayName(of: $0, in: project) } ?? card.title ?? "An agent"
        let status = card.permissionStatus ?? .pending
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text("Permission").fontWeight(.semibold).foregroundStyle(Tokens.need)) · \(name) \(request)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.text)
                    .font(Tokens.mono(12.5))
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Tokens.code, in: .rect(cornerRadius: 8, style: .continuous))
                if !rules.isEmpty {
                    Text("Covers \(rules.map { "`\($0)`" }.joined(separator: ", "))")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason {
                    Text(reason)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if status == .pending {
                    HStack(spacing: 8) {
                        Button("Allow in this chat") { model.answerPermission(card, decision: .allow) }
                            .buttonStyle(PrimaryPillStyle())
                            .help("Let the lead and every worker in this chat run this and similar commands without asking again")
                        Button("Deny") { model.answerPermission(card, decision: .deny) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.danger)
                            .font(.system(size: 13.5))
                            .padding(.horizontal, 8)
                            .help("Tell the agent to find another way; similar commands stay denied in this chat")
                    }
                } else {
                    Text(status.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(status == .denied ? Tokens.stuck : Tokens.done)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.needBackground, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.needLine))
        }
        .task(id: card.permissionRequestId) {
            let request = card.permissionRequestId.flatMap { try? model.database.permissionRequest(id: $0) }
            rules = request?.rules ?? []
            agent = request.flatMap { try? model.database.agent(id: $0.agentId) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission request from \(name)")
    }

    private var request: String {
        guard let capability = card.capability else { return "asks for permission" }
        return "wants to \(capability.describe(card.text))"
    }

    private var reason: String? {
        guard let capability = card.capability else { return nil }
        let run = card.runId.flatMap(model.run(withID:))?.displayTitle
        return ["Needs your OK: \(capability.title.lowercased()).", run.map { "Run: \($0)." }].compactMap(\.self).joined(separator: " ")
    }
}

struct SpecCard: View {
    @Environment(AppModel.self) private var model
    let spec: SpecFile
    let document: SpecDocument
    let proposal: LeadMessage
    let project: Project
    let canStart: Bool
    let startHelp: String

    var body: some View {
        let state = Phase(proposal.status, rejected: document.status == .rejected)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Spec · \(document.title)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                Text(badge(state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(state.background, in: Capsule())
                    .fixedSize()
                Spacer(minLength: 8)
                if let path = spec.relativePath {
                    Text(path).font(Tokens.mono(11.5)).foregroundStyle(Tokens.text2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            .padding(.bottom, 6)
            ForEach(rows, id: \.title) { row in
                HStack(alignment: .top, spacing: 14) {
                    Text(row.title).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(row.isMonospaced ? Tokens.mono(12.5) : .system(size: 14))
                                .foregroundStyle(Tokens.text)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
            }
            if !document.workers.isEmpty {
                HStack(spacing: 10) {
                    Text(state == .approved ? "Started" : "On approval I’ll start").foregroundStyle(Tokens.text2)
                    HStack(spacing: -5) {
                        ForEach(Array(document.workers.prefix(4).enumerated()), id: \.offset) { _, worker in
                            RobotFace(kind: RobotFace.Kind(icon: model.config(for: project).role(worker.role)?.icon ?? worker.role), size: 18)
                                .background(Tokens.raised, in: .rect(cornerRadius: 6))
                        }
                    }
                    Text(ListFormatter.localizedString(byJoining: document.workers.map(\.name))).foregroundStyle(Tokens.text).lineLimit(2)
                }
                .font(.system(size: 13))
                .padding(.top, 10)
                .padding(.bottom, 2)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1).padding(.top, 4) }
            }
            HStack(spacing: 8) {
                switch state {
                case .pending:
                    Button("Approve & start") { model.startProposal(proposal, in: project) }
                        .buttonStyle(PrimaryPillStyle())
                        .disabled(!canStart)
                        .help(startHelp)
                    Button("Edit first") { model.openSpec(spec, in: project) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Open the spec to edit it; the Lead reads your edits before it starts anyone")
                    Button("Reject…") { model.rejectProposal(proposal) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.danger)
                        .font(.system(size: 13.5))
                        .padding(.horizontal, 8)
                        .help("Reject this spec; tell the Lead why in your next message")
                case .approved:
                    statusPill("Approved · \(document.workers.count) worker\(document.workers.count == 1 ? "" : "s") starting", color: Tokens.done, background: Tokens.doneBackground)
                    Button("View spec") { model.openSpec(spec, in: project) }.buttonStyle(.plain).foregroundStyle(Tokens.link)
                case .rejected:
                    Text("Rejected by you · tell the Lead why in your next message").font(.system(size: 13)).foregroundStyle(Tokens.text2)
                case .dismissed:
                    statusPill("Dismissed", color: Tokens.text2, background: Tokens.fill)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .background(Tokens.raised, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.hair2))
        .opacity(state == .rejected ? 0.6 : 1)
        .contextMenu {
            Button("Open Spec") { model.openSpec(spec, in: project) }
            if state == .pending {
                Button("Dismiss Proposal") { model.dismissProposal(proposal) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spec \(document.title)")
    }

    private func statusPill(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(background, in: Capsule())
    }

    private enum Phase {
        case pending
        case approved
        case dismissed
        case rejected

        init(_ status: ProposalStatus?, rejected: Bool) {
            if rejected { self = .rejected; return }
            switch status {
            case .started: self = .approved
            case .dismissed: self = .dismissed
            default: self = .pending
            }
        }

        var color: Color {
            switch self {
            case .pending: Tokens.need
            case .approved: Tokens.done
            case .dismissed, .rejected: Tokens.text2
            }
        }

        var background: Color {
            switch self {
            case .pending: Tokens.needBackground
            case .approved: Tokens.doneBackground
            case .dismissed, .rejected: Tokens.fill
            }
        }
    }

    private func badge(_ state: Phase) -> String {
        switch state {
        case .pending: "v\(document.version) · needs approval"
        case .approved: "v\(document.version) · approved"
        case .dismissed: "v\(document.version) · dismissed"
        case .rejected: "v\(document.version) · rejected"
        }
    }

    private struct Row {
        let title: String
        let lines: [String]
        var isMonospaced = false
    }

    private var rows: [Row] {
        let files = document.extraSections.first { $0.heading.localizedCaseInsensitiveCompare("Files") == .orderedSame }.map { Self.lines(of: $0.body) } ?? []
        return [
            Row(title: "Files", lines: files, isMonospaced: true),
            Row(title: "Interface", lines: document.interfaces, isMonospaced: true),
            Row(title: "Out of scope", lines: document.outOfScope),
            Row(title: "Done when", lines: document.acceptanceCriteria.map(\.text)),
            Row(title: "Verify", lines: Self.lines(of: document.verification), isMonospaced: true),
        ].filter { !$0.lines.isEmpty }
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }
}

struct NoPlanPill: View {
    var body: some View {
        Text("No plan needed")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Tokens.done)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Tokens.doneBackground, in: Capsule())
    }
}
