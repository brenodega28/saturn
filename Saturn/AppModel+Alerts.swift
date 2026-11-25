import AppKit
import SaturnCore
import Foundation

extension AppModel {
    var systemAlerts: [SystemAlert] {
        let errors = local.remoteStatuses.compactMapValues(\.error)
        return SystemAlert.detect(environment: environment, planUsage: planUsage.usage, projects: local.openProjects, remoteErrors: errors)
    }

    func resolve(_ alert: SystemAlert) {
        switch alert {
        case .claudeMissing, .claudeBroken:
            AppDefaults.store.set("engines", forKey: AppSettingsView.tabKey)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .rateLimited:
            open(.usage)
        case .hostDisconnected(let projectID, _, _, _):
            guard let project = local.project(withID: projectID) else { return }
            Task { await local.reopen(project) }
        }
    }

    func updateDockBadge(attention: Int) {
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
    }
}
