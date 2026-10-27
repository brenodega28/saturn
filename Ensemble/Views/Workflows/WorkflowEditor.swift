import EnsembleCore
import Foundation
import Observation

enum WorkflowSelection: Hashable {
    case workflow
    case trigger
    case end
    case step(String)

    init(nodeID: String) {
        switch nodeID {
        case WorkflowDefinition.triggerNodeID: self = .trigger
        case WorkflowDefinition.endStepID: self = .end
        default: self = .step(nodeID)
        }
    }

    var nodeID: String? {
        switch self {
        case .workflow: nil
        case .trigger: WorkflowDefinition.triggerNodeID
        case .end: WorkflowDefinition.endStepID
        case .step(let id): id
        }
    }
}

@MainActor
@Observable
final class WorkflowEditor {
    private(set) var saved: WorkflowDefinition?
    var draft: WorkflowDefinition
    var selection: WorkflowSelection = .workflow
    var script: DryRunScript
    var report: DryRunReport?
    var isTestRunning = false
    var errorMessage: String?

    init(workflow: WorkflowDefinition, isNew: Bool) {
        self.saved = isNew ? nil : workflow
        self.draft = workflow
        self.script = .happyPath(for: workflow)
    }

    var isNew: Bool { saved == nil }
    var isDirty: Bool { saved.map { $0 != draft } ?? true }
    var willBumpVersion: Bool { saved.map { draft.hasBehaviorChanges(comparedTo: $0) } ?? false }
    var nextVersion: Int { draft.preparedForSave(comparedTo: saved).version }

    var selectedStep: WorkflowStep? {
        guard case .step(let id) = selection else { return nil }
        return draft.step(id)
    }

    func select(_ selection: WorkflowSelection) {
        if case .step(let id) = selection, draft.step(id) == nil {
            self.selection = .workflow
        } else {
            self.selection = selection
        }
    }

    func edit(_ change: (inout WorkflowDefinition) -> Void) {
        change(&draft)
        if case .step(let id) = selection, draft.step(id) == nil { selection = .workflow }
    }

    func addStep(_ type: StepType, role: RoleDefinition?, at position: CanvasPosition?) {
        let title: String? = switch type {
        case .agent: role.map { $0.name }
        case .spawn: "Build in parallel"
        case .condition: "Check"
        case .approval: "You approve"
        case .notify: "Notify me"
        case .check: "Run checks"
        }
        let step = draft.addStep(type, role: role?.id, title: title, position: position ?? nextFreePosition())
        selection = .step(step.id)
    }

    func assignRole(_ role: RoleDefinition, to stepID: String) {
        guard let index = draft.index(of: stepID), [.agent, .spawn].contains(draft.steps[index].type) else { return }
        draft.steps[index].role = role.id
        selection = .step(stepID)
    }

    func renameStep(_ id: String, to newID: String) -> Bool {
        let candidate = Slug.make(newID)
        guard draft.renameStep(id, to: newID) else { return false }
        selection = .step(candidate)
        script.outcomes[candidate] = script.outcomes.removeValue(forKey: id)
        return true
    }

    func deleteSelectedStep() {
        guard case .step(let id) = selection else { return }
        draft.removeStep(id)
        selection = .workflow
    }

    func tidyUp() {
        for index in draft.steps.indices { draft.steps[index].position = nil }
    }

    func revert() {
        guard let saved else { return }
        draft = saved
        select(selection)
    }

    func markSaved(_ written: WorkflowDefinition) {
        saved = written
        draft = written
        select(selection)
    }

    func runTest() async {
        isTestRunning = true
        defer { isTestRunning = false }
        do {
            report = try await DryRun.run(draft, script: script)
            errorMessage = nil
        } catch {
            report = nil
            errorMessage = "The test run couldn’t start: \(error.localizedDescription)"
        }
    }

    private func nextFreePosition() -> CanvasPosition {
        let positions = WorkflowLayout.positions(for: draft)
        let end = positions[WorkflowDefinition.endStepID] ?? CanvasPosition(x: WorkflowLayout.centerX, y: WorkflowLayout.top)
        return CanvasPosition(x: end.x, y: end.y)
    }
}
