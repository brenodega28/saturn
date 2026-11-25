import SaturnCore
import SaturnUI
import SwiftUI

struct DebugWorktreesView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    @State private var projectID: Int64?
    @State private var agent = ""
    @State private var slug = "scratch"
    @State private var isWorking = false
    @State private var pendingRemoval: Worktree?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let project {
                content(for: project)
            } else {
                EmptyState("No open projects", message: "Open a repository in the main window to manage its worktrees.")
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(Theme.windowBackground)
        .onAppear { projectID = projectID ?? model.selectedProject?.id ?? workspace.openProjects.first?.id }
        .onChange(of: workspace.openProjects) {
            if project == nil { projectID = workspace.openProjects.first?.id }
        }
    }

    private var project: Project? {
        workspace.openProjects.first { $0.id == projectID } ?? workspace.openProjects.first
    }

    private func content(for project: Project) -> some View {
        let state = workspace.state(for: project)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Project", selection: Binding(get: { project.id }, set: { projectID = $0 })) {
                    ForEach(workspace.openProjects) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Spacer()
                Button("Recover") { Task { await workspace.refresh(project) } }
                    .buttonStyle(.pill)
            }

            HStack(spacing: 8) {
                TextField("Agent", text: $agent, prompt: Text(workspace.nextDebugAgentName(in: project)))
                    .textFieldStyle(.roundedBorder)
                TextField("Slug", text: $slug)
                    .textFieldStyle(.roundedBorder)
                Button("Create Worktree") { Task { await create(in: project) } }
                    .buttonStyle(.primaryPill)
                    .disabled(isWorking)
            }
            Text(previewBranch(in: project))
                .font(Theme.monospaced)
                .foregroundStyle(Theme.tertiaryText)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            Table(state.worktrees) {
                TableColumn("Agent", value: \.agent)
                TableColumn("Branch") { Text($0.branch ?? "detached").font(Theme.monospaced) }
                TableColumn("Path") { Text($0.path.path.abbreviatingHome).font(Theme.monospaced).truncationMode(.middle) }
                TableColumn("") { worktree in
                    HStack {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([worktree.path]) }
                            .disabled(project.isRemote)
                        Button("Remove…") { pendingRemoval = worktree }
                    }
                    .disabled(isWorking)
                }
                .width(150)
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.agent ?? "")?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { worktree in
                Button("Remove Worktree and Branch", role: .destructive) { Task { await remove(worktree, in: project, force: false, deleteBranch: true) } }
                Button("Remove Worktree, Keep Branch") { Task { await remove(worktree, in: project, force: false, deleteBranch: false) } }
                Button("Force Remove, Discarding Changes", role: .destructive) { Task { await remove(worktree, in: project, force: true, deleteBranch: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { worktree in
                Text("\(worktree.path.path.abbreviatingHome)\nBranch \(worktree.branch ?? "detached")")
            }

            if let recovery = state.recovery, !recovery.isClean {
                RecoverySection(recovery: recovery, project: project)
            }
        }
        .padding(20)
    }

    private func previewBranch(in project: Project) -> String {
        let name = agent.isEmpty ? workspace.nextDebugAgentName(in: project) : agent
        let agentSlug = Slug.make(name)
        let taskSlug = Slug.make(slug)
        guard !agentSlug.isEmpty, !taskSlug.isEmpty else { return "Enter an agent name and slug" }
        return "\(WorktreeManager.directoryName)/\(agentSlug)  ·  \(WorktreeManager.branchPrefix)/\(agentSlug)/\(taskSlug)"
    }

    private func create(in project: Project) async {
        await perform {
            try await workspace.createWorktree(in: project, agent: agent.isEmpty ? workspace.nextDebugAgentName(in: project) : agent, slug: slug)
            agent = ""
        }
    }

    private func remove(_ worktree: Worktree, in project: Project, force: Bool, deleteBranch: Bool) async {
        await perform {
            try await workspace.removeWorktree(worktree, in: project, force: force, deleteBranch: deleteBranch)
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecoverySection: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let recovery: WorktreeRecovery
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Recovered on last check")
            ForEach(recovery.pruned) { worktree in
                Text("Pruned missing worktree \(worktree.agent) (branch \(worktree.branch ?? "detached") kept)")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(recovery.orphanedDirectories, id: \.self) { directory in
                HStack {
                    Text("Leftover folder \(directory.path.abbreviatingHome)").font(Theme.monospaced)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        .disabled(project.isRemote)
                    Button("Delete", role: .destructive) {
                        Task { await workspace.deleteOrphanedDirectory(directory, in: project) }
                    }
                }
            }
        }
        .padding(12)
        .card(cornerRadius: 12)
    }
}
