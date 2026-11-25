import Foundation

struct RelayedQuestion: Sendable, Hashable {
    var projectId: Int64
    var runId: Int64
    var agentId: Int64
    var agentName: String
    var body: String
    var questions: [HumanQuestion]
}

@MainActor
final class QuestionRelay {
    var window: Duration
    private let deliver: @MainActor (Int64, [RelayedQuestion]) -> Void
    private var batches: [Int64: [RelayedQuestion]] = [:]
    private var timers: [Int64: Task<Void, Never>] = [:]

    init(window: Duration = .seconds(60), deliver: @escaping @MainActor (Int64, [RelayedQuestion]) -> Void) {
        self.window = window
        self.deliver = deliver
    }

    var bufferedRunIDs: Set<Int64> { Set(batches.keys) }

    var hasPendingTimers: Bool { !timers.isEmpty }

    func enqueue(_ question: RelayedQuestion) {
        let runId = question.runId
        batches[runId, default: []].append(question)
        guard timers[runId] == nil else { return }
        let window = window
        timers[runId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.flush(runId: runId)
        }
    }

    func flush(runId: Int64) {
        timers.removeValue(forKey: runId)?.cancel()
        guard let batch = batches.removeValue(forKey: runId), !batch.isEmpty else { return }
        deliver(runId, batch)
    }

    func flushAll() {
        for runId in Set(batches.keys).union(timers.keys) {
            flush(runId: runId)
        }
    }

    static func message(for batch: [RelayedQuestion]) -> String {
        var parts = ["Questions from your run’s agents (sent by Saturn, not the user):"]
        for question in batch {
            parts.append(section(agentName: question.agentName, body: question.body, questions: question.questions))
        }
        let messageAgent = HandoffTool.messageAgent.qualifiedName
        parts.append("""
            ## What to do
            - Answer what you can yourself from the code, this conversation and the brief.
            - Fix environment problems yourself where your tools allow, for example with `\(HandoffTool.openWorktree.qualifiedName)` and the commands you are allowed to run.
            - Reply to each agent with `\(messageAgent)`, even when the answer is “carry on”.
            - Put only what you truly can’t resolve into ONE `\(HandoffTool.askHuman.qualifiedName)` to the user that merges the points and names which agents each point affects.
            - After the user answers, pass the answers on to each affected agent with `\(messageAgent)`.
            """)
        return parts.joined(separator: "\n\n")
    }

    static func spawnedAgentMessage(agentName: String, body: String, questions: [HumanQuestion]) -> String {
        let messageAgent = HandoffTool.messageAgent.qualifiedName
        return [
            "A question from \(agentName), an agent you started (sent by Saturn, not the user):",
            section(agentName: agentName, body: body, questions: questions),
            """
            ## What to do
            - Answer what you can yourself, and reply to \(agentName) with `\(messageAgent)`.
            - If only the user can answer, ask them with `\(HandoffTool.askHuman.qualifiedName)`, then pass the answer on with `\(messageAgent)`.
            """,
        ].joined(separator: "\n\n")
    }

    private static func section(agentName: String, body: String, questions: [HumanQuestion]) -> String {
        var section = ["## \(agentName) asks:", body]
        if !questions.isEmpty {
            section.append(questions.enumerated().map { index, item in
                "\(index + 1). \(item.question)" + (item.options.isEmpty ? "" : "\n   Options: " + item.options.joined(separator: "; "))
            }.joined(separator: "\n"))
        }
        return section.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
