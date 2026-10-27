import Foundation

struct EditorItem: Hashable, Codable, Identifiable {
    var kind: String
    var project: Int64?
    var ref: String?

    var id: String {
        [kind, project.map(String.init), ref].compactMap(\.self).joined(separator: "/")
    }

    static let inbox = EditorItem(kind: EditorKindID.inbox)
    static let usage = EditorItem(kind: EditorKindID.usage)
    static let quality = EditorItem(kind: EditorKindID.quality)

    static func section(_ tab: ProjectTab, in project: Int64) -> EditorItem {
        EditorItem(kind: EditorKindID.section, project: project, ref: tab.rawValue)
    }

    static func run(_ run: Int64, in project: Int64) -> EditorItem {
        EditorItem(kind: EditorKindID.run, project: project, ref: String(run))
    }

    static func agent(_ agent: Int64, in project: Int64) -> EditorItem {
        EditorItem(kind: EditorKindID.agent, project: project, ref: String(agent))
    }

    static func file(_ path: String, in project: Int64) -> EditorItem {
        EditorItem(kind: EditorKindID.file, project: project, ref: path)
    }

    var tab: ProjectTab? {
        kind == EditorKindID.section ? ref.flatMap(ProjectTab.init(rawValue:)) : nil
    }

    var number: Int64? {
        ref.flatMap(Int64.init)
    }
}

enum EditorKindID {
    static let inbox = "inbox"
    static let usage = "usage"
    static let quality = "quality"
    static let section = "section"
    static let run = "run"
    static let agent = "agent"
    static let file = "file"
}
