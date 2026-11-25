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
    @Environment(DaemonWorkspace.self) private var workspace
    let card: LeadMessage
    let project: Project
    @State private var agent: Agent?
    @State private var rules: [String] = []

    var body: some View {
        let name = agent.map { workspace.displayName(of: $0, in: project) } ?? card.title ?? "An agent"
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
                        Button("Allow in this chat") { workspace.answerPermission(card, decision: .allow) }
                            .buttonStyle(PrimaryPillStyle())
                            .help("Let the lead and every worker in this chat run this and similar commands without asking again")
                        Button("Deny") { workspace.answerPermission(card, decision: .deny) }
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
            let request = card.permissionRequestId.flatMap { try? workspace.database.permissionRequest(id: $0) }
            rules = request?.rules ?? []
            agent = request.flatMap { try? workspace.database.agent(id: $0.agentId) }
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
        let run = card.runId.flatMap(workspace.run(withID:))?.displayTitle
        return ["Needs your OK: \(capability.title.lowercased()).", run.map { "Run: \($0)." }].compactMap(\.self).joined(separator: " ")
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
