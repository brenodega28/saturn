import SaturnCore
import Foundation
import SwiftUI

extension AppModel {
    static var missingChatAlert: AppAlert {
        AppAlert(title: "Couldn’t open the chat link", message: "It may have been deleted, or its project is no longer on this Mac.")
    }

    static func missingChatAlert(on machine: String) -> AppAlert {
        AppAlert(title: "Couldn’t open the chat link", message: "The chat isn’t on \(machine), or that machine isn’t connected.")
    }

    func open(_ link: ChatLink) {
        if let daemon = link.daemon {
            openOnMachine(link, daemon: daemon)
            return
        }
        let preferred = activePage.flatMap { workspace(of: $0.kind) }
        let candidates = [preferred, local].compactMap(\.self) + orderedWorkspaces
        guard let workspace = candidates.first(where: { $0.hasChat(link.requestID) }) else {
            alert = Self.missingChatAlert
            return
        }
        workspace.open(link)
    }

    private func openOnMachine(_ link: ChatLink, daemon: DaemonID) {
        guard let workspace = workspace(for: daemon), workspace.hasChat(link.requestID) else {
            alert = Self.missingChatAlert(on: machineName(of: daemon))
            return
        }
        workspace.open(link)
    }

    private func machineName(of daemon: DaemonID) -> String {
        workspace(for: daemon)?.displayName ?? knownDaemons.first { $0.id == daemon }?.displayName ?? "its machine"
    }

    func highlight(for chat: Chat, in workspace: DaemonWorkspace) -> ChatLink? {
        guard let link = chatHighlight, link.requestID == chat.id, link.daemon == workspace.id else { return nil }
        return link
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
            alert = link.daemon == nil ? AppModel.missingChatAlert : AppModel.missingChatAlert(on: displayName)
            return
        }
        let messageIDs = Set(((try? database.leadMessages(taskId: link.requestID)) ?? []).compactMap(\.id))
        app.chatHighlight = ChatLink(requestID: link.requestID, messageID: link.messageID.flatMap { messageIDs.contains($0) ? $0 : nil }, daemon: id)
        showRequest(id: link.requestID, inProjectID: projectID)
    }

    func copyLink(to task: Chat, message: LeadMessage? = nil) {
        guard let requestID = task.id else { return }
        copyToPasteboard(ChatLink(requestID: requestID, messageID: message?.id, daemon: id).url.absoluteString)
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
        register(MenuCommand(id: "file.copy-chat-link", title: "Copy Link to Chat", menu: "File", section: 2, order: 0, keywords: "url share reference request saturn",
                                  isEnabled: { $0.model.chatRequestForLink != nil }) { $0.model.copyLinkToSelectedChat() })
    }
}
