import SaturnCore
import SaturnUI
import SwiftUI

extension RunStatus {
    var label: String {
        switch self {
        case .pending: "Starting"
        case .running: "Running"
        case .waitingOnYou: "Waiting for you"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .running: Theme.success
        case .waitingOnYou, .interrupted: Theme.warning
        case .paused: Theme.paused
        case .succeeded: Theme.info
        case .failed: Theme.danger
        case .pending, .cancelled: Theme.neutral
        }
    }
}

extension RunStepStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .waitingOnYou: "Waiting for you"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    var color: Color {
        switch self {
        case .running: Theme.success
        case .waitingOnYou, .interrupted: Theme.warning
        case .succeeded: Theme.successText
        case .failed: Theme.danger
        case .cancelled: Theme.neutral
        }
    }
}

extension RunStepStatus {
    func displayColor(needsYou: Bool) -> Color {
        needsYou ? Theme.warning : color
    }

    func displayLabel(needsYou: Bool) -> String {
        needsYou ? RunStepStatus.waitingOnYou.label : label
    }
}

extension RunTimeline.StageState {
    var color: Color {
        switch self {
        case .done: Theme.success
        case .current: Theme.accent
        case .waiting: Theme.warning
        case .failed: Theme.danger
        case .upcoming: Tokens.fill2
        }
    }

    var label: String {
        switch self {
        case .done: "done"
        case .current: "in progress"
        case .waiting: "waiting for you"
        case .failed: "failed"
        case .upcoming: "not started"
        }
    }
}

extension AppModel {
    static func statusColor(needsYou: Bool, otherwise color: Color) -> Color {
        needsYou ? Theme.warning : color
    }
}

extension DaemonWorkspace {
    func statusColor(of run: Run) -> Color {
        if run.id.flatMap(leadFixing(runID:)) != nil { return RunStatus.running.color }
        return AppModel.statusColor(needsYou: runNeedsYou(run), otherwise: run.status.color)
    }

    func statusLabel(of run: Run) -> String {
        if let fixing = run.id.flatMap(leadFixing(runID:)) { return fixing }
        return runNeedsYou(run) ? RunStatus.waitingOnYou.label : run.status.label
    }

    func statusColor(of request: Chat, latestRun: Run?, needsYouTaskIDs: Set<Int64>) -> Color {
        let needsYou = pendingApprovalCount(of: request) > 0 || requestNeedsYou(request, latestRun: latestRun, needsYouTaskIDs: needsYouTaskIDs)
        return AppModel.statusColor(needsYou: needsYou, otherwise: latestRun?.status.color ?? Theme.secondaryText)
    }
}

extension Run {
    var elapsedDescription: String {
        let seconds = (endedAt ?? .now).timeIntervalSince(startedAt)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(seconds, 60)) ?? ""
    }
}

struct RoleBadge: View {
    let role: RoleDefinition?
    var size: CGFloat = 20

    var body: some View {
        AgentAvatar(size: size, appearance: RoleAppearance(role: role))
    }
}
