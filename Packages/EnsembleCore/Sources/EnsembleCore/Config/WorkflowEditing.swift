import Foundation

public struct WorkflowEdge: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case start
        case next
        case route
        case implicit
    }

    public var from: String
    public var to: String
    public var kind: Kind
    public var outcome: String?
    public var maxLoops: Int?
    public var isLoopBack: Bool

    public init(from: String, to: String, kind: Kind, outcome: String? = nil, maxLoops: Int? = nil, isLoopBack: Bool = false) {
        self.from = from
        self.to = to
        self.kind = kind
        self.outcome = outcome
        self.maxLoops = maxLoops
        self.isLoopBack = isLoopBack
    }

    public var id: String { "\(from)|\(outcome ?? kind.rawValue)|\(to)" }
}

extension WorkflowDefinition {
    public static let triggerNodeID = "@trigger"

    public static func blank(id: String, name: String) -> WorkflowDefinition {
        WorkflowDefinition(id: id, name: name, version: 1, steps: [])
    }

    public func duplicated(id: String, name: String) -> WorkflowDefinition {
        var copy = self
        copy.id = id
        copy.name = name
        copy.version = 1
        return copy
    }

    public func index(of stepID: String) -> Int? {
        steps.firstIndex { $0.id == stepID }
    }

    public func implicitTarget(after stepID: String) -> String {
        guard let index = index(of: stepID), index + 1 < steps.count else { return Self.endStepID }
        return steps[index + 1].id
    }

    public func isLoopBack(from source: String, to target: String) -> Bool {
        guard let from = index(of: source), let to = index(of: target) else { return false }
        return to <= from
    }

    public var edges: [WorkflowEdge] {
        var edges = [WorkflowEdge(from: Self.triggerNodeID, to: steps.first?.id ?? Self.endStepID, kind: .start)]
        for step in steps {
            for outcome in step.routes.keys.sorted() {
                guard let route = step.routes[outcome] else { continue }
                edges.append(WorkflowEdge(
                    from: step.id, to: route.to, kind: .route, outcome: outcome, maxLoops: route.maxLoops,
                    isLoopBack: isLoopBack(from: step.id, to: route.to)
                ))
            }
            if let next = step.next {
                edges.append(WorkflowEdge(from: step.id, to: next, kind: .next, isLoopBack: isLoopBack(from: step.id, to: next)))
            } else if step.routes.isEmpty {
                edges.append(WorkflowEdge(from: step.id, to: implicitTarget(after: step.id), kind: .implicit))
            }
        }
        return edges
    }

    public func hasBehaviorChanges(comparedTo saved: WorkflowDefinition) -> Bool {
        Self.withoutLayout(self) != Self.withoutLayout(saved)
    }

    public func preparedForSave(comparedTo saved: WorkflowDefinition?) -> WorkflowDefinition {
        guard let saved, hasBehaviorChanges(comparedTo: saved) else { return self }
        var prepared = self
        prepared.version = max(saved.version, version) + 1
        return prepared
    }

    private static func withoutLayout(_ workflow: WorkflowDefinition) -> WorkflowDefinition {
        var stripped = workflow
        stripped.version = 0
        stripped.steps = stripped.steps.map { step in
            var step = step
            step.position = nil
            return step
        }
        return stripped
    }

    public func uniqueStepID(base: String) -> String {
        let slug = Slug.make(base)
        let root = slug.isEmpty || slug == Self.endStepID ? "step" : slug
        let taken = Set(steps.map(\.id))
        if !taken.contains(root) { return root }
        return (2...).lazy.map { "\(root)-\($0)" }.first { !taken.contains($0) } ?? root
    }

    @discardableResult
    public mutating func addStep(
        _ type: StepType, role: String? = nil, title: String? = nil, position: CanvasPosition? = nil
    ) -> WorkflowStep {
        let id = uniqueStepID(base: Self.defaultStepBase(type, role: role))
        if let last = steps.indices.last, steps[last].routes.isEmpty,
           steps[last].next == nil || steps[last].next == Self.endStepID {
            steps[last].next = id
        }
        let step = WorkflowStep(
            id: id,
            type: type,
            title: title,
            role: type == .agent || type == .spawn ? role : nil,
            maxAgents: type == .spawn ? 4 : nil,
            condition: type == .condition ? StepCondition() : nil,
            next: type == .condition || type == .approval ? nil : Self.endStepID,
            position: position
        )
        steps.append(step)
        return step
    }

    private static func defaultStepBase(_ type: StepType, role: String?) -> String {
        switch type {
        case .agent: role ?? "agent"
        case .spawn: "build"
        case .condition: "check"
        case .approval: "approve"
        case .notify: "notify"
        case .check: "checks"
        case .gates: "gates"
        }
    }

    public mutating func removeStep(_ id: String) {
        guard let index = index(of: id) else { return }
        let removed = steps[index]
        let splice = removed.next ?? (removed.routes.isEmpty ? implicitTarget(after: id) : nil)
        let survivorAfter = splice == id ? nil : splice
        steps.remove(at: index)
        for position in steps.indices {
            if steps[position].next == id { steps[position].next = survivorAfter }
            steps[position].routes = steps[position].routes.filter { $0.value.to != id }
            if steps[position].condition?.outcomeOf == id { steps[position].condition?.outcomeOf = nil }
        }
    }

