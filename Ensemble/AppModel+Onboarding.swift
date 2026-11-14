import EnsembleCore
import Foundation

extension AppModel {
    func needsOnboarding(_ project: Project) -> Bool {
        if project.isRemote, remoteStatus(for: project).filesPulledAt == nil { return false }
        return !hasConfig(project)
    }

    var onboardingProject: Project? {
        guard case .project = selection, let project = selectedProject, needsOnboarding(project) else { return nil }
        return project
    }

    func finishOnboarding(_ project: Project, plan: ProjectSetupPlan, name: String, createAgentsFile: Bool) {
        guard let id = project.id else { return }
        do {
            try plan.apply(to: project.filesRoot)
            if createAgentsFile, !AgentInstructions.status(repository: project.filesRoot).hasAgentsFile {
                _ = try AgentInstructions.setUp(repository: project.filesRoot)
            }
            if name != project.name {
                dispatch("Couldn’t rename \(project.name)", ProjectCommands.Rename(projectID: id, name: name))
            }
        } catch {
            alert = AppAlert(title: "Couldn’t set up \(project.name)", message: error.localizedDescription)
            return
        }
        updateSettings(plan.settings(updating: project.settings), for: project)
        reloadConfig(for: project)
        if project.isRemote {
            Task { try? await syncRemoteFiles(project) }
        }
        selection = .project(id)
        setTab(.lead, for: project)
    }
}
