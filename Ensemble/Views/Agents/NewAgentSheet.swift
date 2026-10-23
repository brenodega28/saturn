import EnsembleCore
import EnsembleUI
import SwiftUI

struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var roleID: String?
    @State private var name = ""
    @State private var count = 1
    @State private var isPinned = false
    @State private var task = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    @FocusState private var isTaskFocused: Bool

    var body: some View {
        let config = model.config(for: project)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent").font(.system(size: 20, weight: .bold))
                Text("Add to the \(project.name) crew. Each agent comes from a role in .ensemble/roles.")
                    .foregroundStyle(Theme.secondaryText)
            }

            if !model.hasConfig(project) {
                InstallDefaultsCard(project: project)
            } else if config.roles.isEmpty {
                Text("There are no roles in .ensemble/roles yet. Add one in Settings › Roles.")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                roleGroup("Writes code", roles: config.roles.filter(\.editsCode))
                roleGroup("Reviews, plans and tests", roles: config.roles.filter { !$0.editsCode })
                if let role = selectedRole(in: config) {
                    details(for: role)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            footer(role: selectedRole(in: config))
        }
        .padding(26)
        .frame(width: 720)
        .onAppear {
            model.reloadConfig(for: project)
            selectDefaultRole(in: model.config(for: project))
        }
        .onChange(of: config.roles.map(\.id)) { selectDefaultRole(in: config) }
    }

    @ViewBuilder
    private func roleGroup(_ title: String, roles: [RoleDefinition]) -> some View {
        if !roles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(roles) { role in
                        RoleTile(role: role, isSelected: role.id == roleID) { pick(role) }
                    }
                }
            }
        }
    }

    private func details(for role: RoleDefinition) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    TextField("Name", text: $name, prompt: Text(role.name))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .help("Agents are numbered after this name when there is more than one")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("How many").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    CountStepper(count: $count, range: 1...AgentRuntime.maxSpawnCount)
                }
                Toggle(isOn: $isPinned) {
                    Label("Pin", systemImage: "pin")
                }
                .toggleStyle(.button)
                .help("Pinned agents are kept between runs")
                .padding(.bottom, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                WorkspaceLine(role: role, branch: model.state(for: project).branch)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("First task (optional)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                TextField("Task", text: $task, prompt: Text("Leave empty to start idle and message the agent later"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(2...6)
                    .focused($isTaskFocused)
                    .padding(10)
                    .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .contentShape(.rect)
                    .onTapGesture { isTaskFocused = true }
                    .labelsHidden()
            }
        }
    }

    private func footer(role: RoleDefinition?) -> some View {
        HStack(spacing: 10) {
            if let role {
                Text("Will add").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(previewNames(for: role), id: \.self) { name in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(RoleAppearance(role: role).palette.gradient)
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                                Text(name).font(.system(size: 12, weight: .medium))
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 10)
                            .frame(height: 26)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            Spacer(minLength: 8)
            if isCreating {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)
            Button(count > 1 ? "Create \(count) Agents" : "Create Agent") { Task { await create() } }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isCreating || role == nil)
        }
    }

    private func selectedRole(in config: ProjectConfig) -> RoleDefinition? {
        roleID.flatMap(config.role)
    }

    private func selectDefaultRole(in config: ProjectConfig) {
        guard roleID.flatMap(config.role) == nil else { return }
        if let role = config.roles.first(where: \.editsCode) ?? config.roles.first {
            pick(role)
        }
    }

    private func pick(_ role: RoleDefinition) {
        roleID = role.id
        name = ""
    }

    private func previewNames(for role: RoleDefinition) -> [String] {
        model.agentNames(for: baseName(for: role), count: count, in: project)
    }

    private func baseName(for role: RoleDefinition) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.name : trimmed
    }

    private func create() async {
        guard let role = selectedRole(in: model.config(for: project)) else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await model.spawnAgents(in: project, role: role, count: count, name: baseName(for: role), pinned: isPinned, task: task)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct InstallDefaultsCard: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("This project has no roles yet").font(.system(size: 13.5, weight: .semibold))
                Text("Add Ensemble’s default roles and workflows to .ensemble/ in \(project.name). They are plain YAML you can edit and commit.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add default roles & workflows") { model.installDefaultConfig(in: project) }
                .buttonStyle(.primaryPill)
                .fixedSize()
        }
        .padding(16)
        .card(cornerRadius: 16)
    }
}

private struct RoleTile: View {
    let role: RoleDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                AgentAvatar(size: 40, appearance: RoleAppearance(role: role))
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(role.skills.first ?? "default · no skill")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(isSelected ? Theme.accent.opacity(0.12) : Theme.fill, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: 1.5))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(role.description.isEmpty ? role.name : role.description)
    }
}

struct CountStepper: View {
    @Binding var count: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 2) {
            Button { count = max(range.lowerBound, count - 1) } label: {
                Image(systemName: "minus").frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(count <= range.lowerBound)
            .accessibilityLabel("Fewer")
            .help("Fewer")
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 28)
                .accessibilityLabel("\(count) agents")
            Button { count = min(range.upperBound, count + 1) } label: {
                Image(systemName: "plus").frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(count >= range.upperBound)
            .accessibilityLabel("More")
            .help("More")
        }
        .padding(.horizontal, 3)
        .frame(height: 36)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How many")
    }
}

private struct WorkspaceLine: View {
    let role: RoleDefinition
    let branch: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: role.editsCode ? "arrow.triangle.branch" : "eye")
                .frame(width: 18)
                .foregroundStyle(role.editsCode ? Theme.successText : Theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(role.editsCode ? "New git worktree per agent" : "Read-only observer")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(role.editsCode
                     ? "Own branch off \(branch ?? "the current branch") under \(WorktreeManager.directoryName)/ — safe for parallel coding"
                     : "Reads the project and every worktree, runs tests — never writes code")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}
