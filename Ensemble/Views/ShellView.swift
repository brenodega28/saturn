import EnsembleCore
import EnsembleUI
import SwiftUI

struct ShellView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 216, ideal: 244, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.windowBackground)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .inbox:
            InboxView()
        case .usage:
            AppScreen(title: "Usage", subtitle: "This week · \(model.weeklySpend.formatted(.currency(code: "USD")))") {
                EmptyState("No spend yet", message: "Spend by project, run, role and model shows up here once agents start running.")
            }
        case .project:
            if let project = model.selectedProject {
                ProjectView(project: project)
            }
        case nil:
            EmptyState("Pick a project", message: "Choose a project in the sidebar, or open a folder with ⌘O.")
        }
    }
}

struct AppScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).kerning(-0.2)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .frame(minHeight: 52, alignment: .leading)
            content
        }
        .padding(EdgeInsets(top: 10, leading: 26, bottom: 24, trailing: 22))
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            InboxSidebarRow()
                .tag(SidebarItem.inbox)

            Section {
                ForEach(model.openProjects) { project in
                    if let id = project.id {
                        ProjectRow(project: project)
                            .tag(SidebarItem.project(id))
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Menu {
                        Button("Open Folder…") { model.isOpenPanelPresented = true }
                        Button("Clone Repository…") { model.isClonePresented = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Add project")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button {
                model.isPalettePresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text("Search or run…").frame(maxWidth: .infinity, alignment: .leading)
                    Text("⌘K").font(.system(size: 11))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.selection = .usage
            } label: {
                HStack {
                    Text("This week").fontWeight(.semibold)
                    Spacer()
                    Text(model.weeklySpend.formatted(.currency(code: "USD"))).foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 12))
                .padding(12)
                .background(model.selection == .usage ? Theme.accent.opacity(0.28) : Color.white.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Usage, this week \(model.weeklySpend.formatted(.currency(code: "USD")))")
            .padding(10)
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let worktrees = model.state(for: project).worktrees.count
        Label {
            HStack {
                Text(project.name)
                Spacer()
                if worktrees > 0 {
                    Text("\(worktrees)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .help("\(worktrees) worktrees in .crew/")
                }
            }
        } icon: {
            Image(systemName: "folder").foregroundStyle(Theme.link)
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("Close Project") { model.close(project) }
        }
    }
}
