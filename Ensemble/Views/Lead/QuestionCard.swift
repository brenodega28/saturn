import EnsembleCore
import EnsembleUI
import SwiftUI

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let project: Project
    let reload: () -> Void
    @State private var reply = ""

    var body: some View {
        let agent = item.agentId.flatMap { model.agent(id: $0) }
        DecisionCard(title: agent.map { "\($0.name) asks: \(item.title)" } ?? item.title, detail: item.body) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply\(agent.map { " to \($0.name)" } ?? "")", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                    .onSubmit(send)
                    .accessibilityLabel("Answer")
                Button("Send", action: send)
                    .buttonStyle(PillButtonStyle(.primary, height: 30))
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Answer the question\(agent.map { " and send it to \($0.name)" } ?? "")")
                if let agent {
                    Button("Open \(agent.name)") { model.select(model.agents.session(for: agent), in: project) }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .help("Open the agent’s session")
                }
            }
        }
    }

    private func send() {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.answerQuestion(item: item, text: reply)
        reply = ""
        reload()
    }
}
