import EnsembleCore
import EnsembleUI
import SwiftUI

enum RunDetailSection: String, CaseIterable, Identifiable {
    case timeline
    case agents
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .agents: "Agents"
        case .logs: "Logs"
        }
    }
}

enum RunDetailFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    static func dollars(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD"))
    }

    static func runTitle(_ run: Run) -> String {
        run.title.isEmpty ? "Run #\(run.id ?? 0)" : run.title
    }
}

extension RunGraph.NodeState {
    var color: Color {
        switch self {
        case .upcoming: Theme.neutral
        case .visited: Theme.success
        case .running: Theme.accent
        case .waiting: Theme.warning
        case .paused: Theme.paused
        case .failed: Theme.danger
        }
    }

    var label: String {
        switch self {
        case .upcoming: "not reached"
        case .visited: "done"
        case .running: "running"
        case .waiting: "waiting for you"
        case .paused: "paused"
        case .failed: "failed"
        }
    }

    var isLive: Bool { self != .upcoming && self != .visited }
}

extension StepType {
    var runSymbol: String {
        switch self {
        case .agent: "person.crop.square"
        case .spawn: "arrow.triangle.branch"
        case .condition: "diamond"
        case .approval: "person.fill.checkmark"
        case .notify: "bell"
        case .check: "checkmark.shield"
        case .gates: "exclamationmark.shield"
        }
    }
}

extension ChatRequestState {
    var label: String {
        switch self {
        case .open: "Open"
        case .answered: "Answered"
        case .dismissed: "Dismissed"
        case .expired: "Expired"
        }
    }
}

extension HoldReason {
    var title: String {
        switch self {
        case .planApproval: "Waiting for plan approval"
        case .approval: "Waiting for your approval"
        case .loopLimit: "Loop limit reached"
        case .stepBudget: "Step went over budget"
        case .runBudget: "Run reached its budget"
        case .stepFailed: "Step failed"
        case .timedOut: "Step timed out"
        case .gates: "Gate findings"
        }
    }

    var allowsRetry: Bool { self == .stepFailed || self == .timedOut }
}

struct StepGlyph: View {
    let type: StepType?
    let role: RoleDefinition?
    var size: CGFloat = 22

    var body: some View {
        if let type, type == .agent || type == .spawn {
            AgentAvatar(size: size, appearance: RoleAppearance(role: role))
        } else {
            Image(systemName: type?.runSymbol ?? "flag.checkered")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .frame(width: size, height: size)
                .background(Tokens.fill2, in: .rect(cornerRadius: size * 0.3, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
