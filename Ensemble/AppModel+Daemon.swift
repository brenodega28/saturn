import AppKit
import EnsembleCore
import Foundation

extension AppModel {
    func confirmStopLocalDaemon() {
        let running = local.live.agents.values.filter(\.isRunning).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop the Ensemble daemon?"
        alert.informativeText = running == 0
            ? "Ensemble’s background service stops. It starts again the next time you open Ensemble."
            : "\(running) running agent\(running == 1 ? "" : "s") will stop. The daemon starts again the next time you open Ensemble."
        alert.addButton(withTitle: "Stop Daemon")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await LocalDaemon.stop(local.connection)
                NSApp.terminate(nil)
            } catch {
                self.alert = AppAlert(title: "Couldn’t stop the Ensemble daemon", message: error.localizedDescription)
            }
        }
    }
}
