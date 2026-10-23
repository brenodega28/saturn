import Foundation
import GRDB
import Yams

public enum TaskColumn: String, Sendable, CaseIterable, Identifiable {
    case incoming
    case running
    case waitingOnYou
    case done
    case failed

    public var id: Self { self }

    public var title: String {
        switch self {
        case .incoming: "Incoming"
        case .running: "Running"
        case .waitingOnYou: "Waiting on you"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    public init?(_ status: TaskStatus) {
        switch status {
        case .incoming: self = .incoming
        case .running: self = .running
        case .waitingOnYou: self = .waitingOnYou
        case .done: self = .done
        case .failed: self = .failed
        case .dismissed: return nil
        }
    }
}

public struct TaskCard: Sendable, Hashable, Identifiable {
    public var task: ProjectTask
    public var run: Run?

    public var id: Int64 { task.id ?? -1 }
}

public struct TaskBoard: Sendable, Hashable {
    public var cards: [TaskCard]

    public init(cards: [TaskCard] = []) {
        self.cards = cards
    }

    public func cards(in column: TaskColumn) -> [TaskCard] {
        cards.filter { TaskColumn($0.task.status) == column }
    }

    static func fetch(_ db: Database, projectId: Int64) throws -> TaskBoard {
        let tasks = try ProjectTask
            .filter(ProjectTask.Columns.projectId == projectId)
            .filter(ProjectTask.Columns.status != TaskStatus.dismissed.rawValue)
            .order(Column("updatedAt").desc, Column("id").desc)
            .fetchAll(db)
        let runs = try Run
            .filter(Run.Columns.projectId == projectId)
            .order(Column("id"))
            .fetchAll(db)
        let latestRun = Dictionary(runs.map { ($0.taskId, $0) }, uniquingKeysWith: { _, newer in newer })
        return TaskBoard(cards: tasks.map { TaskCard(task: $0, run: $0.id.flatMap { latestRun[$0] }) })
    }
}

extension AppDatabase {
    public func taskBoard(projectId: Int64) throws -> TaskBoard {
        try writer.read { db in try TaskBoard.fetch(db, projectId: projectId) }
    }

    public func observeTaskBoard(projectId: Int64) -> AsyncValueObservation<TaskBoard> {
        ValueObservation
            .tracking { db in try TaskBoard.fetch(db, projectId: projectId) }
            .removeDuplicates()
            .values(in: writer)
    }

    public func dismissTask(id: Int64, now: Date = .now) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE task SET status = ?, updatedAt = ? WHERE id = ? AND status = ?",
                arguments: [TaskStatus.dismissed.rawValue, now, id, TaskStatus.incoming.rawValue]
            )
        }
    }
}

extension Run {
    public var workflowDefinition: WorkflowDefinition? {
        guard var workflow = try? YAMLDecoder().decode(WorkflowDefinition.self, from: workflowSnapshot) else { return nil }
        workflow.id = self.workflow
        return workflow
    }
}
