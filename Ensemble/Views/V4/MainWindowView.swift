import EnsembleCore
import EnsembleUI
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProjectSidebar()
                    .overlay { RunMenuDismissal() }
                if let project = model.currentProject, project.isRemote, model.mainScreen.needsTheCrew {
                    RemoteProjectView(project: project)
                } else {
                    VStack(spacing: 8) {
                        if let project = model.currentProject, !project.isRemote {
                            RunBar(project: project)
                                .zIndex(1)
                        }
                        HStack(spacing: 8) {
                            MiddleColumn()
                                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                            LogColumn()
                        }
                        .overlay { RunMenuDismissal() }
                    }
                }
            }
            .padding(8)
            MainStatusBar()
        }
        .frame(minWidth: 1160, minHeight: 680)
        .background(V4.container)
        .ignoresSafeArea()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .insetsWindowButtons(leading: 22, centerFromTop: 32)
        .overlay(alignment: .top) {
            if model.mainWindow.isLibraryShown {
                LibraryPanel { model.mainWindow.isLibraryShown = false }
                    .padding(.top, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .sheet(isPresented: $model.isNewAgentPresented) {
            if let project = model.currentProject {
                NewAgentSheet(project: project)
            }
        }
        .sheet(item: $model.pinPrompt) { prompt in PinPromptSheet(prompt: prompt) }
        .onChange(of: model.mainScreen) { old, new in
            model.mainWindow.record(from: old, to: new)
        }
    }
}

private struct RunMenuDismissal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRunMenuOpen {
            Color.black.opacity(0.001)
                .contentShape(.rect)
                .onTapGesture { model.isRunMenuOpen = false }
                .accessibilityHidden(true)
        }
    }
}

private extension MainScreen {
    var needsTheCrew: Bool {
        switch self {
        case .chat, .run, .agent: true
        case .tool(let tool): [.tasks, .agents, .changes].contains(tool)
        case .spec: false
        }
    }
}
