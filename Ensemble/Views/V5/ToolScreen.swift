import EnsembleCore
import EnsembleUI
import SwiftUI

extension EnvironmentValues {
    @Entry var isInWorkbench = false
}

struct ToolScreen<Accessory: View, Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let project: Project?
    let accessory: Accessory
    let content: Content

    init(title: String, project: Project? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.project = project
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let project = project ?? model.currentProject {
                    ProjectTile(project: project, size: 16)
                    Text(project.name).foregroundStyle(Tokens.text2)
                    Text("/").foregroundStyle(Tokens.text3)
                }
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            .font(.system(size: 13.5))
            .padding(EdgeInsets(top: 12, leading: 22, bottom: 8, trailing: 16))
            .frame(minHeight: 52)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.showsScreenHeader, false)
        }
    }
}

extension ToolScreen where Accessory == EmptyView {
    init(title: String, project: Project? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, project: project, accessory: { EmptyView() }, content: content)
    }
}

struct MiddleColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let isNarrow = geometry.size.width < Tokens.Size.narrowWindow - Tokens.Size.sidebar
            VStack(spacing: 0) {
                PageTabStrip(isNarrow: isNarrow)
                if let page = model.activePage {
                    HStack(spacing: 0) {
                        PageContent(page: page)
                            .id(page.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.pages.isSideBarOpen, !isNarrow, let chat = model.sideBarChat(for: page.kind),
                           let project = model.project(withID: chat.projectId) {
                            ChatSideBar(project: project, chat: chat)
                        }
                    }
                } else {
                    NoPagesView()
                }
            }
        }
        .overlay { PageFileFinder() }
    }
}

private struct PageContent: View {
    @Environment(AppModel.self) private var model
    let page: MainPage

    var body: some View {
        switch page.kind {
        case .tool(.usage, _):
            ToolScreen(title: MainTool.usage.title) { UsageView() }
        default:
            if let project = model.project(of: page.kind) {
                content(project)
            } else {
                PageUnavailable { model.pages.close(page.id) }
            }
        }
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        switch page.kind {
        case .chat:
            ChatColumn(project: project)
        case .terminal(_, let directory):
            TerminalPage(pageID: page.id, project: project, directory: directory)
        case .code(_, let path):
            CodePage(pageID: page.id, project: project, path: path)
        case .tool(let tool, _):
            ToolScreen(title: tool.title, project: project) {
                if let tab = tool.projectTab {
                    ProjectScreenAccessory(project: project, tab: tab)
                }
            } content: {
                if let tab = tool.projectTab {
                    ProjectScreen(project: project, tab: tab)
                        .environment(\.isInWorkbench, tool == .code)
                }
            }
        case .run(let runID):
            ToolScreen(title: model.title(of: page.kind), project: project) {
                RunDetailView(runID: runID, project: project)
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
                    .environment(\.isInWorkbench, true)
            }
        case .agent(let agentID):
            if let session = model.agentSessions(in: project).first(where: { $0.id == agentID }) {
                ToolScreen(title: model.displayName(of: session.agent, in: project), project: project) {
                    AgentSessionView(session: session, project: project)
                        .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
                }
            } else {
                PageUnavailable { model.pages.close(page.id) }
            }
        case .spec(let path, _):
            ToolScreen(title: model.title(of: page.kind), project: project) {
                SpecReviewPage(path: path, project: project)
            }
        }
    }
}

private struct PageUnavailable: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("This page is no longer available").font(.system(size: 15, weight: .semibold))
            Text("What it showed was deleted or closed.").font(.system(size: 13)).foregroundStyle(Tokens.text2)
            Button("Close Tab", action: close).buttonStyle(SecondaryPillStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoPagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("No pages open").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tokens.text)
            Text("Pick a chat in the sidebar, or open something new.").font(.system(size: 13.5)).foregroundStyle(Tokens.text2)
            HStack(spacing: 8) {
                Button("New chat") { model.requestNewChat() }.buttonStyle(PrimaryPillStyle())
                Button("Terminal") { model.openTerminal() }.buttonStyle(SecondaryPillStyle())
                Button("Open file…") { model.openFileFinder() }.buttonStyle(SecondaryPillStyle())
            }
            .disabled(model.currentProject == nil)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct PageFileFinder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isPageFinderShown, let project = model.currentProject {
            let browser = model.codeBrowser(for: project)
            if browser.isFinderPresented {
                CodeFinder(browser: browser) { path, line in
                    model.isPageFinderShown = false
                    model.openFile(path, in: project, line: line)
                }
                .onDisappear { model.isPageFinderShown = false }
            }
        }
    }
}
