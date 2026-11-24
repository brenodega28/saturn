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

    private var leadChat: some View {
        let selected = workspace.selectedRequest(in: project)
        let newRequestHeld = selected == nil ? workspace.heldSends(for: workspace.leadSendTarget(for: nil, in: project)) : []
        return VStack(spacing: 0) {
            ForEach(model.systemAlerts.filter { $0.affects(project) }) { alert in
                ChatAlertBanner(alert: alert)
                    .frame(maxWidth: Tokens.Size.transcript)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
            }
            Group {
                if let selected {
                    RequestChat(task: selected, project: project)
                        .id(selected.id)
                } else if !newRequestHeld.isEmpty {
                    NewRequestHeldSends(held: newRequestHeld)
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
