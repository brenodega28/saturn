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
        SettingsPage("Workspaces", subtitle: "How each agent’s worktree is prepared, which port it gets, how the app runs, and when idle agents are cleaned up.") {
            setupCard(settings)
            portsCard(settings)
            runCommandCard(settings)
            cleanupCard(settings)
        }
        .task(id: project.id) {
            scriptDraft = project.settings.setupScript
            basePortDraft = project.settings.basePort.map(String.init) ?? ""
            runCommandDraft = project.settings.runCommand
        }
    }

    private func runCommandCard(_ settings: ProjectSettings) -> some View {
        let detected = RunCommandDetector.detect(in: project.filesRoot)
        let isDirty = runCommandDraft != settings.runCommand
        let override = settings.runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            header("Run command", detail: "What Start in the run bar launches, with zsh -lc in the chosen checkout. PORT and SATURN_PORT are set to the agent’s port, or the base port for your checkout. Stop ends every process it started.")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Detected").font(.system(size: 13))
                if let detected {
                    Text(detected.label)
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                    Text("from the \(detected.origin)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("Nothing detected")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("Override").font(.system(size: 13))
                TextField(detected?.label ?? "npm run dev", text: $runCommandDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onSubmit { if isDirty { saveRunCommand() } }
                    .accessibilityLabel("Run command override")
                    .help("Leave empty to use the detected command")
                Button("Revert") { runCommandDraft = settings.runCommand }
                    .buttonStyle(.pill)
                    .disabled(!isDirty)
                    .help("Discard your edits to the run command")
                Button("Save") { saveRunCommand() }
                    .buttonStyle(.primaryPill)
                    .disabled(!isDirty)
                    .help("Use this command when you press Start")
            }
            Text(override.isEmpty
                ? (detected == nil ? "Saturn looks for a package.json dev script, a Makefile dev target or a Procfile. Add one, or set a command here." : "Start uses the detected command.")
                : "Start uses your override. Clear it and save to go back to the detected command.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func saveRunCommand() {
        let value = runCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        runCommandDraft = value
        update { $0.runCommand = value }
    }

    private func setupCard(_ settings: ProjectSettings) -> some View {
        let isDirty = scriptDraft != settings.setupScript
        return VStack(alignment: .leading, spacing: 12) {
            header("Setup script", detail: "Runs in every new worktree before the agent’s first turn: install dependencies, migrate the database. It runs with zsh -lc, and $SATURN_WORKTREE, $SATURN_AGENT and $SATURN_PORT are set.")
            TextEditor(text: $scriptDraft)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120, maxHeight: 240)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if scriptDraft.isEmpty {
                        Text("npm ci\npython manage.py migrate")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Setup script")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    timeoutControl(settings)
                    Spacer(minLength: 8)
                    scriptButtons(isDirty: isDirty, settings: settings)
                }
                VStack(alignment: .leading, spacing: 10) {
                    timeoutControl(settings)
                    HStack { scriptButtons(isDirty: isDirty, settings: settings) }
                }
            }
            Text("If the script fails, the agent is marked failed with the script’s last lines. Run agents fail their workflow step.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func timeoutControl(_ settings: ProjectSettings) -> some View {
        HStack(spacing: 10) {
            Text("Time limit").font(.system(size: 13))
            CountStepper(count: Binding(
                get: { settings.setupTimeoutMinutes },
                set: { value in update { $0.setupTimeoutMinutes = value } }
            ), range: 1...120)
            .help("Minutes before Saturn stops the setup script")
            Text("min").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func scriptButtons(isDirty: Bool, settings: ProjectSettings) -> some View {
        Button("Revert") { scriptDraft = settings.setupScript }
            .buttonStyle(.pill)
            .disabled(!isDirty)
            .help("Discard your edits to the setup script")
        Button("Save Script") { update { $0.setupScript = scriptDraft } }
            .buttonStyle(.primaryPill)
            .disabled(!isDirty)
            .help("Use this script for worktrees created from now on")
    }

    private func portsCard(_ settings: ProjectSettings) -> some View {
        let parsed = Int(basePortDraft.trimmingCharacters(in: .whitespaces))
        let isValid = basePortDraft.trimmingCharacters(in: .whitespaces).isEmpty || (parsed.map { (1024...65000).contains($0) } ?? false)
        return VStack(alignment: .leading, spacing: 12) {
            header("Ports", detail: "With a base port, each agent with a worktree gets its own stable port: base, base + 1, and so on. It’s passed to the setup script and the agent as PORT and SATURN_PORT.")
            HStack(spacing: 10) {
                Text("Base port").font(.system(size: 13))
                TextField("None", text: $basePortDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: 110)
                    .onSubmit { savePort(parsed, isValid: isValid) }
                    .accessibilityLabel("Base port")
                    .help("Leave empty to give agents no port")
                Button("Apply") { savePort(parsed, isValid: isValid) }
                    .buttonStyle(.pill)
                    .disabled(!isValid || parsed == settings.basePort)
                    .help("Agents created from now on get ports from this base")
                Spacer(minLength: 0)
            }
            if !isValid {
                Text("Use a number from 1024 to 65000.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            } else if let base = settings.basePort {
                Text(verbatim: "Next agents get \(base), \(base + 1), \(base + 2)… Existing agents keep their ports.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func cleanupCard(_ settings: ProjectSettings) -> some View {
        let choices = Self.cleanupChoices.contains(settings.idleCleanupMinutes)
            ? Self.cleanupChoices
            : (Self.cleanupChoices + [settings.idleCleanupMinutes]).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            header("Cleanup", detail: "Idle agents that aren’t pinned and aren’t in an active run are stopped and their worktrees removed. Branches stay, and worktrees with uncommitted changes are left alone.")
            HStack(spacing: 10) {
                Text("Remove idle agents").font(.system(size: 13))
                Picker("Remove idle agents", selection: Binding(
                    get: { settings.idleCleanupMinutes },
                    set: { value in update { $0.idleCleanupMinutes = value } }
                )) {
                    ForEach(choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "After \(Self.duration(minutes))").tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("How long an agent may sit idle before Saturn removes its worktree")
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func savePort(_ port: Int?, isValid: Bool) {
        guard isValid else { return }
        update { $0.basePort = port }
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
