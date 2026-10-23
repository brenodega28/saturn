import Foundation
import GRDB
import Observation

public struct InboxGroup: Sendable, Hashable, Identifiable {
    public var project: Project
    public var items: [InboxItem]

    public var id: Int64 { project.id ?? -1 }
}

extension AppDatabase {
    static func fetchOpenInboxItemsInOpenProjects(_ db: Database) throws -> [InboxItem] {
        try InboxItem.fetchAll(db, sql: """
            SELECT inboxItem.* FROM inboxItem
            JOIN project ON project.id = inboxItem.projectId
            WHERE project.isOpen = 1 AND inboxItem.status = ?
            ORDER BY inboxItem.createdAt DESC, inboxItem.id DESC
            """, arguments: [InboxStatus.open.rawValue])
    }

    public func openInboxItemsInOpenProjects() throws -> [InboxItem] {
        try writer.read(Self.fetchOpenInboxItemsInOpenProjects)
    }

    public func openInboxCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM inboxItem
                JOIN project ON project.id = inboxItem.projectId
                WHERE project.isOpen = 1 AND inboxItem.status = ?
                """, arguments: [InboxStatus.open.rawValue]) ?? 0
        }
    }
}

@MainActor
@Observable
public final class InboxFeed {
    public private(set) var items: [InboxItem] = []
    public private(set) var lastError: String?

    @ObservationIgnored public var onNewItems: (@MainActor ([InboxItem]) -> Void)?
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
        let observation = ValueObservation.tracking(AppDatabase.fetchOpenInboxItemsInOpenProjects)
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

    public func receive(_ newItems: [InboxItem]) {
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

    public func items(inProject projectID: Int64) -> [InboxItem] {
        items.filter { $0.projectId == projectID }
    }

    public func groups(projects: [Project]) -> [InboxGroup] {
        Self.group(items, projects: projects)
    }

    public static func group(_ items: [InboxItem], projects: [Project]) -> [InboxGroup] {
        let newestFirst = items.sorted { ($0.createdAt, $0.id ?? 0) > ($1.createdAt, $1.id ?? 0) }
        var groups: [InboxGroup] = []
        for item in newestFirst {
            if let index = groups.firstIndex(where: { $0.project.id == item.projectId }) {
                groups[index].items.append(item)
            } else if let project = projects.first(where: { $0.id == item.projectId }) {
                groups.append(InboxGroup(project: project, items: [item]))
            }
        }
        return groups
    }
}
