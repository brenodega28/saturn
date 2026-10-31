import Foundation
import GRDB
import Observation

public enum ChatNotificationEvent: String, CaseIterable, Sendable {
    case permissionCard
    case runProposal
    case leadReply
    case runFinished
}

public struct ChatNotification: Sendable, Hashable {
    public static let excerptLength = 140

    public var event: ChatNotificationEvent
    public var projectId: Int64
    public var taskId: Int64
    public var title: String
    public var body: String
    public var dedupeKey: String

    public init(event: ChatNotificationEvent, projectId: Int64, taskId: Int64, title: String, body: String, dedupeKey: String) {
        self.event = event
        self.projectId = projectId
        self.taskId = taskId
        self.title = title
        self.body = body
        self.dedupeKey = dedupeKey
    }

    public init?(message: LeadMessage) {
        guard let id = message.id else { return nil }
        let key = "lead-message-\(id)"
        switch message.kind {
        case .permission:
            let agent = message.title.flatMap { $0.isEmpty ? nil : $0 } ?? "An agent"
            self.init(
                event: .permissionCard, projectId: message.projectId, taskId: message.taskId,
                title: "\(agent) needs your OK", body: Self.excerpt(message.text), dedupeKey: key
            )
        case .proposal:
            self.init(
                event: .runProposal, projectId: message.projectId, taskId: message.taskId,
                title: "Run proposed: \(message.title ?? "Untitled")", body: Self.excerpt(message.text), dedupeKey: key
            )
        case .lead:
            self.init(
                event: .leadReply, projectId: message.projectId, taskId: message.taskId,
                title: "The lead replied", body: Self.excerpt(message.text), dedupeKey: key
            )
        case .user, .note:
            return nil
        }
    }

    public init?(run: Run) {
        guard let id = run.id, let outcome = Self.outcome(of: run.status) else { return nil }
        self.init(
            event: .runFinished, projectId: run.projectId, taskId: run.taskId,
            title: run.title.isEmpty ? run.workflow : run.title, body: "Run \(outcome)", dedupeKey: "run-\(id)"
        )
    }

    public static func outcome(of status: RunStatus) -> String? {
        switch status {
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .pending, .running, .waitingOnYou, .paused, .interrupted: nil
        }
    }

    public static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptLength else { return trimmed }
        return String(trimmed.prefix(excerptLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

public enum NotificationTarget: Equatable, Sendable {
    case chat(projectId: Int64, taskId: Int64)
    case inboxItem(id: Int64)

    static let kindKey = "target"
    static let projectKey = "projectId"
    static let taskKey = "taskId"
    static let itemKey = "inboxItemId"

    public var userInfo: [String: Any] {
        switch self {
        case .chat(let projectId, let taskId):
            [Self.kindKey: "chat", Self.projectKey: projectId, Self.taskKey: taskId]
        case .inboxItem(let id):
            [Self.kindKey: "inboxItem", Self.itemKey: id]
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.kindKey] as? String {
        case "chat":
            guard let projectId = Self.int64(userInfo[Self.projectKey]), let taskId = Self.int64(userInfo[Self.taskKey]) else { return nil }
            self = .chat(projectId: projectId, taskId: taskId)
        case "inboxItem":
            guard let id = Self.int64(userInfo[Self.itemKey]) else { return nil }
            self = .inboxItem(id: id)
        default:
            return nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64: value
        case let value as Int: Int64(value)
        case let value as NSNumber: value.int64Value
        default: nil
        }
    }
}

public enum NotificationSuppression {
    public static func shouldSuppress(
        appActive: Bool, visibleChat: (projectId: Int64, taskId: Int64)?, target: (projectId: Int64, taskId: Int64?)
    ) -> Bool {
        guard appActive, let visibleChat, let taskId = target.taskId else { return false }
        return visibleChat.projectId == target.projectId && visibleChat.taskId == taskId
    }
}

extension AppDatabase {
    static let notifiedMessageKinds: [LeadMessageKind] = [.permission, .proposal, .lead]
    static let finishedRunStatuses: [RunStatus] = [.succeeded, .failed, .cancelled]

    static func fetchChatNotificationSources(_ db: Database, since date: Date) throws -> (messages: [LeadMessage], runs: [Run]) {
        let messages = try LeadMessage
            .filter(LeadMessage.Columns.createdAt >= date)
            .filter(notifiedMessageKinds.map(\.rawValue).contains(Column("kind")))
            .order(Column("id"))
            .fetchAll(db)
        let runs = try Run
            .filter(Column("endedAt") >= date)
            .filter(finishedRunStatuses.map(\.rawValue).contains(Column("status")))
            .order(Column("id"))
            .fetchAll(db)
        return (messages, runs)
    }
}

@MainActor
@Observable
public final class ChatNotificationFeed {
    public private(set) var lastError: String?

    @ObservationIgnored public var onNew: (@MainActor ([ChatNotification]) -> Void)?
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let launchedAt: Date
    @ObservationIgnored private var seenMessages: Set<Int64> = []
    @ObservationIgnored private var seenRuns: Set<Int64> = []
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?

    public init(database: AppDatabase, launchedAt: Date = .now) {
        self.database = database
        self.launchedAt = launchedAt
    }

    public func start() {
        guard cancellable == nil else { return }
        let since = launchedAt
        let observation = ValueObservation.tracking { db in try AppDatabase.fetchChatNotificationSources(db, since: since) }
        cancellable = observation.start(
            in: database.writer,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error.localizedDescription },
            onChange: { [weak self] sources in self?.receive(messages: sources.messages, runs: sources.runs) }
        )
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    public func receive(messages: [LeadMessage], runs: [Run]) {
        var fresh: [ChatNotification] = []
        for message in messages where message.createdAt >= launchedAt {
            guard let id = message.id, !seenMessages.contains(id), let notification = ChatNotification(message: message) else { continue }
            seenMessages.insert(id)
            fresh.append(notification)
        }
        for run in runs {
            guard let id = run.id, let endedAt = run.endedAt, endedAt >= launchedAt, !seenRuns.contains(id),
                  let notification = ChatNotification(run: run) else { continue }
            seenRuns.insert(id)
            fresh.append(notification)
        }
        if !fresh.isEmpty {
            onNew?(fresh)
        }
    }
}
