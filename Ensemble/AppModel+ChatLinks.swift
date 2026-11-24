import EnsembleCore
import Foundation
import SwiftUI

extension AppModel {
    static var missingChatAlert: AppAlert {
        AppAlert(title: "Couldn’t open the chat link", message: "It may have been deleted, or its project is no longer on this Mac.")
    }

    func open(_ link: ChatLink) {
        let preferred = activePage.flatMap { workspace(of: $0.kind) }
        let candidates = [preferred, local].compactMap(\.self) + orderedWorkspaces
        guard let workspace = candidates.first(where: { $0.hasChat(link.requestID) }) else {
            alert = Self.missingChatAlert
            return
        }
        workspace.open(link)
    }

    var chatRequestForLink: Chat? {
        focusedChat
    }

    func copyLinkToSelectedChat() {
        if let request = chatRequestForLink { currentWorkspace.copyLink(to: request) }
    }

    var chatLinkOpenURLAction: OpenURLAction {
        OpenURLAction { [weak self] url in
            guard let link = ChatLink(url: url) else { return .systemAction }
            self?.open(link)
            return .handled
        }
    }

}

extension DaemonWorkspace {
    func hasChat(_ chatID: Int64) -> Bool {
        guard let task = try? database.task(id: chatID) else { return false }
        return (try? database.leadRequests(projectId: task.projectId))?.contains { $0.id == chatID } == true
    }

    func open(_ link: ChatLink) {
        guard let task = try? database.task(id: link.requestID), let project = projectForLink(id: task.projectId), let projectID = project.id else {
            alert = AppModel.missingChatAlert
            return
        }
        let messageIDs = Set(((try? database.leadMessages(taskId: link.requestID)) ?? []).compactMap(\.id))
        app.chatHighlight = ChatLink(requestID: link.requestID, messageID: link.messageID.flatMap { messageIDs.contains($0) ? $0 : nil })
        showRequest(id: link.requestID, inProjectID: projectID)
    }

    func copyLink(to task: Chat, message: LeadMessage? = nil) {
        guard let requestID = task.id else { return }
        copyToPasteboard(ChatLink(requestID: requestID, messageID: message?.id).url.absoluteString)
    }

    private func projectForLink(id: Int64) -> Project? {
        if let project = project(withID: id) { return project }
        reloadProjects()
        if let project = project(withID: id) { return project }
        guard !isRemote, let stored = try? database.project(id: id), FileManager.default.fileExists(atPath: stored.path) else { return nil }
        Task { await openFolder(stored.url) }
        return stored
    }
}

extension CommandRegistry {
    func registerChatLinkCommands() {
        register(MenuCommand(id: "file.copy-chat-link", title: "Copy Link to Chat", menu: "File", section: 2, order: 0, keywords: "url share reference request ensemble",
                                  isEnabled: { $0.model.chatRequestForLink != nil }) { $0.model.copyLinkToSelectedChat() })
    }
}
