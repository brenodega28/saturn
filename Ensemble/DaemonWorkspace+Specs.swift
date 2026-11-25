import EnsembleCore
import EnsembleUI
import Foundation
import SwiftUI

extension SpecStatus {
    var color: Color {
        switch self {
        case .draft: Theme.info
        case .approved: Theme.paused
        case .inProgress: Theme.warning
        case .done: Theme.successText
        case .rejected: Theme.danger
        }
    }
}

extension DaemonWorkspace {
    var specStore: SpecStore {
        if connection.isRemote, let root = connection.environment.dataDirectory {
            return SpecStore(paths: AppPaths(root: URL(fileURLWithPath: root, isDirectory: true)))
        }
        return SpecStore(paths: app.daemonPaths)
    }

    func specDraftURL(for task: Chat) -> URL? {
        guard let taskID = task.id else { return nil }
        let url = specStore.draftURL(projectId: task.projectId, taskId: taskID)
        guard connection.isRemote else { return url }
        return cachedDaemonFile(.specDraft, id: "\(task.projectId)/\(taskID)", name: url.lastPathComponent, maximumAge: 3)
    }

    func specDraft(for task: Chat) -> SpecFile? {
        guard let taskID = task.id, let url = specDraftURL(for: task), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let document = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) }
        return SpecFile(url: url, relativePath: specStore.committedPath(projectId: task.projectId, taskId: taskID), document: document, taskId: taskID)
    }

    func specFiles(in project: Project) -> [SpecFile] {
        guard let id = project.id else { return [] }
        let committed = SpecStore.files(in: project.filesRoot, config: ProjectConfigLoader.loadSpecs(repository: project.filesRoot))
        let paths = Set(committed.compactMap(\.relativePath))
        let drafts = specStore.drafts(projectId: id).filter { draft in draft.relativePath.map { !paths.contains($0) } ?? true }
        return drafts + committed
    }

    func openSpec(_ file: SpecFile, in project: Project) {
        if !file.isDraft, let path = file.relativePath {
            openFile(path, in: project)
        } else {
            openSpecScreen(file.url.path, in: project)
        }
    }

    func specTitle(atPath path: String) -> String {
        specDocument(atPath: path)?.title ?? "Spec"
    }

    func specDocument(atPath path: String) -> SpecDocument? {
        (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) }
    }

    func specChatID(atPath path: String) -> Int64? {
        Int64(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    func openSpecTab(for task: Chat, in project: Project) {
        guard let url = specDraftURL(for: task) else { return }
        openSpecScreen(url.path, in: project)
    }

    func specDrafted(projectId: Int64, taskId: Int64) {
        guard let project = project(withID: projectId), let task = (try? database.task(id: taskId)) ?? nil else { return }
        leadChatRevision += 1
        openSpecTab(for: task, in: project)
    }

    func specReview(chatID: Int64, in project: Project) async -> SpecReviewStatus {
        if project.isRemote { return SpecReviewStatus(reason: SpecReviewError.remote.localizedDescription) }
        let review: SpecReviewStatus
        do {
            review = try await connection.send(ChatCommands.ReviewSpec(chatID: chatID))
        } catch {
            return SpecReviewStatus(reason: error.localizedDescription)
        }
        guard connection.isRemote else { return review }
        guard review.url != nil, let port = review.port else {
            closeSpecTunnel(chatID: chatID)
            return review
        }
        let failure = "Couldn’t forward the Lavish page from \(displayName) to this Mac, so the spec opens read-only"
        guard let tunnel = specTunnel(remotePort: port) else { return SpecReviewStatus(reason: "\(failure).") }
        do {
            let opening = specTunnelOpenings[port] ?? Task { try await tunnel.open() }
            specTunnelOpenings[port] = opening
            defer { specTunnelOpenings[port] = nil }
            let local = try await opening.value
            specTunnelPorts[chatID] = port
            return review.forwarded(to: local)
        } catch {
            return SpecReviewStatus(reason: "\(failure): \(error.localizedDescription)")
        }
    }

    func specTunnel(remotePort: Int) -> SSHPortForward? {
        if let tunnel = specTunnels[remotePort] { return tunnel }
        guard let destination = connection.destination else { return nil }
        let tunnel = SSHPortForward(client: SSHClient(destination: destination, runner: app.runner), remotePort: remotePort)
        specTunnels[remotePort] = tunnel
        return tunnel
    }

    func closeSpecTunnel(chatID: Int64) {
        guard let port = specTunnelPorts.removeValue(forKey: chatID), !specTunnelPorts.values.contains(port) else { return }
        specTunnels.removeValue(forKey: port)?.stop()
    }

    func closeSpecTunnels() {
        specTunnels.values.forEach { $0.stop() }
        specTunnels = [:]
        specTunnelPorts = [:]
    }

    func approveSpec(for task: Chat, in project: Project) {
        guard let taskID = task.id else { return }
        if task.isClosed {
            alert = AppAlert(title: "Couldn’t approve the spec", message: "This request is closed. Send a message to reopen it first.")
            return
        }
        do {
            try ensureWithinBudget(project)
        } catch {
            alert = AppAlert(title: "Couldn’t approve the spec", message: error.localizedDescription)
            return
        }
        Task {
            await command("Couldn’t approve the spec", ChatCommands.ApproveSpec(chatID: taskID))
            closeSpecTunnel(chatID: taskID)
            leadChatRevision += 1
        }
    }

    func relayChat(_ relayID: UUID, daemon: DaemonID, request: ChatReadRequest) async {
        guard daemon != id, let target = app.workspace(for: daemon) else { return }
        var answer = RelayedChat(relayID: relayID, daemon: daemon)
        if target.isConnected {
            do {
                answer.text = try await target.send(ChatCommands.Read(request: request))
            } catch {
                answer.error = error.localizedDescription
            }
        } else {
            answer.error = "\(target.displayName) isn’t connected to Ensemble right now."
        }
        try? await send(ChatCommands.AnswerRelay(answer: answer))
    }

    var peerName: String {
        connection.destination.map(SSHDestination.displayName) ?? connection.name
    }
}

extension AppModel {
    func shareDaemonPeers() {
        let connected = orderedWorkspaces.filter(\.isConnected)
        for workspace in connected {
            let peers = connected.filter { $0.id != workspace.id }.map { DaemonPeer(id: $0.id, name: $0.peerName) }
            Task { try? await workspace.send(ChatCommands.SetPeers(peers: peers)) }
        }
    }
}
