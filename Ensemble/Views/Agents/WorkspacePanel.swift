import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkspacePanel: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    @State private var status: WorktreeStatus?
    @State private var errorMessage: String?
    @State private var selectedFile: ChangedFile?
    @AppStorage("preferredEditor") private var preferredEditor = ""
    @AppStorage("preferredTerminal") private var preferredTerminal = ""

    var body: some View {
        let agent = session.agent
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Workspace", trailing: agent.readOnly ? "read-only" : "own worktree") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.worktreePath?.abbreviatingHome ?? (agent.readOnly ? "Reads the project folder" : "—"))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Text(status?.branch ?? agent.branch ?? "—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.successText)
                            .textSelection(.enabled)
                        Text(agent.archivedAt == nil ? aheadText : "Archived · worktree removed, branch kept")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                        if let port = agent.port, agent.archivedAt == nil {
                            DevServerRow(port: port).padding(.top, 4)
                        }
                    }
                }

                SetupLogSection(session: session)

                if let worktree = agent.worktreeURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([worktree])
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        OpenWithMenu(
                            title: "Open in",
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            apps: ExternalApp.installed(ExternalApp.editorCandidates),
                            folder: worktree,
                            preferred: $preferredEditor
                        )
                        OpenWithMenu(
                            title: "Terminal",
                            systemImage: "terminal",
                            apps: ExternalApp.installed(ExternalApp.terminalCandidates),
                            folder: worktree,
                            preferred: $preferredTerminal
                        )
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5))
                }

                section("Changed files", trailing: status.map { "\($0.changedFiles.count)" } ?? "") {
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    } else if let files = status?.changedFiles, !files.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                Button {
                                    selectedFile = file
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(file.change.rawValue)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(color(for: file.change))
                                            .frame(width: 12)
                                        Text(file.path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                        Spacer(minLength: 4)
                                        if !file.isCommitted {
                                            Text("uncommitted").font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        Text("No changes yet").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                    }
                }

                section("Usage", trailing: nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        stat("Billed via", model.providerMode?.title ?? "Not chosen")
                        stat("Cost", agent.costUSD.formatted(.currency(code: "USD")))
                        stat("Input", agent.inputTokens.formatted())
                        stat("Output", agent.outputTokens.formatted())
                        stat("Cache read", agent.cacheReadTokens.formatted())
                        stat("Cache write", agent.cacheWriteTokens.formatted())
                    }
                }
            }
            .padding(16)
        }
        .card(cornerRadius: 20)
        .task(id: refreshKey) { await refresh() }
        .sheet(item: $selectedFile) { file in
            FileDiffSheet(session: session, file: file)
        }
    }

    private var refreshKey: String {
        "\(session.id)-\(session.transcript.entries.count)-\(session.agent.status.rawValue)"
    }

    private var aheadText: String {
        guard let status else { return "" }
        let base = status.base ?? session.agent.baseBranch ?? "base"
        return "from \(base) · \(status.commitsAhead) commit\(status.commitsAhead == 1 ? "" : "s") ahead"
    }

    private func refresh() async {
        guard let git = model.git, let worktree = session.agent.worktreeURL, session.agent.archivedAt == nil else { return }
        do {
            status = try await git.status(of: worktree, base: session.agent.baseBranch)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func section(_ title: String, trailing: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            content()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced))
        }
        .font(.system(size: 12))
    }

    private func color(for change: ChangedFile.Change) -> Color {
        switch change {
        case .added, .untracked: Theme.successText
        case .deleted: Theme.danger
        case .modified, .renamed: Theme.warning
        }
    }
}

private struct FileDiffSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: AgentSession
    let file: ChangedFile
    @State private var diff: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(file.path).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                if let diff {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(background(for: line))
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    ProgressView().padding(40)
                }
            }
            .card(cornerRadius: 12)
        }
        .padding(20)
        .frame(width: 820, height: 600)
        .task {
            guard let git = model.git, let worktree = session.agent.worktreeURL else { return }
            diff = (try? await git.diff(of: file.path, in: worktree, base: session.agent.baseBranch)) ?? "Couldn’t load the diff."
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return Theme.tertiaryText }
        if line.hasPrefix("@@") { return Theme.info }
        if line.hasPrefix("+") { return Theme.successText }
        if line.hasPrefix("-") { return Color(hex: 0xFF8A80) }
        return Theme.secondaryText
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return Theme.success.opacity(0.1) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return Theme.danger.opacity(0.1) }
        return .clear
    }
}
