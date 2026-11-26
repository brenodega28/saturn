import Foundation

public struct RunGraph: Sendable, Hashable {
    public enum NodeState: String, Sendable, Hashable {
        case upcoming
        case visited
        case running
        case waiting
        case paused
        case failed
    }

    public struct Node: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var type: StepType?
        public var agent: AgentKind?
        public var layer: Int
        public var column: Int
        public var visits: Int
        public var state: NodeState

        public var isEnd: Bool { id == WorkflowDefinition.endStepID }
    }

    public struct Edge: Sendable, Hashable, Identifiable {
        public var from: String
        public var to: String
        public var outcome: String?
        public var maxLoops: Int?
        public var isLoopBack: Bool
        public var timesTaken: Int

        public var id: String { "\(from)|\(outcome ?? "next")|\(to)" }
        public var label: String? { outcome.map(RunTimeline.title(forOutcome:)) }
    }

    public struct Transition: Sendable, Hashable {
        public var from: RunStep
        public var to: RunStep
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public var layerCount: Int { (nodes.map(\.layer).max() ?? -1) + 1 }
    public var columnCount: Int {
        Dictionary(grouping: nodes, by: \.layer).values.map(\.count).max() ?? 0
    }

    public func node(_ id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    public init(workflow: WorkflowDefinition, run: Run, steps: [RunStep], hold: RunHold?) {
        let layers = Self.layers(of: workflow)
        let ordered = steps.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        let ids = workflow.steps.map(\.id) + [WorkflowDefinition.endStepID]
        var columns: [Int: Int] = [:]
        self.nodes = ids.map { id in
            let layer = layers[id] ?? 0
            let column = columns[layer, default: 0]
            columns[layer] = column + 1
            let step = workflow.step(id)
            return Node(
                id: id, title: RunTimeline.title(ofStep: id, in: workflow), type: step?.type, agent: step?.agent,
                layer: layer, column: column, visits: Self.visits(of: id, in: ordered),
                state: Self.state(of: id, run: run, hold: hold, steps: ordered)
            )
        }
        let known = Set(ids)
        let candidates = Self.edges(of: workflow).filter { known.contains($0.from) && known.contains($0.to) }
        var taken: [String: Int] = [:]
        for transition in Self.transitions(ordered) {
            if let edge = Self.edge(for: transition, among: candidates) {
                taken[edge.id, default: 0] += 1
            }
        }
        self.edges = candidates.map { edge in
            var edge = edge
            edge.timesTaken = taken[edge.id] ?? 0
            return edge
        }
    }

    public static func layers(of workflow: WorkflowDefinition) -> [String: Int] {
        var layers = WorkflowLayout.depths(of: workflow).mapValues { $0 - 1 }
        layers[WorkflowDefinition.endStepID] = (layers.values.max() ?? -1) + 1
        return layers
    }

    public static func edges(of workflow: WorkflowDefinition) -> [Edge] {
        workflow.edges
            .filter { $0.from != WorkflowDefinition.triggerNodeID }
            .map { edge in
                Edge(
                    from: edge.from, to: edge.to, outcome: edge.kind == .route ? edge.outcome : nil,
                    maxLoops: edge.maxLoops, isLoopBack: edge.isLoopBack || edge.from == edge.to, timesTaken: 0
                )
            }
    }

    public static func transitions(_ steps: [RunStep]) -> [Transition] {
        let ordered = steps.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, next in
            let isRetry = previous.stepId == next.stepId && previous.iteration == next.iteration
            guard !isRetry, previous.status == .succeeded else { return nil }
            return Transition(from: previous, to: next)
        }
    }

    static func edge(for transition: Transition, among edges: [Edge]) -> Edge? {
        let candidates = edges.filter { $0.from == transition.from.stepId && $0.to == transition.to.stepId }
        return candidates.first { $0.outcome != nil && $0.outcome == transition.from.outcome }
            ?? candidates.first { $0.outcome == nil }
            ?? candidates.first
    }

    static func visits(of stepId: String, in steps: [RunStep]) -> Int {
        Set(steps.filter { $0.stepId == stepId }.map(\.iteration)).count
    }

    static func state(of stepId: String, run: Run, hold: RunHold?, steps: [RunStep]) -> NodeState {
        let visited = steps.contains { $0.stepId == stepId }
        guard stepId == run.currentStep else { return visited ? .visited : .upcoming }
        switch run.status {
        case .pending, .running:
            return .running
        case .waitingOnYou where hold?.isLeadFixing == true:
            return .running
        case .waitingOnYou:
            return hold.map { [.stepFailed, .timedOut].contains($0.reason) } == true ? .failed : .waiting
        case .paused, .interrupted:
            return .paused
        case .failed:
            return .failed
        case .succeeded:
            return .visited
        case .cancelled:
            return visited ? .visited : .upcoming
        }
    }
}
