import Foundation
import GRDB
import Observation

public struct PendingPermissionCounts: Sendable, Hashable {
    public var byTask: [Int64: Int]
    public var byProject: [Int64: Int]

    public init(byTask: [Int64: Int] = [:], byProject: [Int64: Int] = [:]) {
        self.byTask = byTask
        self.byProject = byProject
    }

    public func count(taskId: Int64) -> Int { byTask[taskId] ?? 0 }

    public func count(projectId: Int64) -> Int { byProject[projectId] ?? 0 }
}

extension AppDatabase {
    static func fetchPendingPermissionCounts(_ db: Database, projectId: Int64? = nil) throws -> PendingPermissionCounts {
        var arguments: StatementArguments = [LeadMessageKind.permission.rawValue, PermissionCardStatus.pending.rawValue]
        var projectFilter = ""
        if let projectId {
            projectFilter = "AND leadMessage.projectId = ?"
            arguments += [projectId]
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT leadMessage.projectId AS projectId, leadMessage.taskId AS taskId, COUNT(*) AS count
            FROM leadMessage
            JOIN task ON task.id = leadMessage.taskId
            WHERE leadMessage.kind = ? AND leadMessage.permissionStatus = ? AND task.closedAt IS NULL \(projectFilter)
            GROUP BY leadMessage.projectId, leadMessage.taskId
            """, arguments: arguments)
        var counts = PendingPermissionCounts()
        for row in rows {
            let projectId: Int64 = row["projectId"]
            let taskId: Int64 = row["taskId"]
            let count: Int = row["count"]
            counts.byTask[taskId] = count
            counts.byProject[projectId, default: 0] += count
        }
        return counts
    }

    public func pendingPermissionCounts(projectId: Int64) throws -> [Int64: Int] {
        try writer.read { db in try Self.fetchPendingPermissionCounts(db, projectId: projectId).byTask }
    }

    public func pendingPermissionCounts() throws -> PendingPermissionCounts {
        try writer.read { db in try Self.fetchPendingPermissionCounts(db) }
    }
}

@MainActor
@Observable
public final class PendingPermissionFeed {
    public private(set) var counts = PendingPermissionCounts()
    public private(set) var lastError: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    public init(database: AppDatabase) {
        self.database = database
    }

    public func start() {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking { db in try AppDatabase.fetchPendingPermissionCounts(db) }.removeDuplicates()
        cancellable = observation.start(
            in: database.writer,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error.localizedDescription },
            onChange: { [weak self] counts in self?.counts = counts }
        )
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    public func count(taskId: Int64) -> Int { counts.count(taskId: taskId) }

    public func count(projectId: Int64) -> Int { counts.count(projectId: projectId) }
}
