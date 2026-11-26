import Foundation
import SaturnCore
import Testing
@testable import Saturn

@MainActor
struct AgentTypeGroupTests {
    private struct Member: AgentTypeMember {
        let agent: Agent
        var isRunning = false
        var isQueued = false
    }

    private static let roles = [AgentKind.lead.builtInRole, AgentKind.builder.builtInRole]

    private func member(_ kind: AgentKind, status: AgentStatus = .idle, isRunning: Bool = false, archived: Bool = false) -> Member {
        let agent = Agent(
            projectId: 1, role: kind.rawValue, name: kind.rawValue, status: status,
            archivedAt: archived ? .now : nil, createdAt: .now, updatedAt: .now
        )
        return Member(agent: agent, isRunning: isRunning)
    }

    private func grouped(_ members: [Member]) -> [AgentTypeGroup<Member>] {
        AgentTypeGroup.grouped(members) { id in Self.roles.first { $0.id == id } }
    }

    @Test func groupsLeadsAndBuildersWithLeadFirst() {
        let builders = (0..<4).map { member(.builder, isRunning: $0 < 2) }
        let leads = (0..<3).map { _ in member(.lead) }
        let groups = grouped(builders + leads)
        #expect(groups.map(\.roleID) == [AgentKind.lead.rawValue, AgentKind.builder.rawValue])
        #expect(groups.map(\.count) == [3, 4])
        #expect(groups.map(\.workingCount) == [0, 2])
        #expect(groups.map(\.title) == [AgentKind.lead.builtInRole.name, AgentKind.builder.builtInRole.name])
    }

    @Test func statusIsMostUrgentInstance() {
        let groups = grouped([member(.builder), member(.builder, isRunning: true), member(.builder, status: .needsInput)])
        #expect(groups.first?.status == .needsYou)
        #expect(grouped([member(.builder), member(.builder, isRunning: true)]).first?.status == .working)
        #expect(grouped([member(.builder), member(.builder, status: .stopped)]).first?.status == .idle)
    }

    @Test func excludesArchivedUnlessAsked() {
        let members = [member(.builder), member(.builder, archived: true), member(.lead, archived: true)]
        #expect(grouped(members).map(\.count) == [1])
        let all = AgentTypeGroup.grouped(members, includesArchived: true) { id in Self.roles.first { $0.id == id } }
        #expect(all.map(\.count) == [1, 2])
    }

    @Test func statusMapping() {
        #expect(AgentTypeStatus(status: .failed, isRunning: false, isQueued: false) == .needsYou)
        #expect(AgentTypeStatus(status: .idle, isRunning: false, isQueued: true) == .queued)
        #expect(AgentTypeStatus(status: .reviewing, isRunning: false, isQueued: false) == .working)
        #expect(AgentTypeStatus(status: .stopped, isRunning: false, isQueued: false) == .stopped)
    }
}
