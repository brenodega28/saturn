import SaturnCore
import SaturnUI
import SwiftUI

struct WorkspacesSettingsView: View {
    static let cleanupChoices = [0, 5, 10, 30, 60, 120, 240]

    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var scriptDraft = ""
    @State private var basePortDraft = ""
    @State private var runCommandDraft = ""

    var body: some View {
        let settings = project.settings
        let detected = RunCommandDetector.detect(in: project.filesRoot)
        let parsedPort = Int(basePortDraft.trimmingCharacters(in: .whitespaces))
        let isPortValid = basePortDraft.trimmingCharacters(in: .whitespaces).isEmpty || (parsedPort.map { (1024...65000).contains($0) } ?? false)
        let isDirty = scriptDraft != settings.setupScript
            || runCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines) != settings.runCommand
            || (isPortValid && parsedPort != settings.basePort)
        SettingsPage("Workspaces", subtitle: "Where workers build, and how Saturn runs the app.") {
            SettingsRows {
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Worktrees in", detail: "One folder per worker")
                    Text("\(WorktreeManager.directoryName)/")
                        .font(Tokens.mono(12.5))
                        .foregroundStyle(Tokens.text2)
                        .frame(width: 320, alignment: .leading)
                }
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Run command", detail: runCommandDetail(detected: detected, settings: settings))
                    TextField("Run command", text: $runCommandDraft, prompt: Text(detected?.label ?? "npm run dev"))
                        .sectionField(monospaced: true)
                        .accessibilityLabel("Run command override")
                        .help("Leave empty to use the detected command. PORT and SATURN_PORT are set to the agent’s port.")
                }
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 14) {
                        SettingsRowLabel(title: "Ports", detail: settings.basePort.map { "Next agents get \($0), \($0 + 1), \($0 + 2)…" } ?? "Each worktree gets the next port from a base")
                        TextField("Base port", text: $basePortDraft, prompt: Text("None"))
                            .sectionField(monospaced: true)
                            .accessibilityLabel("Base port")
                            .help("Leave empty to give agents no port. Existing agents keep their ports.")
                    }
                    if !isPortValid {
                        SettingsNote("Use a number from 1024 to 65000.", color: Tokens.need)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    SettingsRowLabel(title: "Setup command", detail: "Runs once in a new worktree with zsh -lc. $SATURN_WORKTREE, $SATURN_AGENT and $SATURN_PORT are set. If it fails, the agent is marked failed.")
                    TextField("Setup command", text: $scriptDraft, prompt: Text("npm ci"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Tokens.mono(12.5))
                        .lineLimit(1...8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(width: 320, alignment: .leading)
                        .frame(minHeight: 32)
                        .background(Tokens.window, in: .rect(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
                        .accessibilityLabel("Setup script")
                }
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Setup time limit", detail: "Minutes before Saturn stops the setup command")
                    CountStepper(count: Binding(
                        get: { settings.setupTimeoutMinutes },
                        set: { value in update { $0.setupTimeoutMinutes = value } }
                    ), range: 1...120)
                }
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Idle workers", detail: "Unpinned idle agents outside an active run are stopped and their worktrees removed. Branches and uncommitted work stay.")
                    cleanupPicker(settings)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Revert") { loadDrafts() }
                    .buttonStyle(SectionButtonStyle())
                    .disabled(!isDirty)
                    .help("Discard your edits")
                Button("Save") { save(port: parsedPort, isPortValid: isPortValid) }
                    .buttonStyle(SectionButtonStyle(kind: .primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty || !isPortValid)
                    .help("Applies to worktrees and agents created from now on")
            }
        }
        .task(id: project.id) { loadDrafts() }
    }

    private func runCommandDetail(detected: DetectedRunCommand?, settings: ProjectSettings) -> String {
        if !settings.runCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Start uses your override. Clear it and save to use \(detected.map { "the detected \($0.label)" } ?? "a detected command")."
        }
        if let detected { return "Start uses \(detected.label) from the \(detected.origin)" }
        return "Saturn looks for a package.json dev script, a Makefile dev target or a Procfile"
    }

    private func cleanupPicker(_ settings: ProjectSettings) -> some View {
        let choices = Self.cleanupChoices.contains(settings.idleCleanupMinutes)
            ? Self.cleanupChoices
            : (Self.cleanupChoices + [settings.idleCleanupMinutes]).sorted()
        return Picker("Remove idle agents", selection: Binding(
            get: { settings.idleCleanupMinutes },
            set: { value in update { $0.idleCleanupMinutes = value } }
        )) {
            ForEach(choices, id: \.self) { minutes in
                Text(minutes == 0 ? "Never remove" : "Remove after \(Self.duration(minutes))").tag(minutes)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("How long an agent may sit idle before Saturn removes its worktree")
    }

    private func loadDrafts() {
        scriptDraft = project.settings.setupScript
        basePortDraft = project.settings.basePort.map(String.init) ?? ""
        runCommandDraft = project.settings.runCommand
    }

    private func save(port: Int?, isPortValid: Bool) {
        guard isPortValid else { return }
        let command = runCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        runCommandDraft = command
        update { settings in
            settings.setupScript = scriptDraft
            settings.runCommand = command
            settings.basePort = port
        }
    }

    private func update(_ change: (inout ProjectSettings) -> Void) {
        var settings = project.settings
        change(&settings)
        workspace.updateSettings(settings, for: project)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
