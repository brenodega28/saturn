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

extension AppModel {
    var specStore: SpecStore { SpecStore(paths: daemonPaths) }

    func specDraft(for task: Chat) -> SpecFile? {
        guard let taskID = task.id else { return nil }
        let url = specStore.draftURL(projectId: task.projectId, taskId: taskID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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
        let document = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) }
        return document?.title ?? "Spec"
    }
}

struct SpecEditor: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var text = ""
    @State private var saved = ""
    @State private var loadedPath: String?
    @State private var problem: String?

    var body: some View {
        let document = try? SpecDocument(markdown: text)
        let isEditable = (document?.status ?? .draft) == .draft
        VStack(alignment: .leading, spacing: 10) {
            header(document, isEditable: isEditable)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
                .disabled(!isEditable)
                .accessibilityLabel("Spec draft text")
        }
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 20, trailing: 20))
        .task(id: path) { load() }
        .task(id: text) {
            guard text != saved, loadedPath == path else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear { if text != saved { save() } }
    }

    private func header(_ document: SpecDocument?, isEditable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(Theme.link).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(document?.title ?? "Spec draft").font(.system(size: 15, weight: .semibold))
                Text(subtitle(document, isEditable: isEditable))
                    .font(.system(size: 11.5))
                    .foregroundStyle(problem == nil ? Theme.secondaryText : Theme.danger)
            }
            Spacer(minLength: 8)
            if let status = document?.status {
                Text(status.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(status.color.opacity(0.14), in: Capsule())
            }
            if isEditable {
                Button("Save", action: save)
                    .buttonStyle(PillButtonStyle(height: 26))
                    .keyboardShortcut("s")
                    .disabled(text == saved)
                    .help("Save the draft; edits also save as you type")
            }
        }
    }

    private func subtitle(_ document: SpecDocument?, isEditable: Bool) -> String {
        if let problem { return problem }
        guard let document else { return "The front matter can’t be read yet. Keep the title: line between the --- lines." }
        let criteria = "\(document.checkedCount)/\(document.acceptanceCriteria.count) criteria"
        if !isEditable { return "\(criteria) · Committed on the run branch; this copy is read-only" }
        return "\(criteria) · \(text == saved ? "Saved" : "Editing…") · The lead reads your edits on its next turn"
    }

    private func load() {
        let contents = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
        text = contents
        saved = contents
        loadedPath = path
        problem = nil
    }

    private func save() {
        guard loadedPath == path else { return }
        do {
            try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            saved = text
            problem = nil
            model.leadChatRevision += 1
        } catch {
            problem = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}
