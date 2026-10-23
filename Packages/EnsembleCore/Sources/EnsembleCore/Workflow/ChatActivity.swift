import Foundation

public enum ChatActivity: Int, Sendable, Hashable, Comparable, CaseIterable {
    case replying
    case planReady
    case needsYou

    public static func < (lhs: ChatActivity, rhs: ChatActivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .replying: "Replying"
        case .planReady: "Plan ready"
        case .needsYou: "Needs you"
        }
    }

    public var waitsOnYou: Bool { self != .replying }

    public static func lead(needsYou: Bool, messages: [LeadMessage], status: AgentStatus?, isQueued: Bool) -> ChatActivity? {
        if needsYou || status == .needsInput { return .needsYou }
        if hasOpenProposal(messages) { return .planReady }
        if status == .working || isQueued { return .replying }
        return nil
    }

    public static func directChat(status: AgentStatus, awaitingReply: Bool, isQueued: Bool) -> ChatActivity? {
        if status == .needsInput { return .needsYou }
        if status == .working || (awaitingReply && isQueued) { return .replying }
        return nil
    }

    public static func hasOpenProposal(_ messages: [LeadMessage]) -> Bool {
        messages.contains { $0.kind == .proposal && $0.status == .open }
    }
}
