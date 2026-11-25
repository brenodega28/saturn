import AppKit
import SaturnCore
import Foundation

extension AppModel {
    func confirmStopLocalDaemon() {
        let running = local.live.agents.values.filter(\.isRunning).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop the Saturn daemon?"
        alert.informativeText = running == 0
            ? "Saturn’s background service stops. It starts again the next time you open Saturn."
            : "\(running) running agent\(running == 1 ? "" : "s") will stop. The daemon starts again the next time you open Saturn."
        alert.addButton(withTitle: "Stop Daemon")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await LocalDaemon.stop(local.connection)
                NSApp.terminate(nil)
            } catch {
                self.alert = AppAlert(title: "Couldn’t stop the Saturn daemon", message: error.localizedDescription)
            }
        }
    }
}
