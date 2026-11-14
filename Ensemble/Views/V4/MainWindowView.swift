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
                MiddleColumn()
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(8)
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
