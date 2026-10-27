import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var launch = Launch.start()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Ensemble", id: WindowID.main) {
            Group {
                switch launch {
                case .ready(let model):
                    RootView()
                        .environment(model)
                        .onAppear { appDelegate.model = model }
                case .failed(let message):
                    LaunchFailureView(message: message)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            if case .ready(let model) = launch {
                AppCommands(model: model, updater: updater)
            }
        }

        WindowGroup("Ensemble", id: WindowID.detail, for: DetailDestination.self) { $destination in
            if case .ready(let model) = launch {
                DetailWindow(destination: destination)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
                    .navigationTitle(destination?.title ?? "Ensemble")
            }
        }
        .defaultSize(width: 900, height: 700)

        Window("Worktrees", id: WindowID.debugWorktrees) {
            if case .ready(let model) = launch {
                DebugWorktreesView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
            }
        }
        .defaultSize(width: 760, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.agents.terminateAll()
    }
}

enum WindowID {
    static let main = "main"
    static let debugWorktrees = "debug-worktrees"
    static let detail = "detail"
}

enum Launch {
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func start() -> Launch {
        do {
            let paths = AppPaths.standard
            let database = try AppDatabase.open(at: paths.database)
            return .ready(AppModel(database: database, paths: paths, secrets: KeychainSecretStore(service: AppModel.keychainService)))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Ensemble couldn’t open its database").font(.title2.bold())
            Text(message).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            Text(AppDatabase.defaultLocation.path).font(Theme.monospaced).foregroundStyle(Theme.tertiaryText)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 300)
    }
}
