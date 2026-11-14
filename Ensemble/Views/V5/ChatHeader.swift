import EnsembleCore
import EnsembleUI
import SwiftUI

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
