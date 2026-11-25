import EnsembleCore
import Foundation

struct NewChatOptions: Hashable {
    var workflow: String?
    var model: String?
    var effort: LeadEffort?
}

extension AppModel {
    static let leadModels: [(id: String, title: String, detail: String)] = [
        ("opus", "Opus", "Best plans and specs"),
        ("sonnet", "Sonnet", "Faster, good for small changes"),
        ("haiku", "Haiku", "Quick questions only"),
    ]
}

extension DaemonWorkspace {
    func newChatOptions(for project: Project) -> NewChatOptions {
        project.id.flatMap { newChatOptionsByProject[$0] } ?? NewChatOptions()
    }

    func setNewChatOptions(_ options: NewChatOptions, for project: Project) {
        guard let id = project.id else { return }
        newChatOptionsByProject[id] = options
    }

    func leadModel(for chat: Chat?, in project: Project) -> String {
        chat?.leadModel ?? chat.flatMap { leadSession(for: $0)?.agent.model } ?? newChatOptions(for: project).model ?? leadRole(in: project).model
    }

    func leadEffort(for chat: Chat?, in project: Project) -> LeadEffort {
        chat?.leadEffort ?? newChatOptions(for: project).effort ?? .medium
    }

    func chatWorkflow(for chat: Chat?, in project: Project) -> String? {
        chat?.workflow ?? newChatOptions(for: project).workflow ?? config(for: project).preferences.defaultWorkflow ?? config(for: project).workflows.first?.id
    }

    func setLead(model: String, effort: LeadEffort, for chat: Chat?, in project: Project) {
        guard let chat else {
            var options = newChatOptions(for: project)
            options.model = model
            options.effort = effort
            setNewChatOptions(options, for: project)
            return
        }
        guard let chatID = chat.id else { return }
        dispatch("Couldn’t change the Lead’s model", ChatCommands.SetLead(chatID: chatID, model: model, effort: effort))
        leadChatRevision += 1
    }

    func setWorkflow(_ workflow: String, for chat: Chat?, in project: Project) {
        guard let chatID = chat?.id else {
            var options = newChatOptions(for: project)
            options.workflow = workflow
            setNewChatOptions(options, for: project)
            return
        }
        dispatch("Couldn’t change the workflow", ChatCommands.SetWorkflow(chatID: chatID, workflow: workflow))
        leadChatRevision += 1
    }

    func isLeadBusy(_ chat: Chat?) -> Bool {
        guard let session = chat.flatMap(leadSession(for:)) else { return false }
        return session.isRunning || session.isQueued
    }

    func stopLead(_ chat: Chat) {
        leadSession(for: chat)?.stop()
        for session in workingSessions(for: chat) { session.stop() }
    }

    func runLocalCommand(_ command: ChatCommand, in chat: Chat?) {
        guard let chat else { return }
        switch command {
        case .stop:
            stopLead(chat)
        case .retry:
            guard let run = latestRun(of: chat), heldForFailure(run) else {
                alert = AppAlert(title: "Nothing to retry", message: "No step in this chat is waiting after a failure.")
                return
            }
            resolveFailure(run, retry: true)
        default:
            return
        }
    }

    func projectFiles(_ project: Project) async -> [String] {
        guard let id = project.id else { return [] }
        if let cached = projectFileLists[id] { return cached }
        guard let git = git(for: project) else { return [] }
        let output = (try? await git.run(["ls-files"], in: project.url)) ?? ""
        let files = output.split(separator: "\n").map(String.init)
        projectFileLists[id] = files
        return files
    }
}

extension DaemonWorkspace {
    func commitsAhead(of run: Run) async -> Int? {
        guard let base = run.baseBranch, let project = project(withID: run.projectId), let git = git(for: project) else { return nil }
        guard let output = try? await git.run(["rev-list", "--count", "origin/\(base)..\(base)"], in: project.url) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
