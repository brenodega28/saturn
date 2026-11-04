import Foundation
import GRDB

public enum PermissionRequestStatus: String, Codable, Sendable {
    case pending
    case allowed
    case denied
}

public enum PermissionScope: String, Codable, Sendable {
    case once
    case run
}

public enum PermissionDecision: String, Codable, Sendable, CaseIterable {
    case allowOnce
    case allowForRun
    case deny
}

public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "permissionRequest"

    public var id: Int64?
    public var projectId: Int64
    public var agentId: Int64
    public var runId: Int64?
    public var capability: PermissionCapability
    public var request: String
    public var status: PermissionRequestStatus
    public var scope: PermissionScope = .once
    public var inboxItemId: Int64?
    public var createdAt: Date
    public var answeredAt: Date?
    public var consumedAt: Date?

    public var commandName: String { PermissionPolicy.commandName(of: request) }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    public func permissionRequest(inboxItemId: Int64) throws -> PermissionRequest? {
        try writer.read { db in try PermissionRequest.filter(Column("inboxItemId") == inboxItemId).fetchOne(db) }
    }

    public func permissionRequest(id: Int64) throws -> PermissionRequest? {
        try writer.read { db in try PermissionRequest.fetchOne(db, key: id) }
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

    func runPermission(runId: Int64, capability: PermissionCapability, commandName: String) throws -> PermissionRequest? {
        try writer.read { db in
            try PermissionRequest
                .filter(Column("runId") == runId)
                .filter(Column("capability") == capability.rawValue)
                .filter(Column("status") == PermissionRequestStatus.allowed.rawValue)
                .filter(Column("scope") == PermissionScope.run.rawValue)
                .fetchAll(db)
                .first { $0.commandName == commandName }
        }
    }

    func save(_ request: PermissionRequest) throws {
        try writer.write { db in try request.update(db) }
    }

    func insert(_ request: PermissionRequest) throws -> PermissionRequest {
        try writer.write { db in try request.inserted(db) }
    }
}

extension AgentRuntime {
    nonisolated static func decision(_ value: String, reason: String? = nil) -> JSONValue {
        var output: [String: JSONValue] = ["hookEventName": .string("PreToolUse"), "permissionDecision": .string(value)]
        if let reason { output["permissionDecisionReason"] = .string(reason) }
        return .object(["hookSpecificOutput": .object(output)])
    }

    nonisolated static let chainedCommandReason = ClaudeLaunch.oneCommandRule + " Run the allowed command on its own instead."
    nonisolated static let waitingReason = "Still waiting for the user to answer. Carry on with other work or end your turn; Ensemble messages you with the answer."
    nonisolated static let inboxReason = "This needs the user’s OK, so Ensemble asked them in their Inbox. Carry on with other work or end your turn; you’ll get a message with the answer."
    nonisolated static let leadChatReason = "This needs the user’s OK, so Ensemble is asking them through the lead chat. Carry on with other work or end your turn; you’ll get a message with the answer."

    func owningTaskId(of agent: Agent) throws -> Int64? {
        var current = agent
        var visited: Set<Int64> = []
        while true {
            if let taskId = current.taskId { return taskId }
            if let runId = current.runId, let run = try database.run(id: runId) { return run.taskId }
            guard let id = current.id, visited.insert(id).inserted,
                  let spawnerId = current.spawnedById, let spawner = try database.agent(id: spawnerId) else { return nil }
            current = spawner
        }
    }

    func permissionDecision(_ input: JSONValue, agent: Agent, policy: PermissionPolicy) throws -> JSONValue {
        guard let tool = input["tool_name"]?.string, let id = agent.id,
              let (capability, request) = policy.capability(ofTool: tool, input: input["tool_input"]) else { return .object([:]) }
        let command = tool == "Bash" ? request : nil
        switch policy.level(capability) {
        case .never:
            guard capability == .editFiles || (tool == "Bash" && capability != .runShell) else { return .object([:]) }
            return Self.decision("deny", reason: "\(policy.profile.name) agents may never \(capability.describe(request)). Find another way, or explain in your summary why it’s needed.")
        case .allow:
            guard let command, !policy.coversEveryPart(of: command) else { return .object([:]) }
        case .ask:
            break
        }
        if let command, PermissionPolicy.isCompound(command) {
            return Self.decision("deny", reason: Self.chainedCommandReason)
        }
        let latest = try database.latestPermissionRequest(agentId: id, capability: capability, request: request)
        if latest?.status == .denied {
            return Self.decision("deny", reason: "The user said no to this. Don’t ask again; find another way or explain why it’s needed in your summary.")
        }
        if let runId = agent.runId, try database.runPermission(runId: runId, capability: capability, commandName: PermissionPolicy.commandName(of: request)) != nil {
            return Self.decision("allow", reason: "The user allowed this for the run.")
        }
        if var granted = latest, granted.status == .allowed, granted.scope == .run || granted.consumedAt == nil {
            if granted.scope == .once {
                granted.consumedAt = .now
                try database.save(granted)
            }
            return Self.decision("allow", reason: "The user allowed this.")
        }
        if latest?.status == .pending {
            return Self.decision("deny", reason: Self.waitingReason)
        }
        return try ask(capability: capability, request: request, agent: agent, agentId: id, policy: policy)
    }

