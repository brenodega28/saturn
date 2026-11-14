import EnsembleCore
import EnsembleUI
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ChatSidebar()
                MiddleColumn()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Tokens.window)
            }
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
        .confirmationDialog(
            "Delete “\(model.pendingChatDeletion?.title ?? "")”?",
            isPresented: Binding(get: { model.pendingChatDeletion != nil }, set: { if !$0 { model.pendingChatDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let chat = model.pendingChatDeletion { Task { await model.deleteChat(chat) } }
                model.pendingChatDeletion = nil
            }
            Button("Cancel", role: .cancel) { model.pendingChatDeletion = nil }
        } message: {
            Text("Its messages, runs and workers are deleted, and their worktrees and branches removed. This can’t be undone.")
        }
        .onChange(of: model.mainScreen) { old, new in
            model.mainWindow.record(from: old, to: new)
        }
    }
}
