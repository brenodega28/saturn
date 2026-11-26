import Foundation

public enum ChatStage: String, Sendable, Hashable, CaseIterable {
    case needsYou
    case stuck
    case building
    case inReview
    case finished
    case done
    case dropped
    case idle

    public var needsAttention: Bool { self == .needsYou || self == .stuck }

    public struct Facts: Sendable, Hashable {
        public var closeReason: RequestCloseReason?
        public var isClosed: Bool
        public var isFinished: Bool
        public var latestRun: Run?
        public var currentStep: WorkflowStep?
        public var hold: RunHold?
        public var openRequests: [ChatRequestKind]
        public var pendingPermissions: Int
        public var hasOpenProposal: Bool
        public var leadIsWorking: Bool

        public init(
            closeReason: RequestCloseReason? = nil, isClosed: Bool = false, isFinished: Bool = false, latestRun: Run? = nil, currentStep: WorkflowStep? = nil,
            hold: RunHold? = nil, openRequests: [ChatRequestKind] = [], pendingPermissions: Int = 0, hasOpenProposal: Bool = false,
            leadIsWorking: Bool = false
        ) {
            self.closeReason = closeReason
            self.isClosed = isClosed
            self.isFinished = isFinished
            self.latestRun = latestRun
            self.currentStep = currentStep
            self.hold = hold
            self.openRequests = openRequests
            self.pendingPermissions = pendingPermissions
            self.hasOpenProposal = hasOpenProposal
            self.leadIsWorking = leadIsWorking
        }
    }

    static let stuckKinds: Set<ChatRequestKind> = [.failure, .loopLimit]
    static let stuckHolds: Set<HoldReason> = [.stepFailed, .timedOut, .loopLimit]

    public static func detail(_ facts: Facts) -> String? {
        facts.isClosed ? nil : facts.hold?.leadFixingTitle
    }

    public static func of(_ facts: Facts) -> ChatStage {
        if facts.isClosed { return facts.closeReason == .dropped ? .dropped : .done }
        let hold = facts.hold.flatMap { $0.isLeadFixing ? nil : $0 }
        if let hold, stuckHolds.contains(hold.reason) { return .stuck }
        if facts.openRequests.contains(where: stuckKinds.contains) { return .stuck }
        if let run = facts.latestRun, run.status == .failed || run.status == .interrupted { return .stuck }
        if hold != nil || facts.pendingPermissions > 0 || facts.hasOpenProposal { return .needsYou }
        if facts.openRequests.contains(where: { $0 != .notice && $0 != .pinReview }) { return .needsYou }
        if let run = facts.latestRun, run.isActive {
            return facts.currentStep?.agent == .checker || facts.currentStep?.type == .gates ? .inReview : .building
        }
        if facts.leadIsWorking { return .building }
        if facts.isFinished { return .finished }
        if let run = facts.latestRun, run.status == .succeeded { return .finished }
        return .idle
    }
}
