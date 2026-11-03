import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatColumn: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        if model.isShowingRequestPage(in: project) {
            ToolScreen(title: "Chats") {
                RequestListView(project: project)
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
            }
        } else if let session = model.directChatSession(in: project) {
            ToolScreen(title: model.displayName(of: session.agent, in: project)) {
                DirectChatView(session: session, project: project)
                    .id(session.id)
                    .padding(EdgeInsets(top: 4, leading: 22, bottom: 20, trailing: 20))
            }
        } else {
            leadChat
        }
    }

    private var leadChat: some View {
        let selected = model.selectedRequest(in: project)
        let newRequestHeld = selected == nil ? model.heldSends(for: model.leadSendTarget(for: nil, in: project)) : []
        return ZStack(alignment: .bottom) {
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
            LeadComposer(project: project, request: selected)
                .frame(maxWidth: 760)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selected.map { "Chat: \($0.title)" } ?? "New chat")
    }
}
