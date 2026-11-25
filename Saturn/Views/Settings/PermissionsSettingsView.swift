import SaturnCore
import SaturnUI
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
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var draft = PermissionsConfig()
    @State private var newProfileName = ""
    @State private var errorMessage: String?

    @State private var selectedProfileID: String?

    var body: some View {
        let saved = workspace.config(for: project).permissions
        SettingsPage("Permissions", subtitle: "What workers may do without asking you first. Ask holds the agent and asks you in the chat; Never blocks it outright.") {
            if let index = selectedIndex {
                let profile = $draft.profiles[index]
                profilePicker
                SettingsRows {
                    ForEach(PermissionCapability.allCases, id: \.self) { capability in
                        HStack(spacing: 14) {
                            SettingsRowLabel(title: capability.title, detail: capability.detail)
                            SectionSegments(label: capability.title, options: PermissionLevel.allCases, title: \.title, selection: level(of: capability, in: profile))
                        }
                    }
                }
                CommandAllowList(commands: profile.extraCommands, isIgnored: profile.wrappedValue.level(.runShell) == .never)
            }
            newProfileRow
            if let errorMessage {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(Tokens.danger).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                SettingsNote("Builders use Developer, the Lead uses Lead, and checkers use Reviewer. Lead and checkers are always read-only.", color: Tokens.text3)
                Spacer(minLength: 8)
                Button("Revert") { draft = saved }
                    .buttonStyle(SectionButtonStyle())
                    .disabled(draft == saved)
                Button("Save") { save() }
                    .buttonStyle(SectionButtonStyle(kind: .primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == saved)
            }
        }
        .task(id: project.id) { draft = saved }
    }

    private var selectedIndex: Int? {
        draft.profiles.firstIndex { $0.id == selectedProfileID } ?? (draft.profiles.isEmpty ? nil : 0)
    }

    @ViewBuilder
    private var profilePicker: some View {
        if let index = selectedIndex {
            let profile = draft.profiles[index]
            let isBuiltIn = PermissionsConfig.builtIn.contains { $0.id == profile.id }
            let usedBy = usage(of: profile.id)
            HStack(spacing: 12) {
                if draft.profiles.count > 1 {
                    SectionSegments(
                        label: "Profile",
                        options: draft.profiles.map(\.id),
                        title: { id in draft.profile(id)?.name ?? id },
                        selection: Binding(get: { profile.id }, set: { selectedProfileID = $0 })
                    )
                    .fixedSize()
                }
                Text(usedBy.isEmpty ? "Not used by a built-in agent" : "Used by \(usedBy)")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !isBuiltIn {
                    Button("Delete Profile", role: .destructive) {
                        draft.profiles.removeAll { $0.id == profile.id }
                        selectedProfileID = nil
                    }
                    .buttonStyle(SectionButtonStyle(height: 28))
                    .disabled(!usedBy.isEmpty)
                    .help(usedBy.isEmpty ? "Remove this profile" : "Built-in agents use this profile")
                }
            }
        }
    }

    private var newProfileRow: some View {
        let id = Slug.make(newProfileName).replacingOccurrences(of: "-", with: "_")
        let isTaken = draft.profile(id) != nil || id == PermissionsConfig.defaultProfileID
        return HStack(spacing: 8) {
            TextField("New profile name", text: $newProfileName)
                .sectionField(width: 220)
                .onSubmit { addProfile(id: id, isTaken: isTaken) }
            Button("New Profile") { addProfile(id: id, isTaken: isTaken) }
                .buttonStyle(SectionButtonStyle())
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
        selectedProfileID = id
        newProfileName = ""
    }

    private func save() {
        do {
            try ProjectConfigLoader.write(draft, repository: project.filesRoot)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        workspace.reloadConfig(for: project)
    }
}

private struct CommandAllowList: View {
    @Binding var commands: [String]
    let isIgnored: Bool
    @State private var isAdding = false
    @State private var entry = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shell commands that never ask").font(.system(size: 13, weight: .semibold))
            FlowLayout(spacing: 6) {
                ForEach(commands, id: \.self) { command in
                    HStack(spacing: 6) {
                        Text(command).font(Tokens.mono(12))
                        Button { commands.removeAll { $0 == command } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Tokens.text3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(command)")
                        .help("Remove \(command)")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Tokens.code, in: .rect(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.hair))
                }
                if isAdding {
                    TextField("e.g. xcodebuild", text: $entry)
                        .sectionField(width: 180, monospaced: true)
                        .focused($isFocused)
                        .onSubmit(add)
                        .onKeyPress(.escape) {
                            isAdding = false
                            return .handled
                        }
                        .onAppear { isFocused = true }
                } else {
                    Button("+ Add") { isAdding = true }
                        .buttonStyle(SectionButtonStyle(kind: .dashed, height: 26))
                        .help("Let this profile run another command without asking")
                }
            }
            if isIgnored {
                SettingsNote("This profile can’t run shell commands, so these are ignored.", color: Tokens.need)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard()
    }

    private func add() {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !commands.contains(value) { commands.append(value) }
        entry = ""
        isAdding = false
    }
}

private extension PermissionCapability {
    var detail: String {
        switch self {
        case .editFiles: "Inside the worker’s own worktree"
        case .runShell: "Anything not on the list below"
        case .network: "Fetching from the internet"
        case .installPackages: "pip, pnpm and similar"
        case .gitPush: "Pushing branches to the remote"
        case .riskyCommands: "Deleting files, resetting git and similar"
        }
    }
}
