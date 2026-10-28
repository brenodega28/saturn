import EnsembleCore
import EnsembleUI
import SwiftUI

struct SpecsNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var files: [SpecFile] = []

    var body: some View {
        let project = model.currentProject
        Group {
            if let project {
                content(project)
            } else {
                NavigatorEmpty(title: "No project", message: "Open a project to see its specs.")
            }
        }
        .task(id: project?.id) {
            files = []
            while !Task.isCancelled {
                if let project {
                    let latest = model.specFiles(in: project)
                    if latest != files { files = latest }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        let drafts = files.filter(\.isDraft)
        let committed = files.filter { !$0.isDraft }
        if files.isEmpty {
            NavigatorEmpty(
                title: "No specs yet",
                message: "Ask the lead in a chat to draft a spec. Drafts show up here, and specs land in \(ProjectConfigLoader.loadSpecs(repository: project.url).folder)/ when a run starts."
            )
        } else {
            NavigatorList {
                if !drafts.isEmpty {
                    NavigatorSection(title: "In chats", count: drafts.count) {
                        ForEach(drafts) { file in SpecRow(file: file, project: project, isSelected: isSelected(file, in: project)) }
                    }
                }
                if !committed.isEmpty {
                    NavigatorSection(title: ProjectConfigLoader.loadSpecs(repository: project.url).folder + "/", count: committed.count) {
                        ForEach(committed) { file in SpecRow(file: file, project: project, isSelected: isSelected(file, in: project)) }
                    }
                }
            }
        }
    }

    private func isSelected(_ file: SpecFile, in project: Project) -> Bool {
        guard let id = project.id, let active = state.active else { return false }
        if file.isDraft { return active == .spec(file.url, in: id) }
        return file.relativePath.map { active == .file($0, in: id) } ?? false
    }
}

private struct SpecRow: View {
    @Environment(AppModel.self) private var model
    let file: SpecFile
    let project: Project
    let isSelected: Bool

    var body: some View {
        let document = file.document
        NavigatorRow(
            title: document?.title ?? file.url.lastPathComponent,
            detail: detail(document),
            badge: badge(document),
            badgeColor: document.map { file.isDraft && $0.status == .draft ? Theme.info : $0.status.color } ?? Theme.tertiaryText,
            isSelected: isSelected
        ) {
            model.openSpec(file, in: project)
        } leading: {
            Image(systemName: document == nil ? "doc" : "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(document?.status.color ?? Theme.tertiaryText)
                .frame(width: 14)
                .padding(.top, 2)
                .accessibilityHidden(true)
        }
        .help(file.relativePath ?? file.url.path)
    }

    private func badge(_ document: SpecDocument?) -> String {
        guard let document else { return "" }
        return document.status.title
    }

    private func detail(_ document: SpecDocument?) -> String {
        guard let document else { return file.relativePath ?? file.url.lastPathComponent }
        var parts: [String] = []
        if !document.acceptanceCriteria.isEmpty {
            parts.append("\(document.checkedCount)/\(document.acceptanceCriteria.count) criteria")
        }
        if !document.linkedRuns.isEmpty {
            parts.append((document.linkedRuns.count == 1 ? "Run " : "Runs ") + document.linkedRuns.map { "#\($0)" }.joined(separator: ", "))
        }
        if file.isDraft, parts.isEmpty { parts.append("Not started") }
        return parts.joined(separator: " · ")
    }
}
