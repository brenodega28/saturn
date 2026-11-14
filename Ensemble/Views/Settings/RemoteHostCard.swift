import EnsembleCore
import EnsembleUI
import SwiftUI

struct RemoteHostCard: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let status = model.remoteStatus(for: project)
        let destination = project.host.map(SSHDestination.displayName) ?? ""
        let tunnel = project.host.flatMap { model.remoteTunnels[$0]?.remotePort }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                V4Icon(glyph: .server, size: 14, lineWidth: 1.8).foregroundStyle(Theme.secondaryText)
                Text("SSH host").font(.system(size: 13, weight: .semibold))
                Spacer()
                if status.isConnecting {
                    ProgressView().controlSize(.small)
                } else if status.error == nil, status.info != nil {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.successText).font(.system(size: 12))
                }
                Button("Reconnect") { Task { await model.refresh(project) } }
                    .buttonStyle(.pill)
                    .disabled(status.isConnecting)
            }

            VStack(alignment: .leading, spacing: 6) {
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
                Text("Project files (.ensemble/, specs, AGENTS.md, skills) synced \(pulled.formatted(.relative(presentation: .named))). Changes made in Ensemble reach the host within seconds; changes on the host show up when you reconnect or come back to Ensemble.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recovery = model.state(for: project).recovery, !recovery.isClean {
                Text(recoverySummary(recovery)).font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            ForEach([status.syncError, status.error].compactMap(\.self), id: \.self) { message in
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The run bar starts the app on the host and forwards the ports it listens on to this Mac, so localhost links work here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Theme.monospaced)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
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
