import SaturnCore
import Foundation

struct LeadSendTarget: Hashable {
    let project: Int64
    let request: Int64?
    var draft: UUID? = nil
}

struct DeliveringSend: Identifiable, Hashable {
    let id: UUID
    let target: LeadSendTarget
    let message: PendingMessage
    let date: Date
}

extension DaemonWorkspace {
    func chatLeadRole(in project: Project) -> RoleDefinition? {
        leadRole(in: project)
    }

    func sendsDelivering(to target: LeadSendTarget?) -> [DeliveringSend] {
        guard let target else { return [] }
        return deliveringSends.filter { $0.target == target }
    }
}
