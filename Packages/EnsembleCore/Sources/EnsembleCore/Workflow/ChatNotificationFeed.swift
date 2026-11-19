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
    public var messageId: Int64?

    public init(event: ChatNotificationEvent, projectId: Int64, taskId: Int64, title: String, body: String, dedupeKey: String, messageId: Int64? = nil) {
        self.messageId = messageId
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
                title: "\(agent) needs your OK", body: Self.excerpt(message.text), dedupeKey: key, messageId: id
            )
        case .proposal:
            self.init(
                event: .runProposal, projectId: message.projectId, taskId: message.taskId,
                title: "Run proposed: \(message.title ?? "Untitled")", body: Self.excerpt(message.text), dedupeKey: key, messageId: id
            )
        case .lead:
            self.init(
                event: .leadReply, projectId: message.projectId, taskId: message.taskId,
                title: "The lead replied", body: Self.excerpt(message.text), dedupeKey: key
            )
        case .user, .note, .specFeedback:
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
    case chatRequest(id: Int64)

    static let kindKey = "target"
    static let projectKey = "projectId"
    static let taskKey = "taskId"
    static let itemKey = "requestId"

    public var userInfo: [String: Any] {
        switch self {
        case .chat(let projectId, let taskId):
            [Self.kindKey: "chat", Self.projectKey: projectId, Self.taskKey: taskId]
        case .chatRequest(let id):
            [Self.kindKey: "chatRequest", Self.itemKey: id]
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.kindKey] as? String {
        case "chat":
            guard let projectId = Self.int64(userInfo[Self.projectKey]), let taskId = Self.int64(userInfo[Self.taskKey]) else { return nil }
            self = .chat(projectId: projectId, taskId: taskId)
        case "chatRequest":
            guard let id = Self.int64(userInfo[Self.itemKey]) else { return nil }
            self = .chatRequest(id: id)
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
    static let notifiedMessageKinds: [LeadMessageKind] = [.permission, .proposal]
    static let finishedRunStatuses: [RunStatus] = [.succeeded, .failed, .cancelled]

    static func fetchLeadTurnSources(_ db: Database, taskId: Int64, since date: Date) throws -> (messages: [LeadMessage], runs: [Run]) {
        let messages = try LeadMessage
            .filter(LeadMessage.Columns.taskId == taskId)
            .filter(LeadMessage.Columns.createdAt >= date)
            .order(LeadMessage.Columns.createdAt, Column("id"))
            .fetchAll(db)
        let runs = try Run.filter(Column("taskId") == taskId).fetchAll(db)
        return (messages, runs)
    }

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
    @ObservationIgnored private var consideredReplies: Set<Int64> = []
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

    public static func isWaitingOnUser(_ status: RunStatus) -> Bool {
        status == .waitingOnYou || ChatNotification.outcome(of: status) != nil
    }

    public static func finalReply(in messages: [LeadMessage], runs: [Run]) -> LeadMessage? {
        guard runs.allSatisfy({ isWaitingOnUser($0.status) }) else { return nil }
        let conversation = messages.filter { $0.kind == .lead || $0.kind == .user }
        guard let reply = conversation.last, reply.kind == .lead,
              let replyIndex = messages.lastIndex(where: { $0.id == reply.id }) else { return nil }
        let turnStart = messages[..<replyIndex].lastIndex { $0.kind == .lead || $0.kind == .user }.map { $0 + 1 } ?? messages.startIndex
        let turnRaisedCard = messages[turnStart..<replyIndex].contains { $0.kind == .proposal || $0.kind == .permission }
        return turnRaisedCard ? nil : reply
    }

    public func leadTurnEnded(taskId: Int64, liveRun: (Run) -> Run = { $0 }) {
        let since = launchedAt
        do {
            let sources = try database.writer.read { db in try AppDatabase.fetchLeadTurnSources(db, taskId: taskId, since: since) }
            receiveLeadTurnEnd(messages: sources.messages, runs: sources.runs.map(liveRun))
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func receiveLeadTurnEnd(messages: [LeadMessage], runs: [Run]) {
        let fresh = messages.filter { $0.createdAt >= launchedAt }
        guard let latestID = fresh.last(where: { $0.kind == .lead })?.id, !consideredReplies.contains(latestID) else { return }
        consideredReplies.insert(latestID)
        guard let reply = Self.finalReply(in: fresh, runs: runs), let notification = ChatNotification(message: reply) else { return }
        onNew?([notification])
    }

    public func receive(messages: [LeadMessage], runs: [Run]) {
        var fresh: [ChatNotification] = []
        for message in messages where message.createdAt >= launchedAt && message.kind != .lead {
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