    private func ask(capability: PermissionCapability, request: String, agent: Agent, agentId: Int64, policy: PermissionPolicy) throws -> JSONValue {
        let name = database.displayName(of: agent)
        let action = capability.describe(request)
        let pending = PermissionRequest(
            projectId: agent.projectId, agentId: agentId, runId: agent.runId, capability: capability, request: request,
            status: .pending, createdAt: .now
        )
        if let taskId = try owningTaskId(of: agent) {
            let record = try database.insert(pending)
            try database.insert(LeadMessage(
                projectId: agent.projectId, taskId: taskId, kind: .permission, text: request, title: name, runId: agent.runId,
                createdAt: .now, permissionRequestId: record.id, permissionStatus: .pending, capability: capability
            ))
            if let lead = try database.leadAgent(taskId: taskId), lead.id != agent.id {
                session(for: lead)?.send("\(name) asked to \(action). The user sees an Allow/Deny card in this chat; don’t answer it yourself.")
            }
            return Self.decision("deny", reason: Self.leadChatReason)
        }
        let item = try database.createInboxItem(InboxItem(
            projectId: agent.projectId, runId: agent.runId, agentId: agentId, kind: .permission,
            title: "\(name) asks to \(action)",
            body: "\(policy.profile.name) agents need your OK to \(capability.title.lowercased()). Allow it once for this request, or say no.",
            createdAt: .now
        ))
        var record = pending
        record.inboxItemId = item.id
        _ = try database.insert(record)
        return Self.decision("deny", reason: Self.inboxReason)
    }

    public func answerPermission(inboxItemId: Int64, allow: Bool, now: Date = .now) throws {
        guard let request = try database.permissionRequest(inboxItemId: inboxItemId), let id = request.id else { return }
        try answerPermission(requestId: id, decision: allow ? .allowOnce : .deny, now: now)
    }

    public func answerPermission(requestId: Int64, decision: PermissionDecision, now: Date = .now) throws {
        guard var request = try database.permissionRequest(id: requestId), request.status == .pending else { return }
        request.status = decision == .deny ? .denied : .allowed
        request.scope = decision == .allowForRun ? .run : .once
        request.answeredAt = now
        try database.save(request)
        if let inboxItemId = request.inboxItemId {
            try database.resolveInboxItem(id: inboxItemId, response: decision == .deny ? "denied" : "allowed", now: now)
        }
        let card = try database.permissionCard(requestId: requestId)
        if var card {
            card.permissionStatus = PermissionCardStatus(decision)
            try database.save(card)
        }
        guard let agent = try database.agent(id: request.agentId) else { return }
        let action = request.capability.describe(request.request)
        switch decision {
        case .allowOnce:
            session(for: agent)?.send("The user allowed you to \(action). Go ahead; this covers the next attempt only.")
        case .allowForRun:
            session(for: agent)?.send("The user allowed you to \(action), and any `\(request.commandName)` command for the rest of this run. Go ahead.")
        case .deny:
            session(for: agent)?.send("The user said no to: \(action). Find another way, or explain in your summary why it’s needed.")
        }
        guard let card, let lead = try database.leadAgent(taskId: card.taskId), lead.id != agent.id else { return }
        session(for: lead)?.send("The user answered \(database.displayName(of: agent))’s request to \(action): \(Self.describe(decision, commandName: request.commandName)). Nothing for you to do.")
    }

    nonisolated static func describe(_ decision: PermissionDecision, commandName: String) -> String {
        switch decision {
        case .allowOnce: "allowed once"
        case .allowForRun: "allowed `\(commandName)` for every agent for the rest of this run"
        case .deny: "denied"
        }
    }
}