    @discardableResult
    public mutating func renameStep(_ id: String, to newID: String) -> Bool {
        let candidate = Slug.make(newID)
        guard !candidate.isEmpty, candidate != Self.endStepID, index(of: candidate) == nil, let index = index(of: id) else { return false }
        steps[index].id = candidate
        for position in steps.indices {
            if steps[position].next == id { steps[position].next = candidate }
            for (outcome, route) in steps[position].routes where route.to == id {
                steps[position].routes[outcome]?.to = candidate
            }
            if steps[position].condition?.outcomeOf == id { steps[position].condition?.outcomeOf = candidate }
        }
        return true
    }

    public mutating func makeExplicit() {
        for index in steps.indices where steps[index].next == nil && steps[index].routes.isEmpty {
            steps[index].next = implicitTarget(after: steps[index].id)
        }
    }

    public mutating func makeFirst(_ id: String) {
        guard let index = index(of: id), index > 0 else { return }
        makeExplicit()
        steps.insert(steps.remove(at: index), at: 0)
    }

    public mutating func move(_ id: String, to position: CanvasPosition) {
        guard let index = index(of: id) else { return }
        steps[index].position = position
    }

    @discardableResult
    public mutating func connect(from source: String, to target: String) -> String? {
        if source == Self.triggerNodeID {
            makeFirst(target)
            return nil
        }
        guard let index = index(of: source), target == Self.endStepID || self.index(of: target) != nil else { return nil }
        let step = steps[index]
        if step.next == target || step.routes.values.contains(where: { $0.to == target }) { return nil }
        let isGate = step.type == .condition || step.type == .approval
        if !isGate && step.routes.isEmpty && (step.next == nil || step.next == Self.endStepID) {
            steps[index].next = target
            return nil
        }
        let outcome = Self.unusedOutcome(for: step)
        setRoute(from: source, outcome: outcome, to: target)
        return outcome
    }

    public static func suggestedOutcomes(for type: StepType) -> [String] {
        switch type {
        case .condition: [StepOutcome.yes, StepOutcome.no]
        case .approval: [StepOutcome.approved, StepOutcome.changesRequested]
        case .agent, .spawn: [StepOutcome.approved, StepOutcome.changesRequested, StepOutcome.passed, StepOutcome.failed, StepOutcome.done]
        case .notify: [StepOutcome.done]
        case .check: [StepOutcome.passed]
        case .gates: [StepOutcome.passed, StepOutcome.changesRequested]
        }
    }

    public static func unusedOutcome(for step: WorkflowStep) -> String {
        let used = Set(step.routes.keys)
        if let free = suggestedOutcomes(for: step.type).first(where: { !used.contains($0) }) { return free }
        return (2...).lazy.map { "outcome-\($0)" }.first { !used.contains($0) } ?? "outcome"
    }

    public mutating func setRoute(from source: String, outcome: String, to target: String, maxLoops: Int? = nil) {
        guard let index = index(of: source) else { return }
        let loops = maxLoops ?? (isLoopBack(from: source, to: target) ? 3 : nil)
        if steps[index].routes.isEmpty && steps[index].next == Self.endStepID {
            steps[index].next = nil
        }
        steps[index].routes[outcome] = WorkflowRoute(to: target, maxLoops: loops)
    }

    public mutating func removeRoute(from source: String, outcome: String) {
        guard let index = index(of: source) else { return }
        steps[index].routes[outcome] = nil
    }

    @discardableResult
    public mutating func renameRoute(from source: String, outcome: String, to newOutcome: String) -> Bool {
        let trimmed = newOutcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(of: source), !trimmed.isEmpty, steps[index].routes[trimmed] == nil,
              let route = steps[index].routes.removeValue(forKey: outcome) else { return false }
        steps[index].routes[trimmed] = route
        return true
    }

    public mutating func removeEdge(_ edge: WorkflowEdge) {
        switch edge.kind {
        case .route:
            if let outcome = edge.outcome { removeRoute(from: edge.from, outcome: outcome) }
        case .next:
            guard let index = index(of: edge.from) else { return }
            steps[index].next = steps[index].routes.isEmpty ? Self.endStepID : nil
        case .start, .implicit:
            break
        }
    }
}

extension ProjectConfigLoader {
    public static func workflowsDirectory(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: "workflows", directoryHint: .isDirectory)
    }

    public static func deleteWorkflow(_ id: String, repository: URL) throws {
        let directory = workflowsDirectory(in: repository)
        var removed = false
        for name in ["\(id).yaml", "\(id).yml"] {
            let file = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
                removed = true
            }
        }
        if !removed { throw CocoaError(.fileNoSuchFile) }
    }

    @discardableResult
    public static func save(_ draft: WorkflowDefinition, comparedTo saved: WorkflowDefinition?, repository: URL) throws -> WorkflowDefinition {
        let prepared = draft.preparedForSave(comparedTo: saved)
        try write(prepared, repository: repository)
        let twin = workflowsDirectory(in: repository).appending(path: "\(prepared.id).yml")
        if FileManager.default.fileExists(atPath: twin.path) {
            try FileManager.default.removeItem(at: twin)
        }
        return prepared
    }

    public static func newWorkflowID(for name: String, existing: [WorkflowDefinition]) -> String {
        let slug = Slug.make(name)
        let root = slug.isEmpty ? "workflow" : slug
        let taken = Set(existing.map(\.id))
        if !taken.contains(root) { return root }
        return (2...).lazy.map { "\(root)-\($0)" }.first { !taken.contains($0) } ?? root
    }
}
