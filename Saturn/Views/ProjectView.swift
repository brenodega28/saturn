import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    let project: Project
    let tab: ProjectTab

    var body: some View {
        let state = workspace.state(for: project)
        VStack(alignment: .leading, spacing: 14) {
            if let recovery = state.recovery, !recovery.isClean {
                RecoveryBanner(recovery: recovery) { openWindow(id: WindowID.debugWorktrees) }
            }
            content(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 20, trailing: 20))
    }

    @ViewBuilder
    private func content(state: ProjectState) -> some View {
        switch tab {
        case .lead:
            LeadView(project: project)
        case .agents:
            AgentsView(project: project, worktreeCount: state.worktrees.count) {
                openWindow(id: WindowID.debugWorktrees)
            }
        case .changes:
            ChangesView(project: project)
        case .workflows:
            WorkflowsView(project: project)
        case .settings:
            ProjectSettingsView(project: project, branch: state.branch)
        case .code:
            CodeView(project: project)
        }
    }
}

struct ProjectScreenAccessory: View {
    let project: Project
    let tab: ProjectTab

    var body: some View {
        if tab != .lead {
            NewAgentButton()
        }
    }
}

struct NewAgentButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.isNewAgentPresented = true
        } label: {
            Label("New Agent", systemImage: "plus")
        }
        .buttonStyle(PillButtonStyle(.primary, height: 24))
        .fixedSize()
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
