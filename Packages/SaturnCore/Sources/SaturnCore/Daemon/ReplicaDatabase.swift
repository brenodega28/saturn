import Foundation
import GRDB

public struct ReplicaState: Codable, Sendable, Hashable {
    public var daemonID: DaemonID
    public var seq: Int64
}

public final class ReplicaDatabase: Sendable {
    public let url: URL
    public let stateURL: URL
    public let daemonID: DaemonID
    public let database: AppDatabase
    private let pool: DatabasePool

    public init(url: URL, stateURL: URL, daemonID: DaemonID) throws {
        self.url = url
        self.stateURL = stateURL
        self.daemonID = daemonID
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        if isNew {
            try? FileManager.default.removeItem(at: stateURL)
            _ = try AppDatabase(pool)
        }
        try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA query_only = 1") }
        self.pool = pool
        self.database = AppDatabase(replicaWriter: pool)
    }

    public var state: ReplicaState? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ReplicaState.self, from: data),
              state.daemonID == daemonID else { return nil }
        return state
    }

    public var seq: Int64? { state?.seq }

    public var schema: String? {
        try? pool.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
        }
    }

    private func save(seq: Int64) throws {
        let data = try JSONEncoder().encode(ReplicaState(daemonID: daemonID, seq: seq))
        try data.write(to: stateURL, options: .atomic)
    }

    private func writing<T>(_ work: (Database) throws -> T) throws -> T {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA query_only = 0")
            defer { try? db.execute(sql: "PRAGMA query_only = 1") }
            return try work(db)
        }
    }

    public func applySnapshot(file: URL, seq: Int64) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let source = try DatabaseQueue(path: file.path, configuration: configuration)
        try writing { db in
            try source.read { sourceDb in try sourceDb.backup(to: db) }
            db.clearSchemaCache()
            try db.inTransaction {
                try db.notifyChanges(in: .fullDatabase)
                return .commit
            }
        }
        try source.close()
        try save(seq: seq)
    }

    public func apply(_ changes: [RowChange], seq: Int64) throws {
        try writing { db in
            try db.inTransaction {
                for change in changes {
                    try Self.apply(change, db)
                }
                return .commit
            }
        }
        try save(seq: seq)
    }

    static func apply(_ change: RowChange, _ db: Database) throws {
        guard try db.tableExists(change.table) else { return }
        let table = change.table.quotedDatabaseIdentifier
        switch change.op {
        case .delete:
            try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [change.rowID])
        case .upsert:
            guard let row = change.row else { return }
            let known = Set(try db.columns(in: change.table).map(\.name))
            let columns = row.keys.filter(known.contains).sorted()
            let names = (["rowid"] + columns.map(\.quotedDatabaseIdentifier)).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
            var values: [DatabaseValue] = [change.rowID.databaseValue]
            values += columns.map { row[$0]?.databaseValue ?? .null }
            try db.execute(
                sql: "INSERT OR REPLACE INTO \(table) (\(names)) VALUES (\(placeholders))",
                arguments: StatementArguments(values)
            )
        }
    }

    public func close() throws {
        try pool.close()
    }

    public static func remove(at url: URL, stateURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        try? FileManager.default.removeItem(at: stateURL)
    }
}
