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
            Color.clear.frame(height: 20)
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

private struct ProjectGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let isOpen: Bool
    let needsYouTaskIDs: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if isOpen {
                ForEach(LeadRequest.partition(model.leadRequests(in: project)).open) { request in
                    RequestRow(request: request, project: project, needsYouTaskIDs: needsYouTaskIDs)
                }
                Button { model.startNewChat(in: project) } label: {
                    Text("+ New chat")
                        .font(.system(size: 12.5))
                        .foregroundStyle(V4.link)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Start a new chat with the lead in \(project.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
    }

    private var header: some View {
        let location = "Local · \((project.path as NSString).abbreviatingWithTildeInPath)"
        let attention = attentionColor
        return Button { model.expand(project) } label: {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.22)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                V4Icon(glyph: .laptop, size: 12, lineWidth: 2)
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
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Divider()
            Button("Close Project") { model.close(project) }
        }
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint(attention == nil ? "" : "Something needs you")
    }

    private var attentionColor: Color? {
        let items = model.inbox.items.filter { $0.projectId == project.id }
        if items.contains(where: { AppModel.needsYouKinds.contains($0.kind) }) { return V4.orange }
        if items.contains(where: { $0.kind == .failure }) { return Color(hex: 0xFF5A4E) }
        return nil
    }
}

private struct RequestRow: View {
    @Environment(AppModel.self) private var model
    let request: ProjectTask
    let project: Project
    let needsYouTaskIDs: Set<Int64>
    @State private var isHovered = false

    var body: some View {
        let run = model.latestRun(of: request)
        let title = request.title.isEmpty ? "Request #\(request.id ?? 0)" : request.title
        let meta = model.requestStatusLabel(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
        let dot = model.statusColor(of: request, latestRun: run, needsYouTaskIDs: needsYouTaskIDs)
        let badge = badgeCount(latestRun: run)
        let isCurrent = model.selectedRequestID == request.id && model.mainScreen.isChat
        Button { model.showChat(request) } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(V4.leadGradient)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .bottomTrailing) {
                        ZStack {
                            Circle().fill(Color(hex: 0x2C2D32)).frame(width: 12, height: 12)
                            Circle().fill(dot).frame(width: 8, height: 8)
                        }
                        .offset(x: 2, y: 2)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: isCurrent || badge > 0 ? .semibold : .medium))
                        .foregroundStyle(.white)
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(V4.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if badge > 0 && !isCurrent {
                    Text("\(badge)")
                        .font(V4.monospaced(10.5, weight: .bold))
                        .foregroundStyle(V4.orangeText)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(V4.orange.opacity(0.2), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 40)
            .background(isCurrent ? V4.selected : isHovered ? Color.white.opacity(0.05) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu { RequestCloseMenu(request: request, project: project) }
        .help("\(title) — \(meta)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chat \(title), \(meta)\(badge > 0 ? ", \(badge) need\(badge == 1 ? "s" : "") you" : "")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func badgeCount(latestRun: Run?) -> Int {
        guard let id = request.id else { return 0 }
        let count = model.needsYouItems.filter { model.taskID(of: $0) == id }.count
        if count > 0 { return count }
        return model.requestNeedsYou(request, latestRun: latestRun, needsYouTaskIDs: needsYouTaskIDs) ? 1 : 0
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model

    private struct Item: Identifiable {
        let id: String
        let title: String
        let glyph: V4Glyph
        var badge = 0
        var isActive = false
        let action: () -> Void
    }

    var body: some View {
        let screen = model.mainScreen
        let items = [
            item(.inbox, glyph: .inbox, badge: model.inboxCount, screen: screen),
            item(.changes, glyph: .changes, badge: changesCount, screen: screen),
            Item(id: "search", title: "Search ⌘K", glyph: .search) { model.openPalette() },
            item(.agents, glyph: .agents, screen: screen),
            item(.tasks, glyph: .tasks, screen: screen),
            item(.workflows, glyph: .workflows, screen: screen),
            item(.code, glyph: .code, screen: screen),
            item(.usage, glyph: .usage, screen: screen),
            item(.settings, glyph: .settings, screen: screen),
        ]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 28), spacing: 4), count: Self.columns), spacing: 4) {
            ForEach(items) { item in
                ToolButton(title: item.title, glyph: item.glyph, badge: item.badge, isActive: item.isActive, action: item.action)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private static let columns = 6

    private var changesCount: Int {
        guard let id = model.currentProject?.id else { return 0 }
        return ProjectOutline.changesBadge(waiting: model.inbox.items.filter { $0.projectId == id })?.count ?? 0
    }

    private func item(_ tool: MainTool, glyph: V4Glyph, badge: Int = 0, screen: MainScreen) -> Item {
        Item(id: tool.rawValue, title: tool.title, glyph: glyph, badge: badge, isActive: isActive(tool, screen: screen)) { model.open(tool) }
    }

    private func isActive(_ tool: MainTool, screen: MainScreen) -> Bool {
        if screen == .tool(tool) { return true }
        if case .agent = screen { return tool == .agents }
        return false
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
