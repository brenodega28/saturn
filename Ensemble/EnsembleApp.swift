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
                        .onOpenURL { url in
                            if let link = ChatLink(url: url) { model.open(link) }
                        }
                case .failed(let message):
                    LaunchFailureView(message: message)
                case .alreadyRunning:
                    EmptyView()
                }
            }
            .preferredColorScheme(.dark)
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
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
                    .navigationTitle(destination?.title ?? "Ensemble")
            }
        }
        .defaultSize(width: 900, height: 700)
        .handlesExternalEvents(matching: [])

        Window("Organizer", id: WindowID.organizer) {
            if case .ready(let model) = launch {
                OrganizerView()
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
            }
        }
        .defaultSize(width: 1240, height: 780)
        .handlesExternalEvents(matching: [])

        Settings {
            if case .ready(let model) = launch {
                AppSettingsView(updater: updater)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .tint(Theme.accent)
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
        .handlesExternalEvents(matching: [])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Launch.isBlockedByAnotherInstance else { return }
        NSApp.windows.forEach { $0.orderOut(nil) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ensemble is already running with this data folder."
        alert.informativeText = "Quit the other copy first."
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.engine.stopOrphanWatchdog()
        model?.agents.terminateAll()
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
    static let organizer = "organizer"
}

enum Launch {
    case ready(AppModel)
    case failed(String)
    case alreadyRunning

    @MainActor private(set) static var instanceLock: InstanceLock?
    @MainActor private(set) static var isBlockedByAnotherInstance = false

    @MainActor
    static func start() -> Launch {
        let paths = AppPaths.standard
        do {
            instanceLock = try InstanceLock.acquire(paths: paths)
        } catch InstanceLockError.alreadyRunning {
            isBlockedByAnotherInstance = true
            return .alreadyRunning
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
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
