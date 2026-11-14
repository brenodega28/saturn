import Foundation
import GRDB

extension AppDatabase {
    public func run(id: Int64) throws -> Run? {
        try writer.read { db in try Run.fetchOne(db, id: id) }
    }

    public func task(id: Int64) throws -> Chat? {
        try writer.read { db in try Chat.fetchOne(db, id: id) }
    }

    @discardableResult
    public func insert(_ task: Chat) throws -> Chat {
        try writer.write { db in
            var task = task
            try task.insert(db)
            return task
        }
    }

    public func save(_ task: Chat) throws {
        try writer.write { db in try task.update(db) }
    }

    public func runs(projectId: Int64) throws -> [Run] {
        try writer.read { db in
            try Run.filter(Run.Columns.projectId == projectId).order(Run.Columns.startedAt, Column("id")).fetchAll(db)
        }
    }

    public func runs(status: [RunStatus]) throws -> [Run] {
        try writer.read { db in
            try Run.filter(status.map(\.rawValue).contains(Run.Columns.status)).order(Column("id")).fetchAll(db)
        }
    }

    public func runSteps(runId: Int64) throws -> [RunStep] {
        try writer.read { db in
            try RunStep.filter(RunStep.Columns.runId == runId).order(Column("id")).fetchAll(db)
        }
    }

    public func runStep(id: Int64) throws -> RunStep? {
        try writer.read { db in try RunStep.fetchOne(db, id: id) }
    }

    @discardableResult
    func insert(_ step: RunStep) throws -> RunStep {
        try writer.write { db in
            var step = step
            try step.insert(db)
            return step
        }
    }

    func save(_ step: RunStep) throws {
        try writer.write { db in try step.update(db) }
    }

    @discardableResult
    func insert(_ run: Run, state: RunEngineState) throws -> Run {
        let encoded = try RunEngineState.encode(state)
        return try writer.write { db in
            var run = run
            try run.insert(db)
            try db.execute(sql: "UPDATE run SET engineState = ? WHERE id = ?", arguments: [encoded, run.id])
            return run
        }
    }

    func save(_ run: Run) throws {
        try writer.write { db in try run.update(db) }
    }

    public func engineState(runId: Int64) throws -> RunEngineState {
        let text = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT engineState FROM run WHERE id = ?", arguments: [runId])
        }
        return try RunEngineState.decode(text ?? "{}")
    }

    func save(_ state: RunEngineState, runId: Int64) throws {
        let encoded = try RunEngineState.encode(state)
        try writer.write { db in
            try db.execute(sql: "UPDATE run SET engineState = ? WHERE id = ?", arguments: [encoded, runId])
        }
    }
}

extension RunEngineState {
    static func encode(_ state: RunEngineState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> RunEngineState {
        try JSONDecoder().decode(RunEngineState.self, from: Data(text.utf8))
    }
}
