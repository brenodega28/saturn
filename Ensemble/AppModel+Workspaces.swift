import AppKit
import EnsembleCore
import Foundation

extension AppModel {
    func connectWorkspaces() {
        agents.worktreePrepared = { [weak agents] preparation in
            try await agents?.runSetupScript(preparation)
        }
        agents.gitProvider = { [weak self] in self?.git }
        idleCleanup.gitProvider = { [weak self] in self?.git }
    }

    func createProject(from template: CrewTemplate?, at folder: URL) async {
        guard let git else {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
            return
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            alert = AppAlert(title: "Couldn’t create \(folder.lastPathComponent)", message: CloneError.destinationExists(folder).localizedDescription)
            return
        }
        do {
            try await CrewTemplates.createRepository(at: folder, template: template, git: git)
        } catch {
            alert = AppAlert(title: "Couldn’t create \(folder.lastPathComponent)", message: error.localizedDescription)
            return
        }
        await openFolder(folder)
    }

    func recentActivity(of project: Project) -> (text: String, isFailure: Bool)? {
        guard let id = project.id, let runs = try? database.runs(projectId: id), let latest = runs.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        let running = runs.count(where: \.isActive)
        if running > 0 { return ("\(running) running", false) }
        return latest.status == .failed ? ("last run failed", true) : nil
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "my-project"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.createProject(from: nil, at: url) }
        }
    }

    func applyTemplate(_ template: CrewTemplate, toExisting folder: URL) async {
        guard let git else {
            alert = AppAlert(title: "git isn’t available", message: "Ensemble couldn’t find git. Install the Xcode Command Line Tools and check again.")
            return
        }
        let root: URL
        do {
            root = try await git.repositoryRoot(containing: folder)
        } catch {
            alert = AppAlert(title: "Not a git repository", message: "\(folder.path) isn’t inside a git repository. Choose “Create New Folder…” to start a fresh repository with the \(template.name) crew.")
            return
        }
        do {
            try template.install(in: root)
        } catch {
            alert = AppAlert(title: "Couldn’t add the \(template.name) crew", message: error.localizedDescription)
            return
        }
        await openFolder(root)
    }
}
