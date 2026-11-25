import Foundation
import GRDB
import Observation

extension AppDatabase {
    static func fetchOpenChatRequestsInOpenProjects(_ db: Database) throws -> [ChatRequest] {
        try ChatRequest.fetchAll(db, sql: """
            SELECT chatRequest.* FROM chatRequest
            JOIN project ON project.id = chatRequest.projectId
            WHERE project.isOpen = 1 AND chatRequest.status = ?
            ORDER BY chatRequest.createdAt DESC, chatRequest.id DESC
            """, arguments: [ChatRequestState.open.rawValue])
    }

    public func openChatRequestsInOpenProjects() throws -> [ChatRequest] {
        try writer.read(Self.fetchOpenChatRequestsInOpenProjects)
    }

    public func openChatRequestCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM chatRequest
                JOIN project ON project.id = chatRequest.projectId
                WHERE project.isOpen = 1 AND chatRequest.status = ?
                """, arguments: [ChatRequestState.open.rawValue]) ?? 0
        }
    }
}

@MainActor
@Observable
public final class ChatRequestFeed {
    public private(set) var items: [ChatRequest] = []
    public private(set) var lastError: String?

    @ObservationIgnored public var onNewItems: (@MainActor ([ChatRequest]) -> Void)?
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let launchedAt: Date
    @ObservationIgnored private var seen: Set<Int64> = []
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    public init(database: AppDatabase, launchedAt: Date = .now) {
        self.database = database
        self.launchedAt = launchedAt
    }

    public var count: Int { items.count }

    public func start() {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking(AppDatabase.fetchOpenChatRequestsInOpenProjects)
        cancellable = observation.start(
            in: database.writer,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error.localizedDescription },
            onChange: { [weak self] items in self?.receive(items) }
        )
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    public func receive(_ newItems: [ChatRequest]) {
        let fresh = newItems.filter { item in
            guard let id = item.id else { return false }
            return !seen.contains(id) && item.createdAt >= launchedAt
        }
        seen.formUnion(newItems.compactMap(\.id))
        items = newItems
        if !fresh.isEmpty {
            onNewItems?(fresh)
        }
    }

    public func items(inProject projectID: Int64) -> [ChatRequest] {
        items.filter { $0.projectId == projectID }
    }
}
