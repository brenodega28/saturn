import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let updater: Updater
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workbench) private var workbench

    private var context: CommandContext {
        CommandContext(model: model, workbench: workbench, openWindow: openWindow)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isConfigured)
        }

        CommandGroup(replacing: .newItem) {
            if model.currentProject == nil {
                Button("New Project…") { model.newProject() }
                    .keyboardShortcut("n")
            } else {
                Button("New Task") { model.newTask() }
                    .keyboardShortcut("n")
                Button("New Project…") { model.newProject() }
            }
            Button("Open Folder…") { model.isOpenPanelPresented = true }
                .keyboardShortcut("o")
            Button("Clone Repository…") { model.isClonePresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Project") {
                if let project = model.selectedProject { model.close(project) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(model.selectedProject == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                if model.isPalettePresented { model.isPalettePresented = false } else { model.openPalette() }
            }
                .keyboardShortcut("k")
            Divider()
            Menu("Navigator") {
                RegistryMenuItems(menu: "View.Navigator", context: context)
            }
            RegistryMenuItems(menu: "View", context: context)
            Divider()
            Button("Inbox") { model.selection = .inbox }
            ForEach(ProjectTab.sidebarOrder) { tab in
                Button(tab.title) {
                    if let index = ProjectTab.sidebarOrder.firstIndex(of: tab) { model.goToSection(index + 1) }
                }
                .disabled(model.openProjects.isEmpty)
            }
        }

        CommandMenu("Navigate") {
            RegistryMenuItems(menu: "Navigate", context: context)
        }

        CommandMenu("Agent") {
            Button("Message…") { model.openPalette(.agents) }
                .keyboardShortcut("j")
                .disabled(model.openProjects.isEmpty)
            Button("Spawn…") { model.spawnAgent() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.currentProject == nil)
            Divider()
            Button("Pause All") { model.pauseAllAgentsInSelectedProject() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.currentProject == nil)
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
        let groups = WorkbenchRegistry.shared.commands(in: menu)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { command in
                RegistryMenuItem(command: command, context: context)
            }
        }
    }
}

private struct RegistryMenuItem: View {
    let command: WorkbenchCommand
    let context: CommandContext

    var body: some View {
        if let isChecked = command.isChecked {
            Toggle(command.title, isOn: Binding(get: { isChecked(context) }, set: { _ in command.perform(context) }))
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isEnabled(context))
        } else {
            Button(command.title) { command.perform(context) }
                .keyboardShortcut(command.shortcut)
                .disabled(!command.isEnabled(context))
        }
    }
}
