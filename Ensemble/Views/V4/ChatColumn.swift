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
        return GeometryReader { geometry in
            let isNarrow = geometry.size.width < Tokens.Size.narrowWindow - Tokens.Size.sidebar
            let showsCard = selected != nil && !isNarrow
            let reserved = showsCard ? Tokens.Size.chatCardReserve : 0
            VStack(spacing: 0) {
                ChatHeader(project: project, chat: selected)
                    .padding(.trailing, reserved)
                ForEach(model.systemAlerts.filter { $0.affects(project) }) { alert in
                    ChatAlertBanner(alert: alert)
                        .frame(maxWidth: Tokens.Size.transcript)
                        .padding(.horizontal, 28)
                        .padding(.trailing, reserved)
                        .padding(.bottom, 6)
                }
                    .overlay(alignment: .trailing) {
                        if let selected, isNarrow {
                            ChatCardPill(project: project, chat: selected)
                                .padding(.trailing, 16)
                        }
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
                .padding(.trailing, reserved)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        if model.isAppOutputShown, selected != nil {
                            AppOutputPanel(project: project)
                                .padding(.horizontal, 28)
                        }
                        LeadComposer(project: project, request: selected)
                            .frame(maxWidth: Tokens.Size.composer)
                            .padding(.horizontal, 28)
                    }
                    .padding(.trailing, reserved)
                    .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected, showsCard {
                    ChatCard(project: project, chat: selected)
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selected.map { "Chat: \($0.title)" } ?? "New chat")
    }
}
