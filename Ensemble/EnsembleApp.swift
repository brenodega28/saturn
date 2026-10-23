import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    @State private var launch = Launch.start()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Ensemble", id: WindowID.main) {
            Group {
                switch launch {
                case .ready(let model):
                    RootView().environment(model)
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

enum WindowID {
    static let main = "main"
    static let debugWorktrees = "debug-worktrees"
}

enum Launch {
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func start() -> Launch {
        do {
            let database = try AppDatabase.open(at: AppDatabase.defaultLocation)
            return .ready(AppModel(database: database, secrets: KeychainSecretStore(service: AppModel.keychainService)))
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
