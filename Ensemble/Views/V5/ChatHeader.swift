import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat?

    var body: some View {
        HStack(spacing: 8) {
            ProjectTile(project: project, size: 18)
            Text(project.name).foregroundStyle(Tokens.text2)
            Text("/").foregroundStyle(Tokens.text3)
            Text(chat?.title ?? "New chat")
                .fontWeight(.semibold)
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
            if let chat, let stage = model.summary(of: chat)?.stage {
                Text(stage.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(stage.color)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(stage.background, in: Capsule())
            }
            Spacer()
        }
        .font(.system(size: 14))
        .padding(.horizontal, 22)
        .frame(height: 56)
        .contextMenu {
            if let chat { ChatRowMenu(chat: chat, rename: {}) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ClosedChatBanner: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            Text("Closed as \(chat.closeReason?.title.lowercased() ?? "closed") on \((chat.closedAt ?? chat.updatedAt).formatted(.dateTime.month(.abbreviated).day())). Reopen it to keep talking.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Reopen") { model.reopenChat(chat) }.buttonStyle(SecondaryPillStyle())
        }
        .padding(12)
        .background(Tokens.fill, in: .rect(cornerRadius: 12, style: .continuous))
    }
}
