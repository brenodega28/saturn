import EnsembleCore
import EnsembleUI
import SwiftUI

struct RemoteProjectView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private static let upcoming = [
        ("Agents", "Claude Code runs on the host and streams back to this window."),
        ("Checks and the app", "Checks and the dev server run on the host, with ports forwarded here."),
    ]

    var body: some View {
        let status = model.remoteStatus(for: project)
        let destination = project.host.map(SSHDestination.displayName) ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        V4Icon(glyph: .server, size: 16, lineWidth: 1.8).foregroundStyle(V4.secondary)
                        Text(project.name).font(V4.display(22))
                    }
                    Text(project.path)
                        .font(V4.monospaced(12.5))
                        .foregroundStyle(V4.secondary)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 0) {
                    row("Host", destination)
                    row("Branch", model.state(for: project).branch ?? "—")
                    row("System", status.info?.system ?? "—")
                    row("git", status.info.map { $0.gitPath ?? "Not found on the host" } ?? "—")
                    row("claude", status.info.map { $0.claudePath ?? "Not found on the host" } ?? "—")
                }
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))

                HStack(spacing: 10) {
                    Button("Reconnect") { Task { await model.refresh(project) } }
                        .buttonStyle(.pill)
                        .disabled(status.isConnecting)
                    if status.isConnecting {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(destination)…").foregroundStyle(V4.secondary)
                    } else if status.error == nil, status.info != nil {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(V4.greenText)
                    }
                }
                if let error = status.error {
                    Text(error)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                worktrees

                VStack(alignment: .leading, spacing: 10) {
                    Text("Running the crew on \(destination) is still being built")
                        .font(.system(size: 13, weight: .semibold))
                    Text("git and worktrees run on the host, but agents don’t yet. Ensemble won’t touch a folder on this Mac with the same path.")
                        .foregroundStyle(V4.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.upcoming, id: \.0) { title, detail in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(V4.secondary).frame(width: 4, height: 4)
                            Text(title).fontWeight(.medium)
                            Text(detail).foregroundStyle(V4.secondary)
                        }
                    }
                }
                .font(.system(size: 12.5))
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var worktrees: some View {
        let state = model.state(for: project)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Worktrees on \(project.host.map(SSHDestination.displayName) ?? "the host")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(".crew/ · Debug › Worktrees to create or remove")
                    .font(.system(size: 11.5))
                    .foregroundStyle(V4.secondary)
            }
            if state.worktrees.isEmpty {
                Text("None yet. Each agent will get its own worktree here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(V4.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.worktrees) { worktree in
                        row(worktree.agent, worktree.branch ?? "detached")
                    }
                }
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            }
            if let recovery = state.recovery, !recovery.isClean {
                Text(recoverySummary(recovery))
                    .font(.system(size: 12))
                    .foregroundStyle(V4.orangeText)
            }
        }
    }

    private func recoverySummary(_ recovery: WorktreeRecovery) -> String {
        var parts: [String] = []
        if !recovery.pruned.isEmpty { parts.append("pruned \(recovery.pruned.count) missing worktree\(recovery.pruned.count == 1 ? "" : "s")") }
        if !recovery.orphanedDirectories.isEmpty { parts.append("\(recovery.orphanedDirectories.count) leftover folder\(recovery.orphanedDirectories.count == 1 ? "" : "s") in .crew/") }
        return "Last check: " + parts.joined(separator: ", ")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(V4.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(V4.monospaced(12.5))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}
