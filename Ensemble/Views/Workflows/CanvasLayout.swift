import EnsembleCore
import EnsembleUI
import SwiftUI

struct CanvasNode: Identifiable {
    let id: String
    let selection: WorkflowSelection
    let frame: CGRect
    let style: NodeStyle
    let title: String
    let subtitle: String?
    let accessibilityLabel: String
}

struct CanvasEdge: Identifiable {
    let edge: WorkflowEdge
    let points: [CGPoint]
    let label: String?
    let labelPoint: CGPoint
    let labelAlignment: Alignment
    let color: Color

    var id: String { edge.id }
}

struct CanvasLayout {
    static let padding: CGFloat = 90
    static let minimumSize = CGSize(width: 900, height: 900)

    let nodes: [CanvasNode]
    let edges: [CanvasEdge]
    let shift: CGSize
    let size: CGSize

    init(workflow: WorkflowDefinition, roles: [RoleDefinition], frozenShift: CGSize?) {
        let positions = WorkflowLayout.positions(for: workflow)
        var modelNodes: [(id: String, center: CGPoint, style: NodeStyle, title: String, subtitle: String?, selection: WorkflowSelection)] = []
        if let trigger = positions[WorkflowDefinition.triggerNodeID] {
            let title = workflow.trigger.labels.isEmpty ? "Every new chat" : "Chats labelled \(workflow.trigger.labels.joined(separator: ", "))"
            modelNodes.append((WorkflowDefinition.triggerNodeID, CGPoint(x: trigger.x, y: trigger.y), .trigger(), title, nil, .trigger))
        }
        for step in workflow.steps {
            guard let position = positions[step.id] else { continue }
            let role = step.agent.flatMap { kind in roles.first { $0.id == kind.rawValue } }
            let style = NodeStyle.step(step, role: role)
            let (title, subtitle) = Self.titles(for: step, role: role)
            modelNodes.append((step.id, CGPoint(x: position.x, y: position.y), style, title, subtitle, .step(step.id)))
        }
        if let end = positions[WorkflowDefinition.endStepID] {
            modelNodes.append((WorkflowDefinition.endStepID, CGPoint(x: end.x, y: end.y), .end(workflow.end), workflow.end.action.title, nil, .end))
        }

        let minX = modelNodes.map { $0.center.x - $0.style.size.width / 2 }.min() ?? 0
        let minY = modelNodes.map { $0.center.y - $0.style.size.height / 2 }.min() ?? 0
        let shift = frozenShift ?? CGSize(width: max(0, Self.padding - minX), height: max(0, Self.padding - minY))
        self.shift = shift

        let nodes = modelNodes.map { node in
            let frame = CGRect(
                x: node.center.x + shift.width - node.style.size.width / 2,
                y: node.center.y + shift.height - node.style.size.height / 2,
                width: node.style.size.width,
                height: node.style.size.height
            )
            let label = [node.style.kind, node.title, node.subtitle].compactMap(\.self).joined(separator: ", ")
            return CanvasNode(id: node.id, selection: node.selection, frame: frame, style: node.style, title: node.title, subtitle: node.subtitle, accessibilityLabel: label)
        }
        self.nodes = nodes
        let maxX = nodes.map(\.frame.maxX).max() ?? 0
        let maxY = nodes.map(\.frame.maxY).max() ?? 0
        self.size = CGSize(width: max(Self.minimumSize.width, maxX + Self.padding + 120), height: max(Self.minimumSize.height, maxY + Self.padding))

        let frames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.frame) })
        var lanes: [Bool: Int] = [true: 0, false: 0]
        self.edges = workflow.edges.compactMap { edge in
            guard let from = frames[edge.from], let to = frames[edge.to] else { return nil }
            let others = nodes.filter { $0.id != edge.from && $0.id != edge.to }.map(\.frame)
            let route = Self.route(from: from, to: to, isLoopBack: edge.isLoopBack, isSelf: edge.from == edge.to, others: others, lanes: &lanes)
            return CanvasEdge(
                edge: edge, points: route.points, label: Self.label(for: edge, in: workflow), labelPoint: route.labelPoint,
                labelAlignment: route.labelAlignment, color: Self.color(for: edge)
            )
        }
    }

    private struct Route {
        let points: [CGPoint]
        let labelPoint: CGPoint
        let labelAlignment: Alignment
    }

    private static func route(from: CGRect, to: CGRect, isLoopBack: Bool, isSelf: Bool, others: [CGRect], lanes: inout [Bool: Int]) -> Route {
        if !isSelf {
            if to.minY >= from.maxY + 16 {
                let start = CGPoint(x: from.midX, y: from.maxY)
                let end = CGPoint(x: to.midX, y: to.minY)
                let midY = (start.y + end.y) / 2
                let points = [start, CGPoint(x: start.x, y: midY), CGPoint(x: end.x, y: midY), end]
                if isClear(points, from: from, to: to, others: others) {
                    let labelPoint = abs(start.x - end.x) > 40 ? CGPoint(x: (start.x + end.x) / 2, y: midY) : CGPoint(x: end.x, y: midY)
                    return Route(points: points, labelPoint: labelPoint, labelAlignment: .center)
                }
            }
            let rightward = to.minX >= from.maxX + 16
            if rightward || to.maxX <= from.minX - 16 {
                let lift: CGFloat = isLoopBack ? 14 : 0
                let start = CGPoint(x: rightward ? from.maxX : from.minX, y: from.midY + lift)
                let end = CGPoint(x: rightward ? to.minX : to.maxX, y: to.midY + lift)
                let midX = (start.x + end.x) / 2
                let points = [start, CGPoint(x: midX, y: start.y), CGPoint(x: midX, y: end.y), end]
                if isClear(points, from: from, to: to, others: others) {
                    return Route(points: points, labelPoint: CGPoint(x: midX, y: (start.y + end.y) / 2 + (start.y == end.y ? (isLoopBack ? 14 : -14) : 0)), labelAlignment: .center)
                }
            }
        }
        let preferRight = lanes[true, default: 0] <= lanes[false, default: 0]
        let candidates = [preferRight, !preferRight].map { onRight in
            (onRight, laneRoute(from: from, to: to, onRight: onRight, lane: lanes[onRight, default: 0], isSelf: isSelf))
        }
        let (side, chosen) = candidates.first { isClear($0.1.points, from: from, to: to, others: others) } ?? candidates[0]
        lanes[side, default: 0] += 1
        return chosen
    }

    private static func laneRoute(from: CGRect, to: CGRect, onRight: Bool, lane: Int, isSelf: Bool) -> Route {
        let offset = 36 + CGFloat(lane) * 22
        let x = onRight ? max(from.maxX, to.maxX) + offset : min(from.minX, to.minX) - offset
        let start = CGPoint(x: onRight ? from.maxX : from.minX, y: from.midY - (isSelf ? 12 : 0))
        let end = CGPoint(x: onRight ? to.maxX : to.minX, y: to.midY + (isSelf ? 12 : 0))
        let points = [start, CGPoint(x: x, y: start.y), CGPoint(x: x, y: end.y), end]
        return Route(points: points, labelPoint: CGPoint(x: x + (onRight ? 6 : -6), y: (start.y + end.y) / 2), labelAlignment: onRight ? .leading : .trailing)
    }

    private static func isClear(_ points: [CGPoint], from: CGRect, to: CGRect, others: [CGRect]) -> Bool {
        let segments = Array(zip(points, points.dropFirst()))
        return segments.enumerated().allSatisfy { index, segment in
            let (start, end) = segment
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -1, dy: -1)
            var obstacles = others
            if index > 0 { obstacles.append(from) }
            if index < segments.count - 1 { obstacles.append(to) }
            return !obstacles.contains { $0.insetBy(dx: -4, dy: -4).intersects(rect) }
        }
    }

    func node(at point: CGPoint) -> CanvasNode? {
        nodes.last { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }
    }

    func modelPosition(of point: CGPoint) -> CanvasPosition {
        CanvasPosition(x: Self.snap(point.x - shift.width), y: Self.snap(point.y - shift.height))
    }

    static func snap(_ value: CGFloat) -> Double {
        Double((value / 10).rounded() * 10)
    }

    private static func titles(for step: WorkflowStep, role: RoleDefinition?) -> (String, String?) {
        switch step.type {
        case .agent, .spawn:
            let name = role.map { role in step.model.map { "\(role.name) · \($0.modelTitle)" } ?? role.name }
            return (name ?? "Choose an agent", step.displayTitle)
        case .condition:
            return (step.displayTitle, nil)
        case .approval:
            return ("You", step.displayTitle)
        case .notify:
            return ("Notify", step.message.flatMap { $0.isEmpty ? nil : $0 } ?? step.displayTitle)
        case .gates:
            return ("Gates", step.displayTitle)
        case .check:
            return ("Checks", step.checks.map { $0.joined(separator: ", ") } ?? step.displayTitle)
        }
    }

    private static func label(for edge: WorkflowEdge, in workflow: WorkflowDefinition) -> String? {
        let loops = edge.maxLoops.map { "max \($0) loop\($0 == 1 ? "" : "s")" }
        switch edge.kind {
        case .route:
            return [edge.outcome.map(OutcomeColor.label), loops].compactMap(\.self).joined(separator: " · ")
        case .next:
            let hasRoutes = workflow.step(edge.from).map { !$0.routes.isEmpty } ?? false
            return hasRoutes ? "Otherwise" : nil
        case .start, .implicit:
            return nil
        }
    }

    private static func color(for edge: WorkflowEdge) -> Color {
        if edge.outcome == StepOutcome.failed { return Color(hex: 0xFF6B88) }
        if edge.isLoopBack { return Theme.warning }
        return Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.45)
    }
}
