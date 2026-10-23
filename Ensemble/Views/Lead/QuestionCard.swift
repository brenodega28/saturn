import EnsembleCore
import EnsembleUI
import SwiftUI

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let project: Project
    let reload: () -> Void

    var body: some View {
        let agent = item.agentId.flatMap { model.agent(id: $0) }
        DecisionCard(title: item.title, detail: nil) {
            QuestionFormView(form: QuestionForm(item: item), recipient: agent?.name, send: send) {
                if let agent {
                    Button("Open \(agent.name)") { model.select(model.agents.session(for: agent), in: project) }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .help("Open the agent’s session")
                }
            }
            .id(item.id)
        }
    }

    private func send(_ reply: String) {
        model.answerQuestion(item: item, text: reply)
        reload()
    }
}
