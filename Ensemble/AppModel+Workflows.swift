import EnsembleCore
import Foundation

extension AppModel {
    func activeRuns(ofWorkflow workflowID: String, in project: Project) -> [Run] {
        guard let projectID = project.id else { return [] }
        _ = engine.runs
        let stored = (try? database.runs(projectId: projectID)) ?? []
        return stored.filter { $0.workflow == workflowID && $0.isActive }
    }

    @discardableResult
    func saveWorkflow(_ draft: WorkflowDefinition, comparedTo saved: WorkflowDefinition?, in project: Project) throws -> WorkflowDefinition {
        let written = try ProjectConfigLoader.save(draft, comparedTo: saved, repository: project.url)
        reloadConfig(for: project)
        return written
    }

    func deleteWorkflow(_ id: String, in project: Project) throws {
        try ProjectConfigLoader.deleteWorkflow(id, repository: project.url)
        reloadConfig(for: project)
    }
}
