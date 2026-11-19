import EnsembleCore
import Foundation

extension AppModel {
    func needsSetup(_ project: Project) -> Bool {
        !project.isRemote && !hasConfig(project)
    }

    var pendingSetupProject: Project? {
        guard let project = selectedProject, let id = project.id, needsSetup(project) else { return nil }
        return setupAttempts.contains(id) && !setupsInFlight.contains(id) ? nil : project
    }

    func applyRecommendedSetup(_ project: Project) async {
        guard let id = project.id, needsSetup(project), !setupAttempts.contains(id) else { return }
        setupAttempts.insert(id)
        setupsInFlight.insert(id)
        defer { setupsInFlight.remove(id) }

        let scan = await ProjectScanner.scan(repository: project.url, git: git(for: project), files: project.filesRoot)
        let plan = ProjectSetupPlan.recommended(for: scan)
        do {
            try plan.apply(to: project.filesRoot)
            if !scan.docs.contains("AGENTS.md"), !AgentInstructions.status(repository: project.filesRoot).hasAgentsFile {
                _ = try AgentInstructions.setUp(repository: project.filesRoot)
            }
        } catch {
            alert = AppAlert(title: "Couldn’t set up \(project.name)", message: error.localizedDescription)
            return
        }
        updateSettings(plan.settings(updating: project.settings), for: project)
        reloadConfig(for: project)
        selection = .project(id)
        showChat(in: project)
    }
}
