import Foundation

public enum WorkerState: String, Sendable, Hashable, CaseIterable {
    case working
    case waitingOnYou
    case queued
    case idle
    case done
    case stopped
    case stuck
    case failed

    public static let defaultStallMinutes = 10

    public struct Facts: Sendable, Hashable {
        public var status: AgentStatus
        public var isRunning: Bool
        public var isQueued: Bool
        public var needsYou: Bool
        public var runFinished: Bool
        public var lastOutputAt: Date?
        public var stallMinutes: Int

        public init(
            status: AgentStatus, isRunning: Bool = false, isQueued: Bool = false, needsYou: Bool = false, runFinished: Bool = false,
            lastOutputAt: Date? = nil, stallMinutes: Int = WorkerState.defaultStallMinutes
        ) {
            self.status = status
            self.isRunning = isRunning
            self.isQueued = isQueued
            self.needsYou = needsYou
            self.runFinished = runFinished
            self.lastOutputAt = lastOutputAt
            self.stallMinutes = stallMinutes
        }
    }

    public static func of(_ facts: Facts, now: Date) -> WorkerState {
        if facts.needsYou || facts.status == .needsInput { return .waitingOnYou }
        switch facts.status {
        case .failed: return .failed
        case .stopped, .interrupted, .takenOver: return .stopped
        default: break
        }
        if facts.isRunning || facts.status == .working || facts.status == .reviewing {
            if let last = facts.lastOutputAt, now.timeIntervalSince(last) >= Double(facts.stallMinutes) * 60 { return .stuck }
            return .working
        }
        if facts.isQueued || facts.status == .waiting { return .queued }
        if facts.status == .paused { return .stopped }
        return facts.runFinished ? .done : .idle
    }

    public static func stallMinutes(for step: WorkflowStep?) -> Int {
        step?.timeoutMinutes.map { max(1, min($0, defaultStallMinutes)) } ?? defaultStallMinutes
    }
}
