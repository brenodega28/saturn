import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    private var context: CommandContext {
        CommandContext(model: model, openWindow: openWindow)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isConfigured)
            Divider()
            Button("Stop Ensemble daemon") { model.confirmStopLocalDaemon() }
                .help("Stop the background service that runs your agents. Running agents stop too.")
        }

        CommandGroup(replacing: .newItem) {
            RegistryMenuItems(menu: "File", context: context)
            Menu("Open Recent") {
                ForEach(model.recentProjects) { project in
                    Button(project.name) { Task { await model.openFolder(project.url) } }
                }
            }
            .disabled(model.recentProjects.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            RegistryMenuItems(menu: "View", context: context)
        }

        CommandMenu("Navigate") {
            RegistryMenuItems(menu: "Navigate", context: context)
        }

        CommandMenu("Chat") {
            RegistryMenuItems(menu: "Chat", context: context)
        }

        CommandMenu("Agent") {
            RegistryMenuItems(menu: "Agent", context: context)
        }

        CommandMenu("Run") {
            RegistryMenuItems(menu: "Run", context: context)
        }

        CommandMenu("Review") {
            RegistryMenuItems(menu: "Review", context: context)
        }

        CommandMenu("Workflow") {
            RegistryMenuItems(menu: "Workflow", context: context)
        }

        CommandGroup(before: .windowList) {
            RegistryMenuItems(menu: "Window", context: context)
            Divider()
        }

        CommandGroup(replacing: .help) {
            RegistryMenuItems(menu: "Help", context: context)
        }

        CommandMenu("Debug") {
            Button("Worktrees…") { openWindow(id: WindowID.debugWorktrees) }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("Create Debug Worktree") {
                guard let project = model.selectedProject else { return }
                Task {
                    do {
                        try await model.createWorktree(in: project, agent: model.nextDebugAgentName(in: project), slug: "scratch")
                    } catch {
                        model.alert = AppAlert(title: "Couldn’t create worktree", message: error.localizedDescription)
                    }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(model.selectedProject == nil)
            Button("Recover Worktrees") {
                Task { await model.refreshAllProjects() }
            }
        }
    }
}

struct RegistryMenuItems: View {
    let menu: String
    let context: CommandContext

    var body: some View {
        let groups = CommandRegistry.shared.commands(in: menu)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { command in
                RegistryMenuItem(command: command, context: context)
            }
        }
    }
}

private struct RegistryMenuItem: View {
    let command: MenuCommand
    let context: CommandContext

    var body: some View {
        if let isChecked = command.isChecked {
            Toggle(command.title, isOn: Binding(get: { isChecked(context) }, set: { _ in command.perform(context) }))
                .keyboardShortcut(KeyBindings.shared.shortcut(for: command))
                .disabled(!command.isEnabled(context))
        } else {
            Button(command.title) { command.perform(context) }
                .keyboardShortcut(KeyBindings.shared.shortcut(for: command))
                .disabled(!command.isEnabled(context))
        }
    }
}
