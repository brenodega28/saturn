import SaturnCore
import SaturnUI
import SwiftUI

struct RemoteHostCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        let status = workspace.remoteStatus(for: project)
        let destination = project.host.map(SSHDestination.displayName) ?? ""
        let tunnel: Int? = nil
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.error != nil ? Tokens.stuck : status.info != nil ? Tokens.live : Tokens.idle)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(statusText(status, destination: destination)).font(.system(size: 13))
                Spacer()
                if status.isConnecting { ProgressView().controlSize(.small) }
                Button("Move to this server’s daemon") { Task { await model.moveToServerDaemon(project) } }
                    .buttonStyle(SectionButtonStyle())
                    .help("Reopen this project on the Saturn daemon running on the server. Its history here stays read-only.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Tokens.fill, in: .rect(cornerRadius: 12, style: .continuous))

            SettingsRows {
                row("Host", destination)
                row("System", status.info?.system ?? "—")
                row("git", status.info.map { $0.gitPath ?? "Not found on the host" } ?? "—")
                row("claude", status.info.map { $0.claudePath ?? "Not found on the host" } ?? "—")
                row("Agent tools", tunnel.map { "Tunnel open on the host’s port \($0)" } ?? "Opens when the first agent starts")
            }

            if let info = status.info, info.claudePath == nil {
                notice("Agents can’t run until Claude Code is installed on \(destination). Run `curl -fsSL https://claude.ai/install.sh | bash` there, then `claude` once to sign in.")
            }
            if let info = status.info, info.gitPath != nil, !info.hasGitIdentity {
                notice("git on \(destination) has no user name or email, so agents’ commits and merges will fail. Set them there with `git config --global user.name` and `git config --global user.email`.")
            }
            if let pulled = status.filesPulledAt {
                SettingsNote("Project files (.saturn/, specs, AGENTS.md, skills) synced \(pulled.formatted(.relative(presentation: .named))). Changes made in Saturn reach the host within seconds; changes on the host show up when you reconnect or come back to Saturn.")
            }
            if let recovery = workspace.state(for: project).recovery, !recovery.isClean {
                SettingsNote(recoverySummary(recovery), color: Tokens.need)
            }
            ForEach([status.syncError, status.error].compactMap(\.self), id: \.self) { message in
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsNote("The run bar starts the app on the host and forwards the ports it listens on to this Mac, so localhost links work here.", color: Tokens.text3)
        }
    }

    private func statusText(_ status: RemoteProjectStatus, destination: String) -> String {
        if status.isConnecting { return "Connecting to \(destination)…" }
        if status.error != nil { return "Can’t reach \(destination)" }
        if status.info != nil { return "Connected · \(project.name) runs on \(destination)" }
        return "\(project.name) runs on \(destination)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            SettingsRowLabel(title: title)
            Text(value)
                .font(Tokens.mono(12.5))
                .foregroundStyle(Tokens.text2)
                .frame(width: 320, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.need)
        }
        .font(.system(size: 12))
    }

    private func recoverySummary(_ recovery: WorktreeRecovery) -> String {
        var parts: [String] = []
        if !recovery.pruned.isEmpty { parts.append("pruned \(recovery.pruned.count) missing worktree\(recovery.pruned.count == 1 ? "" : "s")") }
        if !recovery.orphanedDirectories.isEmpty { parts.append("\(recovery.orphanedDirectories.count) leftover folder\(recovery.orphanedDirectories.count == 1 ? "" : "s") in .crew/") }
        return "Last check on the host: " + parts.joined(separator: ", ")
    }
}
