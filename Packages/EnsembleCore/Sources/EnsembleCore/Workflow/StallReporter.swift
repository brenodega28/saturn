import Foundation

public struct StalledWorker: Sendable, Hashable {
    public var agent: Agent
    public var lastOutputAt: Date
    public var stallMinutes: Int

    public init(agent: Agent, lastOutputAt: Date, stallMinutes: Int) {
        self.agent = agent
        self.lastOutputAt = lastOutputAt
        self.stallMinutes = stallMinutes
    }
}

@MainActor
public final class StallReporter {
    private let database: AppDatabase
    private var reported: [Int64: Date] = [:]

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func report(_ workers: [StalledWorker], now: Date = .now) throws -> [ChatRequest] {
        var posted: [ChatRequest] = []
        for worker in workers {
            guard let agentID = worker.agent.id, reported[agentID] != worker.lastOutputAt else { continue }
            let silent = Int(now.timeIntervalSince(worker.lastOutputAt) / 60)
            guard silent >= worker.stallMinutes else { continue }
            reported[agentID] = worker.lastOutputAt
            let name = AgentNaming.displayName(of: worker.agent)
            posted.append(try database.createChatRequest(ChatRequest(
                projectId: worker.agent.projectId, runId: worker.agent.runId, agentId: agentID, kind: .failure,
                title: "\(name) is stuck",
                body: "No output for \(silent) min. It may be waiting on a prompt or a hung command.",
                createdAt: now
            )))
        }
        return posted
    }
}
