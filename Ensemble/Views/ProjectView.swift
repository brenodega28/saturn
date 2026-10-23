import EnsembleCore
import EnsembleUI
import SwiftUI

struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project

    var body: some View {
        let state = model.state(for: project)
        VStack(alignment: .leading, spacing: 20) {
            header(branch: state.branch)
            if let recovery = state.recovery, !recovery.isClean {
                RecoveryBanner(recovery: recovery) { openWindow(id: WindowID.debugWorktrees) }
            }
            content(for: model.tab(for: project), state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 10, leading: 26, bottom: 24, trailing: 22))
    }

    private func header(branch: String?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 17, weight: .bold)).kerning(-0.2)
                Text([project.path.abbreviatingHome, branch].compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            CapsuleTabs(ProjectTab.allCases, selection: Binding(
                get: { model.tab(for: project) },
                set: { model.setTab($0, for: project) }
            ), title: \.title)
            .fixedSize()
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func content(for tab: ProjectTab, state: ProjectState) -> some View {
        switch tab {
        case .tasks:
            EmptyState("No tasks yet", message: "Tasks come from Lead chat and GitHub Issues, and move through Incoming, Running, Waiting on you, Done and Failed.")
        case .lead:
            EmptyState("Lead chat", message: "Talk to a lead role here to turn a request into a task and a plan before any agent starts.")
        case .agents:
            EmptyState("No agents yet", message: "Agents are created by runs. Give the lead a task, or accept a GitHub issue from Tasks, and its workflow spins up the right roles.") {
                Button("New task in Lead chat") { model.setTab(.lead, for: project) }.buttonStyle(.primaryPill)
                Button("Open Tasks") { model.setTab(.tasks, for: project) }.buttonStyle(.pill)
            }
            .overlay(alignment: .bottom) {
                if !state.worktrees.isEmpty {
                    Button("\(state.worktrees.count) worktrees in .crew/ — Debug › Worktrees…") {
                        openWindow(id: WindowID.debugWorktrees)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
        case .changes:
            EmptyState("Nothing to review", message: "Diffs across a run’s branches and the pins agents flag for you appear here before anything reaches main.")
        case .workflows:
            EmptyState("No workflows yet", message: "Workflows live in .ensemble/workflows/ in this repository, versioned with your code.")
        case .settings:
            ProjectSettingsView(project: project, branch: state.branch)
        }
    }
}

private struct RecoveryBanner: View {
    let recovery: WorktreeRecovery
    let review: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.warning)
            Text(message).font(.system(size: 12.5))
            Spacer()
            Button("Review", action: review).buttonStyle(.pill)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var message: String {
        var parts: [String] = []
        if !recovery.pruned.isEmpty {
            parts.append("Cleaned up \(recovery.pruned.count) missing worktree\(recovery.pruned.count == 1 ? "" : "s")")
        }
        if !recovery.orphanedDirectories.isEmpty {
            parts.append("\(recovery.orphanedDirectories.count) leftover folder\(recovery.orphanedDirectories.count == 1 ? "" : "s") in .crew/")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let branch: String?

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Folder") {
                    HStack {
                        Text(project.path.abbreviatingHome).font(Theme.monospaced).textSelection(.enabled)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    }
                }
                LabeledContent("Branch", value: branch ?? "detached")
                LabeledContent("Worktrees", value: "\(model.state(for: project).worktrees.count) in \(WorktreeManager.directoryName)/")
            }

            Section("Anthropic access") {
                if let environment = model.environment {
                    LabeledContent("Using", value: environment.provider.summary)
                    Text(environment.provider.detail).foregroundStyle(Theme.secondaryText)
                }
                if model.storedAPIKey {
                    Button("Remove API Key from Keychain", role: .destructive) {
                        Task { await model.removeAPIKey() }
                    }
                } else {
                    APIKeyField()
                }
            }

            Section("Tools") {
                if let environment = model.environment {
                    ToolSummary(name: "git", check: environment.git)
                    ToolSummary(name: "Claude Code", check: environment.claude)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct ToolSummary: View {
    let name: String
    let check: ToolCheck

    var body: some View {
        LabeledContent(name) {
            switch check {
            case .found(let path, let version):
                Text("\(version) · \(path.path.abbreviatingHome)").font(Theme.monospaced)
            case .missing:
                Text("Not found").foregroundStyle(Theme.warning)
            case .broken(_, let message):
                Text(message).foregroundStyle(Theme.warning)
            }
        }
    }
}
