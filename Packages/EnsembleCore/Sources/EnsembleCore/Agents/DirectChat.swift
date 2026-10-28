import Foundation
import GRDB
import Observation

public enum DirectMessageKind: String, Codable, Sendable, Hashable {
    case user
    case agent
}

public struct DirectMessage: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "directMessage"

    public var id: Int64?
    public var projectId: Int64
    public var agentId: Int64
    public var kind: DirectMessageKind
    public var text: String
    public var awaitingReply: Bool
    public var createdAt: Date
    public var attachments: [StoredChatAttachment]?

    public init(
        id: Int64? = nil, projectId: Int64, agentId: Int64, kind: DirectMessageKind, text: String,
        awaitingReply: Bool = false, createdAt: Date, attachments: [StoredChatAttachment]? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.agentId = agentId
        self.kind = kind
        self.text = text
        self.awaitingReply = awaitingReply
        self.createdAt = createdAt
        self.attachments = attachments
    }

    public var storedAttachments: [StoredChatAttachment] { attachments ?? [] }

    public var chatAttachments: [ChatAttachment] { storedAttachments.attachments }

    var promptKey: String {
        let pastes = storedAttachments.compactMap { stored -> ChatAttachment? in
            if case .pastedText(let id, let index, let text) = stored { return .pastedText(id: id, index: index, text: text) }
            return nil
        }
        let prompt = ChatAttachment.prompt(text: text, attachments: pastes)
        return prompt.isEmpty ? ChatAttachment.imagePlaceholder : prompt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Columns {
        public static let agentId = Column(CodingKeys.agentId)
        public static let awaitingReply = Column(CodingKeys.awaitingReply)
        public static let createdAt = Column(CodingKeys.createdAt)
    }
}

extension AppDatabase {
    @discardableResult
    public func insert(_ message: DirectMessage) throws -> DirectMessage {
        try writer.write { db in
            var message = message
            try message.insert(db)
            return message
        }
    }

    public func directMessages(agentId: Int64) throws -> [DirectMessage] {
        try writer.read { db in
            try DirectMessage
                .filter(DirectMessage.Columns.agentId == agentId)
                .order(DirectMessage.Columns.createdAt, Column("id"))
                .fetchAll(db)
        }
    }

    func recordDirectReply(_ reply: DirectMessage, answering questions: [DirectMessage]) throws {
        try writer.write { db in
            for var question in questions {
                question.awaitingReply = false
                try question.update(db)
            }
            var reply = reply
            try reply.insert(db)
        }
    }
}

@MainActor
@Observable
public final class DirectChat {
    public static let noteExcerptLength = 140

    public private(set) var revision = 0
    @ObservationIgnored public let runtime: AgentRuntime
    @ObservationIgnored private var database: AppDatabase { runtime.database }

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
        runtime.observeReplies { [weak self] agent, reply in self?.record(reply: reply, from: agent) }
    }

    public func messages(with agent: Agent) -> [DirectMessage] {
        _ = revision
        guard let id = agent.id else { return [] }
        return (try? database.directMessages(agentId: id)) ?? []
    }

    public func send(_ text: String, attachments: [ChatAttachment] = [], to session: AgentSession, now: Date = .now) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agentId = session.agent.id, !body.isEmpty || !attachments.isEmpty else { return }
        try database.insert(DirectMessage(
            projectId: session.agent.projectId, agentId: agentId, kind: .user, text: body, awaitingReply: true, createdAt: now,
            attachments: try ChatAttachmentStore(paths: runtime.paths).store(attachments)
        ))
        revision += 1
        #if DEBUG
        runtime.debugTrace?.chatMessage(body, direction: "user_to_agent", chat: "direct", agent: session.agent, at: now)
        #endif
        session.send(ChatAttachment.prompt(text: body, attachments: attachments), images: attachments.filter(\.isImage))
    }

    func record(reply: String, from agent: Agent, now: Date = .now) {
        guard let agentId = agent.id, let prompt = lastPrompt(of: agent) else { return }
        let answered = ((try? database.directMessages(agentId: agentId)) ?? [])
            .filter { $0.kind == .user && $0.awaitingReply && prompt.contains($0.promptKey) }
        guard !answered.isEmpty else { return }
        do {
            try database.recordDirectReply(
                DirectMessage(projectId: agent.projectId, agentId: agentId, kind: .agent, text: reply, createdAt: now),
                answering: answered
            )
            try noteForLead(questions: answered, reply: reply, from: agent, now: now)
        } catch {
            return
        }
        #if DEBUG
        runtime.debugTrace?.chatMessage(reply, direction: "agent_to_user", chat: "direct", agent: agent, at: now)
        #endif
        revision += 1
    }

    private func lastPrompt(of agent: Agent) -> String? {
        guard let session = runtime.session(for: agent) else { return nil }
        for entry in session.transcript.entries.reversed() {
            if case .user(let text) = entry.content { return text }
        }
        return nil
    }

    private func noteForLead(questions: [DirectMessage], reply: String, from agent: Agent, now: Date) throws {
        guard let runId = agent.runId, let run = try database.run(id: runId) else { return }
        let asked = questions.map { $0.text.isEmpty ? $0.storedAttachments.map(\.label).joined(separator: ", ") : $0.text }.joined(separator: " ")
        let name = database.displayName(of: agent)
        let text = "You asked \(name) directly: “\(Self.excerpt(asked))” \(name) replied: “\(Self.excerpt(reply))”"
        try database.insert(LeadMessage(projectId: run.projectId, taskId: run.taskId, kind: .note, text: text, runId: runId, createdAt: now))
    }

    static func excerpt(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flattened.count > noteExcerptLength else { return flattened }
        return flattened.prefix(noteExcerptLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
