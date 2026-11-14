import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.engine.runs
        let needsYouTaskIDs = model.needsYouTaskIDs()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                AddProjectMenu()
            }
            .frame(height: 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.openProjects) { project in
                        ProjectGroup(project: project, isOpen: project.id == model.currentProject?.id, needsYouTaskIDs: needsYouTaskIDs)
                    }
                }
            }
            .scrollIndicators(.never)
            ToolRow()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(width: 236)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(V4.sidebarFill, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects")
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case agents = "Agents"
    case workflows = "Workflows"
    case changes = "Changes"
    case source = "Source"
    case settings = "Settings"

    var id: Self { self }

    static let groups: [(name: String, sections: [SidebarSection])] = [
        ("Work", [.chat]),
        ("Crew", [.agents, .workflows]),
        ("Review", [.changes, .source]),
        ("", [.settings]),
    ]

    var glyph: V4Glyph {
        switch self {
        case .chat: .chat
        case .agents: .agents
        case .workflows: .workflows
        case .changes: .changes
        case .source: .code
        case .settings: .settings
        }
    }

    var tool: MainTool? {
        switch self {
        case .chat: nil
        case .agents: .agents
        case .workflows: .workflows
        case .changes: .changes
        case .source: .code
        case .settings: .settings
        }
    }

    func isHighlighted(on screen: MainScreen) -> Bool {
        switch self {
        case .chat:
            return screen == .chat
        case .agents:
            if case .agent = screen { return true }
            return screen == .tool(.agents)
        default:
            return tool.map { screen == .tool($0) } ?? false
        }
    }

    func badgeDescription(_ count: Int) -> String {
        switch self {
        case .agents: "\(count) agent\(count == 1 ? "" : "s")"
        case .changes: "\(count) waiting for review"
        default: "\(count)"
        }
    }
}

