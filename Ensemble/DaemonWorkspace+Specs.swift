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
        if connection.isRemote {
            return SpecReviewStatus(reason: "Ensemble is connected to a daemon on another Mac, so the spec opens read-only. Send feedback in the chat.")
        }
        do {
            return try await connection.send(ChatCommands.ReviewSpec(chatID: chatID))
        } catch {
            return SpecReviewStatus(reason: error.localizedDescription)
        }
    }
}
