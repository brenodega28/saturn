import Foundation
import Yams

extension Run {
    public var workflowDefinition: WorkflowDefinition? {
        guard var workflow = try? YAMLDecoder().decode(WorkflowDefinition.self, from: workflowSnapshot) else { return nil }
        workflow.id = self.workflow
        return workflow
    }
}
