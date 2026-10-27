import EnsembleCore
import Foundation

extension AppModel {
    func needsOnboarding(_ project: Project) -> Bool {
        !hasConfig(project)
    }

    var onboardingProject: Project? {
        guard case .project = selection, let project = selectedProject, needsOnboarding(project) else { return nil }
        return project
    }

    func finishOnboarding(_ project: Project, plan: ProjectSetupPlan, name: String, createAgentsFile: Bool) {
        guard let id = project.id else { return }
        do {
            try plan.apply(to: project.url)
            if createAgentsFile, !AgentInstructions.status(repository: project.url).hasAgentsFile {
                _ = try AgentInstructions.setUp(repository: project.url)
            }
            if name != project.name {
                try database.renameProject(id: id, to: name)
            }
        } catch {
            alert = AppAlert(title: "Couldn’t set up \(project.name)", message: error.localizedDescription)
            return
        }
        updateSettings(plan.settings(updating: project.settings), for: project)
        reloadConfig(for: project)
        selection = .project(id)
        setTab(.lead, for: project)
    }
}
