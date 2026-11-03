import EnsembleCore
import Foundation
import SwiftUI

extension AppModel {
    static var missingChatAlert: AppAlert {
        AppAlert(title: "Couldn’t open the chat link", message: "It may have been deleted, or its project is no longer on this Mac.")
    }

    func open(_ link: ChatLink) {
        guard let task = try? database.task(id: link.requestID),
              (try? database.leadRequests(projectId: task.projectId))?.contains(where: { $0.id == link.requestID }) == true,
              let project = projectForLink(id: task.projectId) else {
            alert = Self.missingChatAlert
            return
        }
        guard let projectID = project.id else { return }
        let messageIDs = Set(((try? database.leadMessages(taskId: link.requestID)) ?? []).compactMap(\.id))
        chatHighlight = ChatLink(requestID: link.requestID, messageID: link.messageID.flatMap { messageIDs.contains($0) ? $0 : nil })
        mainWindow.spec = nil
        runDetailIDs[projectID] = nil
        showRequest(id: link.requestID, inProjectID: projectID)
        selection = .project(projectID)
        tabs[projectID] = .lead
    }

    func copyLink(to task: ProjectTask, message: LeadMessage? = nil) {
        guard let requestID = task.id else { return }
        copyToPasteboard(ChatLink(requestID: requestID, messageID: message?.id).url.absoluteString)
    }

    var chatRequestForLink: ProjectTask? {
        currentProject.flatMap(selectedRequest(in:))
    }

    func copyLinkToSelectedChat() {
        if let request = chatRequestForLink { copyLink(to: request) }
    }

    var chatLinkOpenURLAction: OpenURLAction {
        OpenURLAction { [weak self] url in
            guard let link = ChatLink(url: url) else { return .systemAction }
            self?.open(link)
            return .handled
        }
    }

    private func projectForLink(id: Int64) -> Project? {
        if let project = project(withID: id) { return project }
        reloadProjects()
        if let project = project(withID: id) { return project }
        guard let stored = try? database.project(id: id), FileManager.default.fileExists(atPath: stored.path),
              (try? database.openProject(at: stored.url)) != nil else { return nil }
        reloadProjects()
        guard let project = project(withID: id) else { return nil }
        Task { await refresh(project) }
        return project
    }
}

extension CommandRegistry {
    func registerChatLinkCommands() {
        register(MenuCommand(id: "file.copy-chat-link", title: "Copy Link to Chat", menu: "File", section: 2, order: 0, keywords: "url share reference request ensemble",
                                  isEnabled: { $0.model.chatRequestForLink != nil }) { $0.model.copyLinkToSelectedChat() })
    }
}
