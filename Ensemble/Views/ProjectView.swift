import EnsembleCore
import EnsembleUI
import SwiftUI

struct ProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project

    var body: some View {
        @Bindable var model = model
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
        .sheet(isPresented: $model.isNewAgentPresented) {
            NewAgentSheet(project: project)
        }
    }

    private func header(branch: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                title(branch: branch).frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 12)
                headerControls
            }
            VStack(alignment: .leading, spacing: 12) {
                title(branch: branch)
                headerControls
            }
        }
        .frame(minHeight: 52)
    }

    private func title(branch: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 17, weight: .bold))
                .kerning(-0.2)
                .lineLimit(1)
            Text([project.path.abbreviatingHome, branch].compactMap(\.self).joined(separator: " · "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 14) {
            CapsuleTabs(ProjectTab.allCases, selection: Binding(
                get: { model.tab(for: project) },
                set: { model.setTab($0, for: project) }
            ), title: \.title)
            .fixedSize()
            Button {
                model.isNewAgentPresented = true
            } label: {
                Label("New Agent", systemImage: "plus")
            }
            .buttonStyle(.primaryPill)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func content(for tab: ProjectTab, state: ProjectState) -> some View {
        switch tab {
        case .tasks:
            TasksView(project: project)
        case .lead:
            LeadView(project: project)
        case .agents:
            if let session = model.selectedAgent(in: project) {
                AgentSessionView(session: session, project: project)
            } else {
                AgentsView(project: project, worktreeCount: state.worktrees.count) {
                    openWindow(id: WindowID.debugWorktrees)
                }
            }
        case .changes:
            ChangesView(project: project)
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
