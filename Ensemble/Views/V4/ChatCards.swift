import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadAvatar: View {
    var appearance: RoleAppearance?
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3, style: .continuous)
            .fill(appearance.map { AnyShapeStyle($0.palette.gradient) } ?? AnyShapeStyle(V4.leadGradient))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

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
            LeadAvatar(appearance: agent.map { RoleAppearance(role: model.role(for: $0, in: project)) })
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text("Permission").fontWeight(.semibold).foregroundStyle(V4.orangeText)) · \(name) \(request)")
                    .font(.system(size: 12))
                    .foregroundStyle(V4.label.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.text)
                    .font(V4.monospaced(12))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(V4.code, in: .rect(cornerRadius: 8, style: .continuous))
                if !rules.isEmpty {
                    Text("Covers \(rules.map { "`\($0)`" }.joined(separator: ", "))")
                        .font(.system(size: 12))
                        .foregroundStyle(V4.label.opacity(0.75))
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
                        Button("Allow") { model.answerPermission(card, decision: .allow) }
                            .buttonStyle(V4Pill(kind: .orange, height: 28, horizontalPadding: 12))
                            .help("Let the lead and every worker in this chat run this and similar commands without asking again")
                        Button("Deny") { model.answerPermission(card, decision: .deny) }
                            .buttonStyle(V4Pill(kind: .deny, height: 28, horizontalPadding: 12))
                            .help("Tell the agent to find another way; similar commands stay denied in this chat")
                    }
                } else {
                    Text(status.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(status == .denied ? V4.denied : V4.greenText)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V4.orange.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(V4.orange.opacity(0.35)))
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
        let state = Phase(proposal.status)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Spec · \(document.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let path = spec.relativePath {
                    Text(path)
                        .font(V4.monospaced(11))
                        .foregroundStyle(V4.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Text(badge(state))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state.badgeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(state.badgeBackground, in: Capsule())
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
            ForEach(rows, id: \.title) { row in
                HStack(alignment: .top, spacing: 14) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V4.secondary)
                        .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(row.isMonospaced ? V4.monospaced(12) : .system(size: 13))
                                .lineSpacing(row.isMonospaced ? 4 : 3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1) }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch state {
                case .pending:
                    Button("Edit spec") { model.openSpec(spec, in: project) }
                        .buttonStyle(V4Pill(kind: .secondary))
                        .help("Open the draft to read and edit it; the lead reads your edits on its next turn")
                    Button("Approve & start") { model.startProposal(proposal, in: project) }
                        .buttonStyle(V4Pill(kind: .primary, horizontalPadding: 16))
                        .disabled(!canStart)
                        .help(startHelp)
                case .approved:
                    Button("View spec") { model.openSpec(spec, in: project) }
                        .buttonStyle(V4Pill(kind: .quiet))
                    V4StatusPill(text: "Approved · run starting", foreground: V4.greenText, background: V4.green.opacity(0.15))
                case .dismissed:
                    V4StatusPill(text: "Dismissed", foreground: V4.secondary, background: Color.white.opacity(0.06))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        }
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(state.border))
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Open Spec") { model.openSpec(spec, in: project) }
            if state == .pending {
                Button("Dismiss Proposal") { model.dismissProposal(proposal) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spec \(document.title)")
    }

    private enum Phase {
        case pending
        case approved
        case dismissed

        init(_ status: ProposalStatus?) {
            switch status {
            case .started: self = .approved
            case .dismissed: self = .dismissed
            default: self = .pending
            }
        }

        var border: Color {
            switch self {
            case .pending: V4.orange.opacity(0.35)
            case .approved: V4.green.opacity(0.3)
            case .dismissed: Color.white.opacity(0.08)
            }
        }

        var badgeForeground: Color {
            switch self {
            case .pending: V4.orangeText
            case .approved: V4.greenText
            case .dismissed: V4.secondary
            }
        }

        var badgeBackground: Color {
            switch self {
            case .pending: V4.orange.opacity(0.18)
            case .approved: V4.green.opacity(0.15)
            case .dismissed: Color.white.opacity(0.06)
            }
        }
    }

    private func badge(_ state: Phase) -> String {
        switch state {
        case .pending: "\(document.status.title) · needs approval"
        case .approved: "Approved"
        case .dismissed: "Dismissed"
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
            .foregroundStyle(V4.greenText)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(V4.green.opacity(0.14), in: Capsule())
    }
}
