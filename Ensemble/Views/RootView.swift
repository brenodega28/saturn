import AppKit
import EnsembleUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        content
            .environment(model.local)
            .frame(minWidth: 960, minHeight: 620)
            .environment(\.openURL, model.chatLinkOpenURLAction)
            .task { await model.launch() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadAllConfigs()
            }
            .fileImporter(isPresented: $model.isOpenPanelPresented, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.openFolder(url) }
                }
            }
            .sheet(isPresented: $model.isClonePresented) {
                CloneRepositorySheet()
            }
            .sheet(isPresented: $model.isRemoteFolderPresented) {
                RemoteFolderSheet()
            }
            .overlay {
                if model.isPalettePresented {
                    CommandPalette()
                }
            }
            .alert(item: $model.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let environment = model.environment {
            if !environment.isReady {
                FirstRunView(report: environment)
            } else if !model.hasOpenProjects {
                WelcomeView()
            } else if let setup = model.pendingSetup {
                ProgressView("Setting up \(setup.project.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Backdrop())
                    .task(id: setup.workspace.ref(of: setup.project)) { await setup.workspace.applyRecommendedSetup(setup.project) }
            } else {
                MainWindowView()
            }
        } else {
            ProgressView("Checking your setup…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Backdrop())
        }
    }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [Color.adaptive(dark: 0x1D2A4A, light: 0xCFE0FF), .clear], center: UnitPoint(x: 0.12, y: 0.08), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.adaptive(dark: 0x3A1F3F, light: 0xF3D9F1), .clear], center: UnitPoint(x: 0.92, y: 0.9), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