private struct ProjectGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let isOpen: Bool
    let needsYouTaskIDs: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if isOpen {
                tree
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
    }

    private var tree: some View {
        let screen = model.mainScreen
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(SidebarSection.groups.enumerated()), id: \.offset) { _, group in
                if !group.name.isEmpty {
                    Text(group.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(V4.secondary)
                        .padding(EdgeInsets(top: 8, leading: 10, bottom: 2, trailing: 10))
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.sections) { section in
                    SectionRow(
                        section: section, title: section.rawValue,
                        badge: badge(for: section), isHighlighted: section.isHighlighted(on: screen), help: help(for: section)
                    ) {
                        activate(section)
                    }
                    if section == .chat {
                        ForEach(LeadRequest.partition(model.leadRequests(in: project)).open) { request in
                            RequestRow(request: request, project: project, needsYouTaskIDs: needsYouTaskIDs)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func activate(_ section: SidebarSection) {
        if let tool = section.tool {
            model.open(tool)
        } else {
            model.startNewChat(in: project)
        }
    }

    private func help(for section: SidebarSection) -> String {
        return section == .chat ? "Start a new chat with the lead in \(project.name)" : section.tool?.title ?? section.rawValue
    }

    private func badge(for section: SidebarSection) -> (count: Int, color: Color)? {
        let count: Int
        let color: Color
        switch section {
        case .agents:
            count = model.agentSessions(in: project).count
            color = V4.secondary
        case .changes:
            count = ProjectOutline.changesBadge(waiting: model.requests.items.filter { $0.projectId == project.id })?.count ?? 0
            color = V4.orange
        default:
            return nil
        }
        return count > 0 ? (count, color) : nil
    }

    private var header: some View {
        let location = project.isRemote ? "SSH · \(project.location)" : "Local · \((project.path as NSString).abbreviatingWithTildeInPath)"
        let attention = attentionColor
        return Button { model.expand(project) } label: {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.22)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                V4Icon(glyph: project.isRemote ? .server : .laptop, size: 12, lineWidth: 2)
                    .foregroundStyle(V4.secondary)
                    .help(location)
                    .accessibilityHidden(false)
                    .accessibilityLabel(location)
                if !isOpen, let attention {
                    Circle().fill(attention).frame(width: 6, height: 6).accessibilityHidden(true)
                }
            }
            .foregroundStyle(isOpen ? Color.white : V4.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show All Chats") { model.showRequestPage(inProjectID: project.id ?? -1) }
            if !project.isRemote {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            }
            Divider()
            Button("Close Project") { model.close(project) }
        }
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(attention == nil ? "" : "Something needs you")
    }

    private var attentionColor: Color? {
        let items = model.requests.items.filter { $0.projectId == project.id }
        if model.projectHasPendingApprovals(project) || items.contains(where: { AppModel.needsYouKinds.contains($0.kind) }) { return V4.orange }
        if items.contains(where: { $0.kind == .failure }) { return Color(hex: 0xFF5A4E) }
        return nil
    }
}

private struct SectionRow: View {
    let section: SidebarSection
    let title: String
    let badge: (count: Int, color: Color)?
    let isHighlighted: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                V4Icon(glyph: section.glyph, size: 15, lineWidth: 1.8)
                    .foregroundStyle(isHighlighted ? Color.white : V4.secondary)
                Text(title)
                    .font(.system(size: 13, weight: isHighlighted ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? Color.white : V4.label.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge {
                    Text("\(badge.count)")
                        .font(V4.monospaced(11, weight: .bold))
                        .foregroundStyle(badge.color)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovered ? Color.white.opacity(0.05) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.map { "\(section.rawValue), \(section.badgeDescription($0.count))" } ?? section.rawValue)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}

private struct RequestRow: View {
    @Environment(AppModel.self) private var model
    let request: Chat
    let project: Project
    let needsYouTaskIDs: Set<Int64>
    @State private var isHovered = false

    var body: some View {
        let run = model.latestRun(of: request)
        let title = request.title.isEmpty ? "Request #\(request.id ?? 0)" : request.title
        let meta = model.requestStatusLabel(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
        let dot = model.statusColor(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
        let approvals = model.pendingApprovalCount(of: request)
        let badge = badgeCount(latestRun: run, pendingApprovals: approvals)
        let isCurrent = model.selectedRequestID == request.id && model.mainScreen.isChat
        let needsYou = badge > 0 && !isCurrent
        Button { model.showChat(request) } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : V4.label.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(needsYou ? "Needs you" : Self.shortStatus(meta))
                    .font(.system(size: 11))
                    .foregroundStyle(needsYou ? V4.orangeText : V4.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.leading, 34)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(isCurrent ? V4.selected : isHovered ? Color.white.opacity(0.05) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { RequestCloseMenu(request: request, project: project) }
        .help("\(title) — \(meta)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, meta: meta, badge: badge, pendingApprovals: approvals))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    static func shortStatus(_ meta: String) -> String {
        meta.components(separatedBy: " · ").first ?? meta
    }

    static func accessibilityLabel(title: String, meta: String, badge: Int, pendingApprovals: Int) -> String {
        var parts = ["Chat \(title)", meta]
        if pendingApprovals > 0 {
            parts.append("\(pendingApprovals) command approval\(pendingApprovals == 1 ? "" : "s") pending")
        }
        if badge > 0 {
            parts.append("\(badge) need\(badge == 1 ? "s" : "") you")
        }
        return parts.joined(separator: ", ")
    }

    private func badgeCount(latestRun: Run?, pendingApprovals: Int) -> Int {
        guard let id = request.id else { return 0 }
        let count = model.needsYouItems.filter { model.taskID(of: $0) == id }.count + pendingApprovals
        if count > 0 { return count }
        return model.requestNeedsYou(request, latestRun: latestRun, needsYouTaskIDs: needsYouTaskIDs) ? 1 : 0
    }
}

private struct AddProjectMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Open Folder…") { model.isOpenPanelPresented = true }
            Button("Open SSH Folder…") { model.isRemoteFolderPresented = true }
            Button("Clone Repository…") { model.isClonePresented = true }
            Divider()
            Button("New Project…") { model.newProject() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(V4.secondary)
                .frame(width: 22, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a project")
        .accessibilityLabel("Add a project")
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let screen = model.mainScreen
        HStack(spacing: 4) {
            ToolButton(title: "Search ⌘K", glyph: .search, badge: 0, isActive: false) { model.openPalette() }
            ToolButton(title: "Usage", glyph: .usage, badge: 0, isActive: screen == .tool(.usage)) { model.open(.usage) }
            ToolButton(title: "App settings ⌘,", glyph: .settings, badge: 0, isActive: false) { openSettings() }
        }
        .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }
}

private struct ToolButton: View {
    let title: String
    let glyph: V4Glyph
    let badge: Int
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            V4Icon(glyph: glyph, size: 15, lineWidth: 1.8)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(isActive ? Color.white.opacity(0.12) : isHovered ? Color.white.opacity(0.06) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(V4.onOrange)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(V4.orange, in: Capsule())
                            .padding(.top, 3)
                            .padding(.trailing, 6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : V4.label.opacity(0.8))
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
