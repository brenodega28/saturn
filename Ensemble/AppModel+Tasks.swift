import EnsembleCore
import Foundation

extension AppModel {
    func workflows(for project: Project) -> [WorkflowDefinition] {
        config(for: project).workflows
    }

    func defaultWorkflowID(for task: ProjectTask, in project: Project) -> String? {
        let workflows = workflows(for: project)
        let available = Set(workflows.map(\.id))
        if let chosen = task.workflow, available.contains(chosen) { return chosen }
        let labels = Set(task.labels)
        if let mapped = project.settings.githubMappings.first(where: { labels.contains($0.label) && available.contains($0.workflow) }) {
            return mapped.workflow
        }
        if let triggered = workflows.first(where: { $0.trigger.sources.contains(task.source) && !labels.isDisjoint(with: $0.trigger.labels) }) {
            return triggered.id
        }
        return workflows.first?.id
    }

    func acceptTask(_ task: ProjectTask, workflowID: String, in project: Project) {
        do {
            try startMappedWorkflow(task: task, workflowID: workflowID, in: project)
        } catch {
            alert = AppAlert(title: "Couldn’t start “\(task.title)”", message: error.localizedDescription)
        }
    }

    func dismissTask(_ task: ProjectTask) {
        guard let id = task.id else { return }
        do {
            try database.dismissTask(id: id)
        } catch {
            alert = AppAlert(title: "Couldn’t dismiss “\(task.title)”", message: error.localizedDescription)
        }
    }

    func retryFailedRun(_ run: Run) {
        do {
            try engine.retryStep(run)
        } catch {
            alert = AppAlert(title: "Couldn’t retry “\(run.title)”", message: error.localizedDescription)
        }
    }

    func openLead(forRun runID: Int64?, in projectID: Int64) {
        selection = .project(projectID)
        if let runID { leadFocusRunIDs[projectID] = runID }
        tabs[projectID] = .lead
    }
}
