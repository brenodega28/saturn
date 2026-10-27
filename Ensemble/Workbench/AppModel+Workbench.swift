import EnsembleCore
import Foundation

extension AppModel {
    var currentEditorItem: EditorItem? {
        switch sidebarDestination {
        case .inbox: .inbox
        case .usage: .usage
        case .quality: .quality
        case .section(let project, let tab):
            if tab == .agents, let agent = selectedAgents[project] {
                .agent(agent, in: project)
            } else {
                .section(tab, in: project)
            }
        case .run(let project, let run): .run(run, in: project)
        case .request(let project, _), .requests(let project): .section(.lead, in: project)
        case nil: nil
        }
    }

    func apply(_ item: EditorItem) {
        guard item != currentEditorItem else { return }
        switch item.kind {
        case EditorKindID.inbox:
            selection = .inbox
        case EditorKindID.usage:
            selection = .usage
        case EditorKindID.quality:
            selection = .quality
        case EditorKindID.section:
            guard let project = item.project, let tab = item.tab else { return }
            if tab == .agents { selectedAgents[project] = nil }
            if tab == .lead, tabs[project] == .lead, case .project(project) = selection, runDetailIDs[project] == nil { return }
            sidebarDestination = .section(project: project, tab: tab)
        case EditorKindID.run:
            guard let project = item.project, let run = item.number else { return }
            openRunDetail(runID: run, in: project)
        case EditorKindID.agent:
            guard let project = item.project, let agent = item.number else { return }
            runDetailIDs[project] = nil
            selectedAgents[project] = agent
            tabs[project] = .agents
            selection = .project(project)
        default:
            break
        }
    }

    func project(of item: EditorItem) -> Project? {
        item.project.flatMap(project(withID:))
    }

    func editorTitle(_ item: EditorItem) -> String {
        let title = WorkbenchRegistry.shared.editorKind(for: item)?.title(item, self) ?? item.kind.capitalized
        guard item.kind == EditorKindID.section, openProjects.count > 1, let project = project(of: item) else { return title }
        return "\(title) · \(project.name)"
    }

    func isAvailable(_ item: EditorItem) -> Bool {
        if item.project != nil, project(of: item) == nil { return false }
        return WorkbenchRegistry.shared.editorKind(for: item)?.isAvailable(item, self) ?? false
    }
}
