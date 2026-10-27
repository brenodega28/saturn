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
            UsageView()
        case .quality:
            QualityView()
        case .project:
            if let project = model.selectedProject {
                ProjectView(project: project)
            }
        case nil:
            EmptyState("Pick a project", message: "Choose a project in the sidebar, or open a folder with ⌘O.")
        }
    }
}

struct AppScreen<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    let accessory: Accessory
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .bold)).kerning(-0.2)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 52, alignment: .leading)
            content
        }
        .padding(EdgeInsets(top: 10, leading: 26, bottom: 24, trailing: 22))
    }
}

extension AppScreen where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}
