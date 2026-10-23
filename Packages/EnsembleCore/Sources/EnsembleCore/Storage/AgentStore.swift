import Foundation
import GRDB

extension AppDatabase {
    public func agents(inProject projectId: Int64) throws -> [Agent] {
        try writer.read { db in
            try Agent
                .filter(Agent.Columns.projectId == projectId)
                .order(Agent.Columns.createdAt)
                .fetchAll(db)
        }
    }

    public func agent(id: Int64) throws -> Agent? {
        try writer.read { db in try Agent.fetchOne(db, id: id) }
    }

    @discardableResult
    public func insert(_ agent: Agent) throws -> Agent {
        try writer.write { db in
            var agent = agent
            try agent.insert(db)
            return agent
        }
    }

    public func save(_ agent: Agent) throws {
        try writer.write { db in try agent.update(db) }
    }

    public func deleteAgent(id: Int64) throws {
        _ = try writer.write { db in try Agent.deleteOne(db, id: id) }
    }

    public func record(_ usage: UsageEntry) throws {
        try writer.write { db in
            var usage = usage
            try usage.insert(db)
        }
    }

    public func agentsWithLiveProcesses() throws -> [Agent] {
        try writer.read { db in
            try Agent.filter(Agent.Columns.status == AgentStatus.working.rawValue).fetchAll(db)
        }
    }
}
