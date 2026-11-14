import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var launch = Launch.connecting
    @State private var updater = Updater()

    var body: some Scene {
        Window("Ensemble", id: WindowID.main) {
            Group {
                switch launch {
                case .ready(let model):
                    RootView()
                        .environment(model)
                        .onAppear { appDelegate.model = model }
                        .modifier(SettingsLinkRouting())
                        .onOpenURL { url in
                            if let link = ChatLink(url: url) { model.open(link) }
                        }
                case .failed(let message):
                    LaunchFailureView(message: message) {
                        launch = .connecting
                        launch = await Launch.start()
                    }
                case .connecting:
                    ConnectingView()
                        .task { launch = await Launch.start() }
                }
            }
            .followsAppearance()
            .tint(Theme.accent)
        }
        .defaultSize(width: 1280, height: 820)
        .handlesExternalEvents(matching: [ChatLink.scheme])
        .commands {
            if case .ready(let model) = launch {
                AppCommands(model: model, updater: updater)
            }
        }

        WindowGroup("Ensemble", id: WindowID.detail, for: DetailDestination.self) { $destination in
            if case .ready(let model) = launch {
                DetailWindow(destination: destination)
                    .environment(model)
                    .modifier(ChatLinkRouting(model: model))
                    .followsAppearance()
                    .tint(Theme.accent)
                    .navigationTitle(destination?.title ?? "Ensemble")
            }
        }
        .defaultSize(width: 900, height: 700)
        .handlesExternalEvents(matching: [])

        Settings {
            if case .ready(let model) = launch {
                AppSettingsView(updater: updater)
                    .environment(model)
                    .followsAppearance()
                    .tint(Theme.accent)
            }
        }

        Window("Worktrees", id: WindowID.debugWorktrees) {
            if case .ready(let model) = launch {
                DebugWorktreesView()
                    .environment(model)
                    .followsAppearance()
                    .tint(Theme.accent)
            }
        }
        .defaultSize(width: 760, height: 560)
        .handlesExternalEvents(matching: [])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.stopAllAppsImmediately()
        model?.connection.stop()
    }
}

private struct ChatLinkRouting: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let link = ChatLink(url: url) else { return .systemAction }
            openWindow(id: WindowID.main)
            model.open(link)
            return .handled
        })
    }
}

enum WindowID {
    static let main = "main"
    static let debugWorktrees = "debug-worktrees"
    static let detail = "detail"
}

enum Launch {
    case connecting
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func start() async -> Launch {
        let clientPaths = AppPaths.standard
        do {
            let connection = try await LocalDaemon.connect(clientPaths: clientPaths)
            return .ready(AppModel(connection: connection, clientPaths: clientPaths, daemonPaths: LocalDaemon.paths))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct ConnectingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to the Ensemble daemon…").font(.title3)
            Text("Ensemble runs your agents in a background service so they keep working when this window is closed.")
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 300)
    }
}

struct LaunchFailureView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Ensemble couldn’t reach its daemon").font(.title2.bold())
            Text(message).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            Text(LocalDaemon.paths.root.path).font(Theme.monospaced).foregroundStyle(Theme.tertiaryText)
            Button("Try Again") { Task { await retry() } }.buttonStyle(.pill)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 300)
    }
}

private struct SettingsLinkRouting: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            guard url.scheme == ChatLink.scheme, url.host() == "settings" else { return }
            let tab = url.pathComponents.dropFirst().first
            if let tab { AppDefaults.store.set(tab, forKey: AppSettingsView.tabKey) }
            openSettings()
        }
    }
}
