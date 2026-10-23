import Foundation

public enum WorkflowLayout {
    public static let centerX = 400.0
    public static let top = 60.0
    public static let rowSpacing = 120.0
    public static let columnSpacing = 240.0

    public static func depths(of workflow: WorkflowDefinition) -> [String: Int] {
        var depths: [String: Int] = [:]
        let forward = workflow.edges.filter { !$0.isLoopBack && $0.from != WorkflowDefinition.triggerNodeID }
        for (index, step) in workflow.steps.enumerated() {
            if index == 0 {
                depths[step.id] = 1
                continue
            }
            let incoming = forward.filter { $0.to == step.id }.compactMap { depths[$0.from] }
            depths[step.id] = (incoming.max() ?? depths[workflow.steps[index - 1].id] ?? 1) + 1
        }
        return depths
    }

    public static func positions(for workflow: WorkflowDefinition) -> [String: CanvasPosition] {
        let depths = depths(of: workflow)
        var rows: [Int: [String]] = [:]
        for step in workflow.steps {
            rows[depths[step.id] ?? 1, default: []].append(step.id)
        }
        var positions: [String: CanvasPosition] = [:]
        for (depth, ids) in rows {
            for (column, id) in ids.enumerated() {
                let offset = Double(column) - Double(ids.count - 1) / 2
                positions[id] = CanvasPosition(x: centerX + offset * columnSpacing, y: top + Double(depth) * rowSpacing)
            }
        }
        for step in workflow.steps {
            if let stored = step.position { positions[step.id] = stored }
        }
        let first = workflow.steps.first.flatMap { positions[$0.id] } ?? CanvasPosition(x: centerX, y: top + rowSpacing)
        positions[WorkflowDefinition.triggerNodeID] = CanvasPosition(x: first.x, y: first.y - rowSpacing)
        let stepPositions = workflow.steps.compactMap { positions[$0.id] }
        let lowest = stepPositions.map(\.y).max() ?? first.y - rowSpacing
        let last = workflow.steps.last.flatMap { positions[$0.id] } ?? first
        positions[WorkflowDefinition.endStepID] = CanvasPosition(x: last.x, y: lowest + rowSpacing)
        return positions
    }
}
