import Foundation

public struct RunHistory: Sendable, Hashable {
    public struct Attempt: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var number: Int
        public var status: RunStepStatus
        public var outcome: String?
        public var summary: String?
        public var costUSD: Double
        public var startedAt: Date
        public var endedAt: Date?
    }

    public struct Handoff: Sendable, Hashable {
        public var plan: Plan?
        public var verdict: Verdict?
        public var result: String?
        public var taskResults: [TaskResult]

        public var isEmpty: Bool { plan == nil && verdict == nil && result == nil && taskResults.isEmpty }
    }

    public struct Hop: Sendable, Hashable {
        public var to: String
        public var toTitle: String
        public var outcome: String?
        public var isLoopBack: Bool
        public var loopNumber: Int
        public var maxLoops: Int?
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var stepId: String
        public var title: String
        public var type: StepType?
        public var role: String?
        public var iteration: Int
        public var attempts: [Attempt]
        public var handoff: Handoff
        public var feedback: Feedback?
        public var hop: Hop?
        public var agentIDs: [Int64]

        public var latest: Attempt? { attempts.last }
        public var status: RunStepStatus { latest?.status ?? .running }
        public var outcome: String? { latest?.outcome }
        public var outcomeTitle: String? { outcome.map(RunTimeline.title(forOutcome:)) }
        public var summary: String? { handoff.verdict?.summary ?? latest?.summary }
        public var issues: [ReviewIssue] { handoff.verdict?.issues ?? [] }
        public var costUSD: Double { attempts.reduce(0) { $0 + $1.costUSD } }
        public var startedAt: Date { attempts.first?.startedAt ?? .distantPast }
        public var endedAt: Date? { status == .running || status == .waitingOnYou ? nil : latest?.endedAt }

        public func duration(now: Date) -> TimeInterval {
            max(0, (endedAt ?? now).timeIntervalSince(startedAt))
        }
    }

    public var entries: [Entry]

    public var loops: [Hop] { entries.compactMap(\.hop).filter(\.isLoopBack) }

    public init(workflow: WorkflowDefinition, steps: [RunStep], agents: [Agent] = []) {
        let ordered = steps.filter { $0.id != nil }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let groups = Self.group(ordered)
        let edges = RunGraph.edges(of: workflow)
        var loopCounts: [String: Int] = [:]
        var entries: [Entry] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let firstID = first.id else { continue }
            let attemptIDs = Set(group.compactMap(\.id))
            let attempts = group.enumerated().compactMap { offset, row -> Attempt? in
                guard let id = row.id else { return nil }
                return Attempt(
                    id: id, number: offset + 1, status: row.status, outcome: row.outcome,
                    summary: RunTimeline.decodeOutput(row.output).summary, costUSD: row.costUSD,
                    startedAt: row.startedAt, endedAt: row.endedAt
                )
            }
            let output = RunTimeline.decodeOutput(group.last?.output)
            var hop: Hop?
            if let last = group.last, index + 1 < groups.count, let next = groups[index + 1].first, last.status == .succeeded,
               let edge = RunGraph.edge(for: RunGraph.Transition(from: last, to: next), among: edges) {
                var loopNumber = 0
                if edge.isLoopBack {
                    loopCounts[edge.id, default: 0] += 1
                    loopNumber = loopCounts[edge.id] ?? 0
                }
                hop = Hop(
                    to: next.stepId, toTitle: RunTimeline.title(ofStep: next.stepId, in: workflow), outcome: last.outcome,
                    isLoopBack: edge.isLoopBack, loopNumber: loopNumber, maxLoops: edge.maxLoops
                )
            }
            entries.append(Entry(
                id: firstID, stepId: first.stepId, title: RunTimeline.title(ofStep: first.stepId, in: workflow),
                type: workflow.step(first.stepId)?.type, role: workflow.step(first.stepId)?.role,
                iteration: first.iteration, attempts: attempts,
                handoff: Handoff(plan: output.plan, verdict: output.verdict, result: output.verdict == nil ? output.summary : nil, taskResults: output.taskResults),
                feedback: Self.decodeFeedback(first.input), hop: hop,
                agentIDs: agents.filter { $0.runStepId.map(attemptIDs.contains) == true }.compactMap(\.id)
            ))
        }
        self.entries = entries
    }

    public static func group(_ steps: [RunStep]) -> [[RunStep]] {
        steps.reduce(into: [[RunStep]]()) { groups, step in
            if let last = groups.last?.last, last.stepId == step.stepId, last.iteration == step.iteration {
                groups[groups.count - 1].append(step)
            } else {
                groups.append([step])
            }
        }
    }

    static func decodeFeedback(_ input: String?) -> Feedback? {
        input.flatMap { try? JSONDecoder().decode(StepInputs.self, from: Data($0.utf8)) }?.feedback
    }
}

