import Foundation

public enum SystemAlert: Identifiable, Hashable, Sendable {
    case claudeMissing
    case claudeBroken(String)
    case rateLimited(resetsAt: Date?)
    case hostDisconnected(projectID: Int64, host: String, projectName: String, error: String)

    public var id: String {
        switch self {
        case .claudeMissing: "claude-missing"
        case .claudeBroken: "claude-broken"
        case .rateLimited: "rate-limited"
        case .hostDisconnected(let projectID, _, _, _): "host-\(projectID)"
        }
    }

    public var title: String {
        switch self {
        case .claudeMissing: "Claude CLI not found"
        case .claudeBroken: "Claude CLI isn’t working"
        case .rateLimited: "Rate limit reached"
        case .hostDisconnected(_, let host, _, _): "\(host) disconnected"
        }
    }

    public var message: String {
        switch self {
        case .claudeMissing: "Ensemble needs the claude CLI. Nothing can run until it’s installed."
        case .claudeBroken(let detail): "The Lead can’t reply: \(detail)"
        case .rateLimited(let resetsAt):
            "The Lead and its workers are paused\(resetsAt.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""). Queued messages send then."
        case .hostDisconnected(_, _, let name, _): "\(name)’s chats are paused until it reconnects."
        }
    }

    public func affects(_ project: Project) -> Bool {
        switch self {
        case .hostDisconnected(let projectID, _, _, _): project.id == projectID
        default: true
        }
    }

    public static func detect(environment: EnvironmentReport?, planUsage: PlanUsage?, projects: [Project], remoteErrors: [Int64: String]) -> [SystemAlert] {
        var alerts: [SystemAlert] = []
        switch environment?.claude {
        case .missing: alerts.append(.claudeMissing)
        case .broken(_, let message): alerts.append(.claudeBroken(message))
        default: break
        }
        if let session = planUsage?.session, session.utilization >= 100 {
            alerts.append(.rateLimited(resetsAt: session.resetsAt))
        }
        for project in projects where project.isRemote {
            guard let id = project.id, let error = remoteErrors[id] else { continue }
            alerts.append(.hostDisconnected(projectID: id, host: project.location, projectName: project.name, error: error))
        }
        return alerts
    }
}
