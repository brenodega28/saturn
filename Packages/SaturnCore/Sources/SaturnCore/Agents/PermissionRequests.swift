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
    case chat
}

public enum PermissionDecision: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
}

public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "permissionRequest"

    public var id: Int64?
    public var projectId: Int64
    public var agentId: Int64
    public var runId: Int64?
    public var taskId: Int64?
    public var capability: PermissionCapability
    public var request: String
    public var rules: [String] = []
    public var status: PermissionRequestStatus
    public var scope: PermissionScope = .chat
    public var requestId: Int64?
    public var createdAt: Date
    public var answeredAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    public func permissionRequest(requestId: Int64) throws -> PermissionRequest? {
        try writer.read { db in try PermissionRequest.filter(Column("requestId") == requestId).fetchOne(db) }
    }

    public func permissionRequest(id: Int64) throws -> PermissionRequest? {
        try writer.read { db in try PermissionRequest.fetchOne(db, key: id) }
    }

    func permissionRequests(taskId: Int64?, agentId: Int64) throws -> [PermissionRequest] {
        try writer.read { db in
            let scoped = taskId.map { PermissionRequest.filter(Column("taskId") == $0) }
                ?? PermissionRequest.filter(Column("taskId") == nil && Column("agentId") == agentId)
            return try scoped
                .filter(Column("scope") == PermissionScope.chat.rawValue)
                .order(Column("id"))
                .fetchAll(db)
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

    nonisolated static let waitingReason = "Still waiting for the user to answer. Carry on with other work or end your turn; Saturn messages you with the answer."
    nonisolated static let askedReason = "This needs the user’s OK, so Saturn asked them in the chat. Carry on with other work or end your turn; you’ll get a message with the answer."
    nonisolated static let leadChatReason = "This needs the user’s OK, so Saturn is asking them through the lead chat. Carry on with other work or end your turn; you’ll get a message with the answer."
    nonisolated static let alreadyAllowedReason = "The user already allowed this kind of command."

    nonisolated static let severity: [PermissionCapability] = [.gitPush, .riskyCommands, .installPackages, .network, .editFiles, .runShell]

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

    func permissionDecision(_ input: JSONValue, agent: Agent, policy: PermissionPolicy, directory: String? = nil) throws -> JSONValue {
        guard let tool = input["tool_name"]?.string, let id = agent.id,
              let assessment = policy.assess(tool: tool, input: input["tool_input"], directory: directory) else { return .object([:]) }
        let shell = tool == "Bash"
        if let blocked = assessment.needs.first(where: { policy.level($0.capability) == .never }) {
            guard blocked.capability == .editFiles || (shell && blocked.capability != .runShell) else { return .object([:]) }
            return Self.decision("deny", reason: "\(policy.profile.name) agents may never \(blocked.capability.describe(blocked.command)). Find another way, or explain in your summary why it’s needed.")
        }
        let asks = assessment.needs.filter { policy.level($0.capability) == .ask }
        guard !asks.isEmpty else { return shell ? Self.decision("allow") : .object([:]) }

        let taskId = try owningTaskId(of: agent)
        let history = try database.permissionRequests(taskId: taskId, agentId: id)
        let denied = Set(history.filter { $0.status == .denied }.flatMap(\.rules))
        if let refused = asks.first(where: { denied.contains($0.rule) }) {
            return Self.decision("deny", reason: "The user said no to this kind of command (`\(refused.rule)`). Don’t ask again; find another way or explain why it’s needed in your summary.")
        }
        let allowed = Set(history.filter { $0.status == .allowed }.flatMap(\.rules))
        let missing = asks.filter { !allowed.contains($0.rule) }
        guard !missing.isEmpty else { return Self.decision("allow", reason: Self.alreadyAllowedReason) }

        let rules = missing.map(\.rule).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let capability = Self.severity.first { severe in missing.contains { $0.capability == severe } } ?? missing[0].capability
        let pending = history.filter { $0.status == .pending }
        let request = PermissionRequest(
            projectId: agent.projectId, agentId: id, runId: agent.runId, taskId: taskId, capability: capability,
            request: assessment.request, rules: rules, status: .pending, createdAt: .now
        )
        if Set(rules).isSubset(of: pending.flatMap(\.rules)) {
            if !pending.contains(where: { $0.agentId == id && Set(rules).isSubset(of: $0.rules) }) {
                _ = try database.insert(request)
            }
            return Self.decision("deny", reason: Self.waitingReason)
        }
        return try ask(request, agent: agent, policy: policy)
    }

    private func ask(_ pending: PermissionRequest, agent: Agent, policy: PermissionPolicy) throws -> JSONValue {
        let name = database.displayName(of: agent)
        let action = pending.capability.describe(pending.request)
        if let taskId = pending.taskId {
            let record = try database.insert(pending)
            try database.insert(LeadMessage(
                projectId: agent.projectId, taskId: taskId, kind: .permission, text: pending.request, title: name, runId: agent.runId,
                createdAt: .now, permissionRequestId: record.id, permissionStatus: .pending, capability: pending.capability
            ))
            if let lead = try database.leadAgent(taskId: taskId), lead.id != agent.id {
                session(for: lead)?.send("\(name) asked to \(action). The user sees an Allow/Deny card in this chat; don’t answer it yourself.")
            }
            return Self.decision("deny", reason: Self.leadChatReason)
        }
        let item = try database.createChatRequest(ChatRequest(
            projectId: agent.projectId, runId: agent.runId, agentId: pending.agentId, kind: .permission,
            title: "\(name) asks to \(action)",
            body: "\(policy.profile.name) agents need your OK for \(pending.capability.title.lowercased()). Allowing it also covers \(Self.similar(pending.rules)) from this agent later.",
            createdAt: .now
        ))
        var record = pending
        record.requestId = item.id
        _ = try database.insert(record)
        return Self.decision("deny", reason: Self.askedReason)
    }

    public func answerPermission(requestId: Int64, allow: Bool, now: Date = .now) throws {
        guard let request = try database.permissionRequest(requestId: requestId), let id = request.id else { return }
        try answerPermission(requestId: id, decision: allow ? .allow : .deny, now: now)
    }

    public func answerPermission(requestId: Int64, decision: PermissionDecision, now: Date = .now) throws {
        guard let request = try database.permissionRequest(id: requestId), request.status == .pending else { return }
        try resolve(request, decision: decision, now: now)
        let history = try database.permissionRequests(taskId: request.taskId, agentId: request.agentId)
        let allowed = Set(history.filter { $0.status == .allowed }.flatMap(\.rules))
        let denied = Set(history.filter { $0.status == .denied }.flatMap(\.rules))
        for waiting in history where waiting.status == .pending && !waiting.rules.isEmpty {
            if waiting.rules.contains(where: denied.contains) {
                try resolve(waiting, decision: .deny, now: now)
            } else if waiting.rules.allSatisfy(allowed.contains) {
                try resolve(waiting, decision: .allow, now: now)
            }
        }
    }

    private func resolve(_ pending: PermissionRequest, decision: PermissionDecision, now: Date) throws {
        var request = pending
        request.status = decision == .deny ? .denied : .allowed
        request.scope = .chat
        request.answeredAt = now
        try database.save(request)
        if let requestId = request.requestId {
            try database.resolveChatRequest(id: requestId, response: decision == .deny ? "denied" : "allowed", now: now)
        }
        let card = try request.id.flatMap { try database.permissionCard(requestId: $0) }
        if var card {
            card.permissionStatus = PermissionCardStatus(decision)
            try database.save(card)
        }
        guard let agent = try database.agent(id: request.agentId) else { return }
        let action = request.capability.describe(request.request)
        let similar = Self.similar(request.rules)
        let place = request.taskId == nil ? "" : " in this chat"
        switch decision {
        case .allow:
            session(for: agent)?.send("The user allowed you to \(action). Go ahead; \(similar) won’t need asking again\(place).")
        case .deny:
            session(for: agent)?.send("The user said no to: \(action). Don’t retry it or \(similar)\(place); find another way, or explain in your summary why it’s needed.")
        }
        guard let card, let lead = try database.leadAgent(taskId: card.taskId), lead.id != agent.id else { return }
        session(for: lead)?.send("The user answered \(database.displayName(of: agent))’s request to \(action): \(Self.describe(decision, rules: request.rules)). Nothing for you to do.")
    }

    nonisolated static func similar(_ rules: [String]) -> String {
        rules.isEmpty ? "anything similar" : "anything similar (\(ruleList(rules)))"
    }

    nonisolated static func ruleList(_ rules: [String]) -> String {
        rules.map { "`\($0)`" }.joined(separator: ", ")
    }

    nonisolated static func describe(_ decision: PermissionDecision, rules: [String]) -> String {
        switch decision {
        case .allow: rules.isEmpty ? "allowed" : "allowed \(ruleList(rules)) for everyone in this chat"
        case .deny: "denied"
        }
    }
}
