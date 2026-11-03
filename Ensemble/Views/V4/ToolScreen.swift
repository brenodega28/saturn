import EnsembleCore
import EnsembleUI
import SwiftUI

extension EnvironmentValues {
    @Entry var isInWorkbench = false
}

struct ToolScreen<Accessory: View, Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let accessory: Accessory
    let content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.goBack() } label: {
                    HStack(spacing: 4) {
                        V4Icon(glyph: .back, size: 12, lineWidth: 2.4)
                        Text("Back")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(backLabel) (⌘[)")
                .accessibilityLabel(backLabel)
                Text(title)
                    .font(V4.display(14))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.showsScreenHeader, false)
        }
    }

    private var backLabel: String {
        let screen = model.mainScreen
        if case .spec = screen { return "Back" }
        if case .tool(let tool) = model.mainWindow.back, screen != .tool(tool) { return "Back to \(tool.title)" }
        return "Back to chat"
    }
}

extension ToolScreen where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

struct MiddleColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let project = model.currentProject {
            switch model.mainScreen {
            case .chat:
                ChatColumn(project: project)
            case .tool(let tool):
                ToolScreen(title: tool.title) {
                    if tool == .usage {
                        usageSwitch
                    } else if let tab = tool.projectTab {
                        ProjectScreenAccessory(project: project, tab: tab)
                    }
                } content: {
                    toolContent(tool, project: project)
                }
            case .run(let runID):
                ToolScreen(title: model.run(withID: runID).map { "Run · \($0.displayTitle)" } ?? "Run") {
                    RunDetailView(runID: runID, project: project)
                        .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
                        .environment(\.isInWorkbench, true)
                }
            case .agent(let agentID):
                if let session = model.agentSessions(in: project).first(where: { $0.id == agentID }) {
                    ToolScreen(title: model.displayName(of: session.agent, in: project)) {
                        AgentSessionView(session: session, project: project)
                            .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
                    }
                } else {
                    ToolScreen(title: MainTool.agents.title) {
                        toolContent(.agents, project: project)
                    }
                }
            case .spec(let path):
                ToolScreen(title: "Spec · \(model.specTitle(atPath: path))") {
                    SpecEditor(path: path)
                }
            }
        }
    }

    @ViewBuilder
    private func toolContent(_ tool: MainTool, project: Project) -> some View {
        switch tool {
        case .inbox:
            InboxView()
        case .usage:
            if model.selection == .quality { QualityView() } else { UsageView() }
        default:
            if let tab = tool.projectTab {
                ProjectScreen(project: project, tab: tab)
                    .environment(\.isInWorkbench, tool == .code)
            }
        }
    }

    private var usageSwitch: some View {
        HStack(spacing: 2) {
            ForEach([SidebarItem.usage, .quality], id: \.self) { item in
                let isOn = model.selection == item
                Button {
                    model.selection = item
                } label: {
                    Text(item == .usage ? "Usage" : "Quality")
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(isOn ? Color.white.opacity(0.16) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
