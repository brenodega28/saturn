import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

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
            Button("Inbox") { model.goToSection(0) }
                .keyboardShortcut("1")
            ForEach(Array(ProjectTab.sidebarOrder.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { model.goToSection(index + 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")))
                    .disabled(model.openProjects.isEmpty)
            }
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
