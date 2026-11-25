import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        if workspace.isShowingRequestPage(in: project) {
            ToolScreen(title: "Chats", project: project) {
                RequestListView(project: project)
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
            }
        } else {
            leadChat
        }
    }

    private func shows(_ alert: SystemAlert) -> Bool {
        if case .hostDisconnected = alert, workspace.isRemote { return false }
        return alert.affects(project)
    }

    private var leadChat: some View {
        let selected = workspace.selectedRequest(in: project)
        let newRequestDelivering = selected == nil ? workspace.sendsDelivering(to: workspace.leadSendTarget(for: nil, in: project)) : []
        return VStack(spacing: 0) {
            ForEach(model.systemAlerts.filter(shows)) { alert in
                ChatAlertBanner(alert: alert)
                    .frame(maxWidth: Tokens.Size.transcript)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
            }
            Group {
                if let selected {
                    RequestChat(task: selected, project: project)
                        .id(selected.id)
                } else if !newRequestDelivering.isEmpty {
                    NewRequestDeliveringSends(delivering: newRequestDelivering)
                } else {
                    NewRequestIntro(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if model.isAppOutputShown, selected != nil {
                        AppOutputPanel(project: project)
                            .padding(.horizontal, 28)
                    }
                    LeadComposer(project: project, request: selected)
                        .frame(maxWidth: Tokens.Size.transcript)
                        .padding(.horizontal, 28)
                }
                .padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selected.map { "Chat: \($0.title)" } ?? "New chat")
    }
}
