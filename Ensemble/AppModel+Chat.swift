import EnsembleCore
import Foundation

enum PendingSendTarget: Hashable {
    case session(Int64)
    case lead(project: Int64, request: Int64?)
}

struct HeldSend: Identifiable, Hashable {
    let id: UUID
    let target: PendingSendTarget
    let message: PendingMessage
    let date: Date
    let isCancellable: Bool
}

extension AppModel {
    func chatLeadRole(in project: Project) -> RoleDefinition? {
        leadRole(in: project)
    }

    static let sendHoldSecondsKey = "chat.sendHoldSeconds"
    static let defaultSendHoldSeconds = 3

    var sendHoldSeconds: Int {
        max(UserDefaults.standard.object(forKey: Self.sendHoldSecondsKey) as? Int ?? Self.defaultSendHoldSeconds, 0)
    }

    func holdSend(_ message: PendingMessage, to target: PendingSendTarget, deliver: @escaping @MainActor (PendingMessage) -> Void) {
        pendingSends.schedule(message, for: target, delay: TimeInterval(sendHoldSeconds), deliver: deliver)
    }

    func heldSends(for target: PendingSendTarget?) -> [HeldSend] {
        guard let target else { return [] }
        let holds = pendingSends.holds(for: target).map {
            HeldSend(id: $0.id, target: $0.target, message: $0.message, date: $0.scheduledAt, isCancellable: true)
        }
        return deliveringSends.filter { $0.target == target } + holds
    }

    func cancelHeldSend(_ held: HeldSend) {
        pendingSends.cancel(held.id)
    }

    func holdSessionMessage(_ text: String, to session: AgentSession) {
        holdSend(PendingMessage(text: text), to: .session(session.id)) { session.send($0.text) }
    }
}
