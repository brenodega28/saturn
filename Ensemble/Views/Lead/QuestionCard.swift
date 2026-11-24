import EnsembleCore
import EnsembleUI
import SwiftUI

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let item: ChatRequest
    let project: Project
    let reload: () -> Void

    var body: some View {
        let agent = item.agentId.flatMap { workspace.agent(id: $0) }
        let name = agent.map { workspace.displayName(of: $0, in: project) }
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Text("Question").fontWeight(.semibold).foregroundStyle(Tokens.need)) · \(item.title)")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
            QuestionFormView(form: QuestionForm(item: item), recipient: name, quickAnswers: true, send: send) {
                if let agent {
                    Button("Open \(workspace.displayName(of: agent, in: project))") { workspace.openAgentSession(agent, in: project) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Open the agent’s session")
                }
            }
            .id(item.id)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.needBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.needLine))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question: \(item.title)")
    }

    private func send(_ reply: String) {
        workspace.answerQuestion(item: item, text: reply)
        reload()
    }
}
