import EnsembleCore
import EnsembleUI
import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.inbox.groups(projects: model.openProjects)
        AppScreen(title: "Inbox", subtitle: subtitle) {
            if groups.isEmpty {
                EmptyState("Nothing waiting on you", message: "Agent questions, plan approvals, pin reviews and failures from every project land here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groups) { group in
                            InboxProjectSection(group: group)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var subtitle: String {
        let count = model.inboxCount
        return count == 0 ? "Across all projects" : "\(count) waiting on you · across all projects"
    }
}

private struct InboxProjectSection: View {
    let group: InboxGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.link).accessibilityHidden(true)
                Text(group.project.name).font(.system(size: 13, weight: .semibold))
                Text("\(group.items.count)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(group.items) { item in
                InboxItemCard(item: item)
            }
        }
    }
}

struct InboxSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.inboxCount
        Label {
            HStack {
                Text("Inbox").fontWeight(.semibold)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: 0x1A1205))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.warning, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: "tray")
        }
        .accessibilityLabel(count == 0 ? "Inbox" : "Inbox, \(count) waiting")
    }
}
