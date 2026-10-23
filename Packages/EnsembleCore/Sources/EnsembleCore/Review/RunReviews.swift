import Foundation
import Yams

public struct FileReview: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        case approved
        case changesRequested
        case reviewing
    }

    public var reviewer: String
    public var role: String?
    public var stepId: String
    public var state: State
    public var notes: [String]

    public init(reviewer: String, role: String?, stepId: String, state: State, notes: [String] = []) {
        self.reviewer = reviewer
        self.role = role
        self.stepId = stepId
        self.state = state
        self.notes = notes
    }

    public var id: String { "\(stepId)|\(reviewer)" }
}

public struct RunReviews: Sendable, Hashable {
    struct StepReview: Sendable, Hashable {
        var reviewer: String
        var role: String?
        var stepId: String
        var state: FileReview.State
        var issues: [ReviewIssue]
    }

    var steps: [StepReview]

    public static let empty = RunReviews(steps: [])

    public func reviews(for path: String) -> [FileReview] {
        steps.map { step in
            let notes = step.issues.filter { $0.file.map { Self.matches(issueFile: $0, path: path) } ?? false }.map(\.description)
            let mentionsAnyFile = step.issues.contains { $0.file != nil }
            let state: FileReview.State = switch step.state {
            case .changesRequested where mentionsAnyFile && notes.isEmpty: .approved
            default: step.state
            }
            return FileReview(reviewer: step.reviewer, role: step.role, stepId: step.stepId, state: state, notes: notes)
        }
    }

    public static func derive(run: Run, steps: [RunStep], agents: [Agent]) -> RunReviews {
        let workflow = try? YAMLDecoder().decode(WorkflowDefinition.self, from: run.workflowSnapshot)
        var latest: [String: RunStep] = [:]
        var order: [String] = []
        for step in steps.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            if latest[step.stepId] == nil { order.append(step.stepId) }
            latest[step.stepId] = step
        }
        let reviews = order.compactMap { stepId -> StepReview? in
            guard let runStep = latest[stepId] else { return nil }
            let definition = workflow?.step(stepId)
            if let definition, definition.type != .agent { return nil }
            let stepAgents = agents.filter { $0.runStepId == runStep.id && runStep.id != nil }
            let reviewer = reviewerName(agents: stepAgents, definition: definition, stepId: stepId)
            let role = stepAgents.first?.role ?? definition?.role
            if runStep.status == .running {
                let isReviewing = stepAgents.contains(where: \.readOnly) || hasEverReviewed(stepId, in: steps)
                return isReviewing ? StepReview(reviewer: reviewer, role: role, stepId: stepId, state: .reviewing, issues: []) : nil
            }
            guard runStep.status == .succeeded, let verdict = decodeVerdict(runStep.output) else { return nil }
            let state: FileReview.State = approvingOutcomes.contains(verdict.outcome) ? .approved : .changesRequested
            return StepReview(reviewer: reviewer, role: role, stepId: stepId, state: state, issues: verdict.issues)
        }
        return RunReviews(steps: reviews)
    }

    static let approvingOutcomes: Set<String> = [StepOutcome.approved, StepOutcome.passed, StepOutcome.done]

    static func matches(issueFile: String, path: String) -> Bool {
        var file = issueFile.trimmingCharacters(in: .whitespaces)
        if let colon = file.firstIndex(of: ":"), file[file.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == "-" || $0 == "–" }) {
            file = String(file[..<colon])
        }
        while file.hasPrefix("./") { file.removeFirst(2) }
        guard !file.isEmpty else { return false }
        return path == file || path.hasSuffix("/" + file) || file.hasSuffix("/" + path)
    }

    private static func reviewerName(agents: [Agent], definition: WorkflowStep?, stepId: String) -> String {
        if !agents.isEmpty { return agents.map(\.name).joined(separator: ", ") }
        return definition?.role ?? definition?.title ?? stepId
    }

    private static func hasEverReviewed(_ stepId: String, in steps: [RunStep]) -> Bool {
        steps.contains { $0.stepId == stepId && decodeVerdict($0.output) != nil }
    }

    private static func decodeVerdict(_ output: String?) -> Verdict? {
        guard let output, let decoded = try? JSONDecoder().decode(StepOutput.self, from: Data(output.utf8)) else { return nil }
        return decoded.verdict
    }
}
