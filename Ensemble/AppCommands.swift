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
            Button("Open Folder…") { model.isOpenPanelPresented = true }
                .keyboardShortcut("o")
            Button("Clone Repository…") { model.isClonePresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Agent…") { model.isNewAgentPresented = true }
                .keyboardShortcut("n")
                .disabled(model.selectedProject == nil)
            Divider()
            Button("Close Project") {
                if let project = model.selectedProject { model.close(project) }
            }
            .disabled(model.selectedProject == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { model.isPalettePresented.toggle() }
                .keyboardShortcut("k")
            Divider()
            ForEach(Array(ProjectTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) {
                    if let project = model.selectedProject { model.setTab(tab, for: project) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                .disabled(model.selectedProject == nil)
            }
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
