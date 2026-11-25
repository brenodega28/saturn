import Foundation
import GRDB
import Synchronization

public final class ChangeLog: Sendable {
    public static let tableName = "changeLog"
    public static let unreplicatedTables: Set<String> = [tableName, "grdb_migrations", "sqlite_sequence"]
    public static let defaultRetention = 10_000

    public let retention: Int
    private let writer: any DatabaseWriter
    private let queue = DispatchQueue(label: "saturn.change-log")
    private let listeners = Mutex<[UUID: @Sendable (Int64) -> Void]>([:])
    private let recorder: ChangeRecorder

    public init(database: AppDatabase, retention: Int = ChangeLog.defaultRetention) {
        self.writer = database.writer
        self.retention = max(1, retention)
        let queue = queue
        let pendingWrites = PendingWrites()
        self.recorder = ChangeRecorder()
        recorder.onCommit = { [weak self] events in
            pendingWrites.add(events)
            guard let log = self else { return }
            queue.async { log.flush(pendingWrites.take()) }
        }
        writer.add(transactionObserver: recorder, extent: .observerLifetime)
    }

    public func addListener(_ listener: @escaping @Sendable (Int64) -> Void) -> UUID {
        let id = UUID()
        listeners.withLock { $0[id] = listener }
        return id
    }

    public func removeListener(_ id: UUID) {
        _ = listeners.withLock { $0.removeValue(forKey: id) }
    }

    public func waitUntilFlushed() {
        queue.sync {}
    }

    public func latestSeq() throws -> Int64 {
        try writer.read { db in try Self.latestSeq(db) }
    }

    static func latestSeq(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = ?", arguments: [tableName]) ?? 0
    }

    public func oldestSeq() throws -> Int64? {
        try writer.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM changeLog") }
    }

    public func canResume(from seq: Int64) throws -> Bool {
        try writer.read { db in
            let latest = try Self.latestSeq(db)
            if seq == latest { return true }
            guard seq < latest, let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM changeLog") else { return false }
            return seq >= oldest - 1
        }
    }

    public func changes(after seq: Int64, limit: Int = 500) throws -> [RowChange] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM changeLog WHERE seq > ? ORDER BY seq LIMIT ?", arguments: [seq, limit]).map { row in
                let payload: String? = row["row"]
                return RowChange(
                    seq: row["seq"],
                    table: row["tableName"],
                    op: ChangeOperation(rawValue: row["op"]) ?? .upsert,
                    rowID: row["rowID"],
                    row: try payload.map { try JSONDecoder().decode([String: DBValue].self, from: Data($0.utf8)) }
                )
            }
        }
    }

    private func flush(_ events: [ChangeEvent]) {
        guard !events.isEmpty else { return }
        var unique: [ChangeEvent] = []
        var seen: Set<ChangeEvent> = []
        for event in events.reversed() where seen.insert(event).inserted {
            unique.append(event)
        }
        unique.reverse()
        let latest: Int64? = try? writer.write { db in
            let encoder = JSONEncoder()
            for event in unique {
                let row = try Row.fetchOne(db, sql: "SELECT * FROM \(event.table.quotedDatabaseIdentifier) WHERE rowid = ?", arguments: [event.rowID])
                let payload = try row.map { row -> String in
                    var values: [String: DBValue] = [:]
                    for (column, value) in row { values[column] = DBValue(value) }
                    return String(decoding: try encoder.encode(values), as: UTF8.self)
                }
                try db.execute(
                    sql: "INSERT INTO changeLog (tableName, op, rowID, row) VALUES (?, ?, ?, ?)",
                    arguments: [event.table, (payload == nil ? ChangeOperation.delete : .upsert).rawValue, event.rowID, payload]
                )
            }
            let latest = try Self.latestSeq(db)
            try db.execute(sql: "DELETE FROM changeLog WHERE seq <= ?", arguments: [latest - Int64(retention)])
            return latest
        }
        guard let latest else { return }
        let current = listeners.withLock { Array($0.values) }
        current.forEach { $0(latest) }
    }
}

struct ChangeEvent: Hashable, Sendable {
    let table: String
    let rowID: Int64
}

private final class PendingWrites: Sendable {
    private let events = Mutex<[ChangeEvent]>([])

    func add(_ new: [ChangeEvent]) {
        events.withLock { $0.append(contentsOf: new) }
    }

    func take() -> [ChangeEvent] {
        events.withLock { events in
            defer { events = [] }
            return events
        }
    }
}

final class ChangeRecorder: TransactionObserver, @unchecked Sendable {
    var onCommit: ([ChangeEvent]) -> Void = { _ in }
    private var pending: [ChangeEvent] = []

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        !ChangeLog.unreplicatedTables.contains(eventKind.tableName)
    }

    func databaseDidChange(with event: DatabaseEvent) {
        pending.append(ChangeEvent(table: event.tableName, rowID: event.rowID))
    }

    func databaseDidCommit(_ db: Database) {
        let events = pending
        pending = []
        if !events.isEmpty { onCommit(events) }
    }

    func databaseDidRollback(_ db: Database) {
        pending = []
    }
}
