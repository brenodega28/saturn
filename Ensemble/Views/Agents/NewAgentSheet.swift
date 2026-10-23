import EnsembleCore
import EnsembleUI
import SwiftUI

struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var name = ""
    @State private var agentModel: AgentModel = .sonnet
    @State private var task = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent").font(.system(size: 20, weight: .bold))
                Text("A Claude Code agent with its own worktree and branch in \(project.name).")
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Name")
                    TextField("Name", text: $name, prompt: Text(model.nextAgentName(in: project)))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Model")
                    Picker("Model", selection: $agentModel) {
                        ForEach(AgentModel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Task")
                TextField("Task", text: $task, prompt: Text("What should the agent do?"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(6...12)
                    .padding(10)
                    .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .labelsHidden()
            }

            Text(preview)
                .font(Theme.monospaced)
                .foregroundStyle(Theme.tertiaryText)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating worktree…").foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Create and Start") { Task { await create() } }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isCreating || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 620)
    }

    private var resolvedName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? model.nextAgentName(in: project) : name
    }

    private var preview: String {
        let agentSlug = Slug.make(resolvedName)
        let taskSlug = Slug.make(task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " "))
        return "\(WorktreeManager.directoryName)/\(agentSlug)  ·  \(WorktreeManager.branchPrefix)/\(agentSlug)/\(taskSlug.isEmpty ? "task" : taskSlug)"
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            try await model.spawnAgent(in: project, name: resolvedName, model: agentModel, task: task)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
