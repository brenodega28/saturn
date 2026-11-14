import EnsembleCore
import EnsembleUI
import SwiftUI

struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var kind: AgentKind = .builder
    @State private var name = ""
    @State private var modelName = AgentKind.builder.defaultModel
    @State private var skills: [String] = []
    @State private var count = 1
    @State private var isPinned = false
    @State private var task = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    @FocusState private var isTaskFocused: Bool
    @FocusState private var isModelFocused: Bool

    var body: some View {
        let role = kind.builtInRole
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent").font(.system(size: 20, weight: .bold))
                Text("Add a builder or a checker to \(project.name), then choose its model and the installed skills it loads.")
                    .foregroundStyle(Theme.secondaryText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(AgentKind.spawnable) { option in
                    KindTile(role: option.builtInRole, isSelected: option == kind) { pick(option) }
                }
            }
            details(for: role, projectModels: AgentKind.allCases.map(\.defaultModel))

            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            footer(role: role)
        }
        .padding(26)
        .frame(width: 720)
        .onAppear { model.reloadConfig(for: project) }
        .task(id: project.path) { try? await model.loadSkillPlugins(for: project) }
    }

    private func skillsField() -> some View {
        let installed = SkillLibrary.skills(in: project.filesRoot, pluginSkills: model.pluginSkills(for: project))
        let names = Set(installed.map(\.name))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Skills").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            TokenEditor(items: $skills, placeholder: installed.isEmpty ? "No skills installed" : "Add an installed skill", suggestions: installed.map(\.name), missing: Set(skills.filter { !names.contains($0) }))
            Text(installed.isEmpty
                 ? "Install skills in .claude/skills, ~/.claude/skills or with a plugin in Settings › Skills."
                 : "The agent loads only the skills you add here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func details(for role: RoleDefinition, projectModels: [String]) -> some View {
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
                    Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    ModelField(model: $modelName, roleModel: role.model, projectModels: projectModels)
                        .focused($isModelFocused)
                }
                .frame(width: 220)
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

            if !isModelValid && !isModelFocused {
                Text(AgentError.unknownModel(modelName).localizedDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }

            skillsField()

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

    private func footer(role: RoleDefinition) -> some View {
        HStack(spacing: 10) {
            Group {
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
                .disabled(isCreating || !isModelValid)
        }
    }

    private func pick(_ option: AgentKind) {
        kind = option
        name = ""
        modelName = option.defaultModel
    }

    private var trimmedModel: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isModelValid: Bool {
        trimmedModel.isEmpty || ModelCatalog.isValid(trimmedModel)
    }

    private func previewNames(for role: RoleDefinition) -> [String] {
        model.agentNames(for: baseName(for: role), count: count, in: project)
    }

    private func baseName(for role: RoleDefinition) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.name : trimmed
    }

    private func create() async {
        let role = kind.builtInRole
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await model.spawnAgents(in: project, kind: kind, count: count, name: baseName(for: role), model: trimmedModel, skills: skills, pinned: isPinned, task: task)
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
                Text("This project has no workflows yet").font(.system(size: 13.5, weight: .semibold))
                Text("Add Ensemble’s default workflows to .ensemble/ in \(project.name). They are plain YAML you can edit and commit.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add default workflows") { model.installDefaultConfig(in: project) }
                .buttonStyle(.primaryPill)
                .fixedSize()
        }
        .padding(16)
        .card(cornerRadius: 16)
    }
}

private struct KindTile: View {
    let role: RoleDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                AgentAvatar(size: 40, appearance: RoleAppearance(role: role))
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(role.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
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

private struct ModelField: View {
    @Binding var model: String
    let roleModel: String
    let projectModels: [String]

    var body: some View {
        TextField("Model", text: $model, prompt: Text(roleModel))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()
            .textInputSuggestions(ModelCatalog.suggestions(matching: model, including: projectModels), id: \.self) { suggestion in
                HStack {
                    Text(suggestion).lineLimit(1).fixedSize()
                    Spacer(minLength: 12)
                    Text(ModelCatalog.detail(for: suggestion)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .textInputCompletion(suggestion)
            }
            .help("An alias like sonnet always uses the latest model; a full claude- name pins a version. The default is \(roleModel).")
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
                     : "Starts fresh, reads the project and every worktree, runs tests — never writes code")
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
