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
    func saveWorkflow(_ draft: WorkflowDefinition, comparedTo saved: WorkflowDefinition?, note: String = "", in project: Project) throws -> WorkflowDefinition {
        let written = try ProjectConfigLoader.save(draft, comparedTo: saved, note: note, repository: project.filesRoot)
        reloadConfig(for: project)
        return written
    }

    func workflowHistory(_ workflowID: String, in project: Project) -> [WorkflowVersionStats] {
        guard let projectID = project.id else { return [] }
        _ = engine.runs
        let versions = ProjectConfigLoader.history(of: workflowID, repository: project.filesRoot)
        return (try? database.versionStats(of: workflowID, projectId: projectID, versions: versions)) ?? []
    }

    @discardableResult
    func restoreWorkflow(_ version: WorkflowVersion, of current: WorkflowDefinition, in project: Project) throws -> WorkflowDefinition {
        let written = try ProjectConfigLoader.restore(version, of: current, repository: project.filesRoot)
        reloadConfig(for: project)
        return written
    }

    func deleteWorkflow(_ id: String, in project: Project) throws {
        try ProjectConfigLoader.deleteWorkflow(id, repository: project.filesRoot)
        reloadConfig(for: project)
    }
}
