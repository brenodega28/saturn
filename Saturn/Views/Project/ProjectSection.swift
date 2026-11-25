import SaturnCore
import Foundation

extension SettingsSection: Codable {}

enum ProjectSection: Codable, Hashable, Sendable {
    case overview
    case chats
    case agents
    case workflows
    case changes
    case source
    case settings(SettingsSection)

    init(_ key: ProjectPageSection, settings: SettingsSection = .general) {
        switch key {
        case .overview: self = .overview
        case .chats: self = .chats
        case .agents: self = .agents
        case .workflows: self = .workflows
        case .changes: self = .changes
        case .source: self = .source
        case .settings: self = .settings(settings)
        }
    }

    init?(tool: MainTool, settings: SettingsSection = .general) {
        guard let key = ProjectPageSection(legacyTool: tool.rawValue) else { return nil }
        self.init(key, settings: settings)
    }

    var key: ProjectPageSection {
        switch self {
        case .overview: .overview
        case .chats: .chats
        case .agents: .agents
        case .workflows: .workflows
        case .changes: .changes
        case .source: .source
        case .settings: .settings
        }
    }

    var tool: MainTool? {
        switch self {
        case .overview, .chats: nil
        case .agents: .agents
        case .workflows: .workflows
        case .changes: .changes
        case .source: .code
        case .settings: .settings
        }
    }

    var tab: ProjectTab? { tool?.projectTab }
}

extension ProjectPageSection {
    static let navOrder: [ProjectPageSection] = [.overview, .chats, .agents, .workflows, .changes, .source, .settings]

    var title: String {
        switch self {
        case .overview: "Overview"
        case .chats: "Chats"
        case .agents: "Agents"
        case .workflows: "Workflows"
        case .changes: "Changes"
        case .source: "Source"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .chats: "bubble.left"
        case .agents: "person.2"
        case .workflows: "flowchart"
        case .changes: "plus.forwardslash.minus"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .settings: "slider.horizontal.3"
        }
    }
}

extension MainPageKind {
    var projectPage: ProjectRef? {
        if case .project(let ref, _) = self { return ref }
        return nil
    }

    var migratedToProjectPage: MainPageKind {
        guard case .tool(let tool, let project?) = self, let section = ProjectSection(tool: tool) else { return self }
        return .project(project, section: section)
    }
}
