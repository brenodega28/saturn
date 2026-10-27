import Foundation
import GRDB

public enum PermissionRequestStatus: String, Codable, Sendable {
    case pending
    case allowed
    case denied
}

public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "permissionRequest"

    public var id: Int64?
    public var projectId: Int64
    public var agentId: Int64
    public var capability: PermissionCapability
    public var request: String
    public var status: PermissionRequestStatus
    public var inboxItemId: Int64?
    public var createdAt: Date
    public var answeredAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    public func permissionRequest(inboxItemId: Int64) throws -> PermissionRequest? {
        try writer.read { db in try PermissionRequest.filter(Column("inboxItemId") == inboxItemId).fetchOne(db) }
    }

    func latestPermissionRequest(agentId: Int64, capability: PermissionCapability, request: String) throws -> PermissionRequest? {
        try writer.read { db in
            try PermissionRequest
                .filter(Column("agentId") == agentId)
                .filter(Column("capability") == capability.rawValue)
                .filter(Column("request") == request)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }
}

extension AgentRuntime {
    nonisolated static func decision(_ value: String, reason: String? = nil) -> JSONValue {
        var output: [String: JSONValue] = ["hookEventName": .string("PreToolUse"), "permissionDecision": .string(value)]
        if let reason { output["permissionDecisionReason"] = .string(reason) }
        return .object(["hookSpecificOutput": .object(output)])
    }

    func permissionDecision(_ input: JSONValue, agent: Agent, policy: PermissionPolicy) throws -> JSONValue {
        guard let tool = input["tool_name"]?.string, let id = agent.id,
              let (capability, request) = policy.capability(ofTool: tool, input: input["tool_input"]) else { return .object([:]) }
        switch policy.level(capability) {
        case .allow:
            return .object([:])
        case .never:
            guard tool == "Bash", capability != .runShell else { return .object([:]) }
            return Self.decision("deny", reason: "\(policy.profile.name) agents may never \(capability.describe(request)). Find another way, or explain in your summary why it’s needed.")
        case .ask:
            let latest = try database.latestPermissionRequest(agentId: id, capability: capability, request: request)
            switch latest?.status {
            case .allowed?:
                return Self.decision("allow", reason: "The user allowed this.")
            case .denied?:
                return Self.decision("deny", reason: "The user said no to this. Don’t ask again; find another way or explain why it’s needed in your summary.")
            case .pending?:
                return Self.decision("deny", reason: "Still waiting for the user to answer. Carry on with other work or end your turn; Ensemble messages you with the answer.")
            case nil:
                let item = try database.createInboxItem(InboxItem(
                    projectId: agent.projectId, runId: agent.runId, agentId: id, kind: .permission,
                    title: "\(agent.name) asks to \(capability.describe(request))",
                    body: "\(policy.profile.name) agents need your OK to \(capability.title.lowercased()). Allow it once for this request, or say no.",
                    createdAt: .now
                ))
                var record = PermissionRequest(
                    projectId: agent.projectId, agentId: id, capability: capability, request: request, status: .pending,
                    inboxItemId: item.id, createdAt: .now
                )
                try database.writer.write { db in try record.insert(db) }
                return Self.decision("deny", reason: "This needs the user’s OK, so Ensemble asked them in their Inbox. Carry on with other work or end your turn; you’ll get a message with the answer.")
            }
        }
    }

    public func answerPermission(inboxItemId: Int64, allow: Bool, now: Date = .now) throws {
        guard var request = try database.permissionRequest(inboxItemId: inboxItemId), request.status == .pending else { return }
        request.status = allow ? .allowed : .denied
        request.answeredAt = now
        let updated = request
        try database.writer.write { db in try updated.update(db) }
        try database.resolveInboxItem(id: inboxItemId, response: allow ? "allowed" : "denied", now: now)
        guard let agent = try database.agent(id: request.agentId), let session = session(for: agent) else { return }
        let action = request.capability.describe(request.request)
        session.send(allow
            ? "The user allowed you to \(action). Go ahead."
            : "The user said no to: \(action). Find another way, or explain in your summary why it’s needed.")
    }
}
