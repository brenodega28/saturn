import EnsembleCore
import EnsembleUI
import SwiftUI

enum PermissionSummary {
    static func line(_ profile: PermissionProfileDefinition) -> String {
        PermissionCapability.allCases
            .map { "\($0.title): \(profile.level($0).title)" }
            .joined(separator: " · ")
    }
}

struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var draft = PermissionsConfig()
    @State private var newProfileName = ""
    @State private var errorMessage: String?

    var body: some View {
        let saved = model.config(for: project).permissions
        SettingsPage("Permissions", subtitle: "What each kind of agent may do on its own. Ask holds the agent and asks you in the chat; Never blocks it outright.") {
            matrixCard
            ForEach($draft.profiles) { $profile in
                commandsCard($profile)
            }
            newProfileCard
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Revert") { draft = saved }
                    .buttonStyle(.pill)
                    .disabled(draft == saved)
                Button("Save") { save() }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == saved)
            }
        }
        .task(id: project.id) { draft = saved }
    }

    private var matrixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Profile")
                    ForEach(PermissionCapability.allCases, id: \.self) { Text($0.title) }
                    Text("Used by")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                Divider().overlay(Theme.hairline)
                ForEach($draft.profiles) { $profile in
                    GridRow {
                        Text(profile.name).font(.system(size: 13, weight: .semibold))
                        ForEach(PermissionCapability.allCases, id: \.self) { capability in
                            Picker(capability.title, selection: level(of: capability, in: $profile)) {
                                ForEach(PermissionLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Text(usage(of: profile.id))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(2)
                    }
                }
            }
            Text("Builders use Developer, the Lead uses Lead, and checkers use Reviewer. Lead and checkers are always read-only.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }

    private func commandsCard(_ profile: Binding<PermissionProfileDefinition>) -> some View {
        let value = profile.wrappedValue
        let isBuiltIn = PermissionsConfig.builtIn.contains { $0.id == value.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(value.name) · extra commands").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !isBuiltIn {
                    Button("Delete", role: .destructive) { draft.profiles.removeAll { $0.id == value.id } }
                        .buttonStyle(.pill)
                        .disabled(!usage(of: value.id).isEmpty)
                        .help(usage(of: value.id).isEmpty ? "Remove this profile" : "Built-in agents use this profile")
                }
            }
            TokenEditor(items: profile.extraCommands, placeholder: "Add a command, e.g. xcodebuild", suggestions: [])
            Text(value.level(.runShell) == .never
                ? "This profile can’t run shell commands, so these are ignored."
                : "Agents with this profile may also run these without asking.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }

    private var newProfileCard: some View {
        let id = Slug.make(newProfileName).replacingOccurrences(of: "-", with: "_")
        let isTaken = draft.profile(id) != nil || id == PermissionsConfig.defaultProfileID
        return HStack(spacing: 8) {
            TextField("New profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { addProfile(id: id, isTaken: isTaken) }
            Button("New Profile") { addProfile(id: id, isTaken: isTaken) }
                .buttonStyle(.pill)
                .disabled(id.isEmpty || isTaken)
                .help(isTaken ? "A profile with this name already exists" : "Starts as a copy of Developer")
            Spacer()
        }
    }

    private func level(of capability: PermissionCapability, in profile: Binding<PermissionProfileDefinition>) -> Binding<PermissionLevel> {
        Binding(
            get: { profile.wrappedValue.level(capability) },
            set: { profile.wrappedValue.levels[capability] = $0 }
        )
    }

    private func usage(of id: String) -> String {
        AgentKind.allCases
            .filter { draft.resolve(for: $0, readOnly: !$0.editsCode).id == id }
            .map(\.name)
            .joined(separator: ", ")
    }

    private func addProfile(id: String, isTaken: Bool) {
        guard !id.isEmpty, !isTaken else { return }
        let template = draft.profile("developer") ?? PermissionsConfig.builtIn[0]
        draft.profiles.append(PermissionProfileDefinition(id: id, name: newProfileName.trimmingCharacters(in: .whitespaces), levels: template.levels))
        newProfileName = ""
    }

    private func save() {
        do {
            try ProjectConfigLoader.write(draft, repository: project.filesRoot)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        model.reloadConfig(for: project)
    }
}
