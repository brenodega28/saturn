import SaturnCore
import SaturnUI
import SwiftUI

@MainActor
protocol AgentTypeMember {
    var agent: Agent { get }
    var isRunning: Bool { get }
    var isQueued: Bool { get }
}

extension LiveAgentSession: AgentTypeMember {}

enum AgentTypeStatus: Int, Comparable {
    case needsYou
    case working
    case queued
    case idle
    case stopped

    init(status: AgentStatus, isRunning: Bool, isQueued: Bool) {
        if AgentActivity(status: status, isRunning: isRunning, isQueued: isQueued) == .needsYou {
            self = .needsYou
        } else if isRunning || [.working, .reviewing].contains(status) {
            self = .working
        } else if isQueued {
            self = .queued
        } else if status == .stopped {
            self = .stopped
        } else {
            self = .idle
        }
    }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .queued: "Queued"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: Tokens.need
        case .working: Tokens.build
        case .queued, .idle: Tokens.idle
        case .stopped: Tokens.text2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
struct AgentTypeGroup<Member: AgentTypeMember>: @MainActor Identifiable {
    let roleID: String
    let role: RoleDefinition?
    let sessions: [Member]
    let status: AgentTypeStatus
    let workingCount: Int

    var id: String { roleID }
    var title: String { role?.name ?? roleID }
    var count: Int { sessions.count }
    var kind: AgentKind { role?.kind ?? AgentKind.guessing(roleID: roleID) }

    var summary: String {
        count == 1 ? status.label : "\(count) instances · \(workingCount) working"
    }

    var sharedModel: String? {
        let models = Set(sessions.map(\.agent.model))
        return models.count == 1 ? models.first : nil
    }

    static func grouped(
        _ members: [Member],
        includesArchived: Bool = false,
        role: (String) -> RoleDefinition?,
        status: (Member) -> AgentStatus = { $0.agent.status }
    ) -> [AgentTypeGroup] {
        let shown = includesArchived ? members : members.filter { $0.agent.archivedAt == nil }
        let byRole = Dictionary(grouping: shown, by: \.agent.role)
        return byRole.map { roleID, sessions in
            let states = sessions.map { AgentTypeStatus(status: status($0), isRunning: $0.isRunning, isQueued: $0.isQueued) }
            return AgentTypeGroup(
                roleID: roleID,
                role: role(roleID),
                sessions: sessions,
                status: states.min() ?? .idle,
                workingCount: states.count { $0 == .working }
            )
        }
        .sorted { lhs, rhs in
            let lhsLead = lhs.kind == .lead, rhsLead = rhs.kind == .lead
            if lhsLead != rhsLead { return lhsLead }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

typealias AgentType = AgentTypeGroup<LiveAgentSession>
