#if DEBUG
import Foundation

extension AgentWorkflowDriver {
    func traceRequestAnswer(for session: AgentSession, since start: Date) {
        guard let trace = runtime.debugTrace, let runId = session.agent.runId,
              let items = try? runtime.database.chatRequests(runId: runId) else { return }
        let answered = items.last { $0.agentId == session.id && $0.kind == .question && $0.status == .answered && ($0.resolvedAt ?? .distantPast) >= start }
        guard let answered else { return }
        trace.questionAnswered(for: session.agent, answer: answered.response, via: "user")
    }

    func traceDelivery(_ batch: [RelayedQuestion], runId: Int64, to target: String) {
        runtime.debugTrace?.runEvent("questions_delivered", runId: runId, title: (try? runtime.database.run(id: runId))??.title ?? "", fields: [
            "target": JSONValue(target),
            "count": JSONValue(batch.count),
            "agents": JSONValue(batch.map(\.agentName)),
            "agentIds": .array(batch.map { JSONValue($0.agentId) }),
        ])
    }
}
#endif
