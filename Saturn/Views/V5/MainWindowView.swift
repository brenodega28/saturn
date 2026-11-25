import SaturnCore
import SaturnUI
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
        .background(Tokens.window)
        .ignoresSafeArea()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .insetsWindowButtons(leading: 22, centerFromTop: 32)
        .sheet(isPresented: $model.isNewAgentPresented) {
            if let project = model.currentProject {
                NewAgentSheet(project: project).environment(model.currentWorkspace)
            }
        }
        .sheet(item: $model.pinPrompt) { prompt in PinPromptSheet(prompt: prompt).inWorkspace(prompt.daemon) }
        .confirmationDialog(
            "Delete “\(model.pendingChatDeletion?.chat.title ?? "")”?",
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
        .background(MainWindowReader { model.mainWindowRef = $0 })
        .task(id: model.currentRef) {
            guard let project = model.currentProject else { return }
            await model.currentWorkspace.openOnboardingIfNeeded(project)
        }
    }
}

private struct MainWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view.window) }
    }
}
