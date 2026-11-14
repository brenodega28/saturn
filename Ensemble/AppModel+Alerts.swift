import AppKit
import EnsembleCore
import Foundation

extension AppModel {
    var systemAlerts: [SystemAlert] {
        let errors = remoteStatuses.compactMapValues(\.error)
        return SystemAlert.detect(environment: environment, planUsage: planUsage.usage, projects: openProjects, remoteErrors: errors)
    }

    func resolve(_ alert: SystemAlert) {
        switch alert {
        case .claudeMissing, .claudeBroken:
            UserDefaults.standard.set("engines", forKey: AppSettingsView.tabKey)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .rateLimited:
            open(.usage)
        case .hostDisconnected(let projectID, _, _, _):
            guard let project = project(withID: projectID) else { return }
            Task { await reopen(project) }
        }
    }

    func updateDockBadge(attention: Int) {
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
    }
}
