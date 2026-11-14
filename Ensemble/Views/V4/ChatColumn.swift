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
        } else {
            leadChat
        }
    }

    private var leadChat: some View {
        let selected = model.selectedRequest(in: project)
        let newRequestHeld = selected == nil ? model.heldSends(for: model.leadSendTarget(for: nil, in: project)) : []
        let reserved = selected == nil ? 0 : ChatCard.reservedWidth
        return Group {
            if let selected {
                RequestChat(task: selected, project: project)
                    .id(selected.id)
            } else if !newRequestHeld.isEmpty {
                NewRequestHeldSends(held: newRequestHeld)
            } else {
                NewRequestIntro(project: project)
            }
        }
        .padding(.trailing, reserved)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LeadComposer(project: project, request: selected)
                .frame(maxWidth: 760)
                .padding(.horizontal, 28)
                .padding(.trailing, reserved)
                .padding(.bottom, 16)
        }
        .overlay(alignment: .topTrailing) {
            if selected != nil {
                ChatCard(project: project)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selected.map { "Chat: \($0.title)" } ?? "New chat")
    }
}
