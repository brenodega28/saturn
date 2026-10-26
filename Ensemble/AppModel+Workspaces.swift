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

    func createProject(from template: CrewTemplate, at folder: URL) async {
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
