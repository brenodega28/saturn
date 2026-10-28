import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunGraphCard: View {
    let graph: RunGraph
    let roles: [RoleDefinition]
    let workflowName: String?

    var body: some View {
        let loops = graph.edges.filter(\.isLoopBack)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workflow").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let workflowName {
                    Text(workflowName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .help("The workflow version this run started with")
                }
            }
            ScrollView(.horizontal) {
                RunGraphView(graph: graph, roles: roles)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            if !loops.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(loops) { edge in
                        LoopLegendRow(edge: edge, graph: graph)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

private struct LoopLegendRow: View {
    let edge: RunGraph.Edge
    let graph: RunGraph

    var body: some View {
        let from = graph.node(edge.from)?.title ?? edge.from
        let to = graph.node(edge.to)?.title ?? edge.to
        let limit = edge.maxLoops.map { " of \($0)" } ?? ""
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(edge.timesTaken > 0 ? Theme.warning : Theme.tertiaryText)
                .accessibilityHidden(true)
            Text("\(from) → \(to)\(edge.label.map { " on \($0.lowercased())" } ?? "")")
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(edge.timesTaken > 0 ? "×\(edge.timesTaken)\(limit)" : "not taken")
                .monospacedDigit()
                .foregroundStyle(edge.timesTaken > 0 ? Theme.warning : Theme.tertiaryText)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

struct RunGraphGeometry {
    static let nodeSize = CGSize(width: 164, height: 44)
    static let columnGap: CGFloat = 18
    static let layerGap: CGFloat = 38
    static let margin: CGFloat = 8
    static let laneGap: CGFloat = 12

    let graph: RunGraph
    let centers: [String: CGPoint]
    let lanes: [String: CGFloat]
    let size: CGSize

    init(graph: RunGraph) {
        self.graph = graph
        let columns = max(graph.columnCount, 1)
        let contentWidth = CGFloat(columns) * Self.nodeSize.width + CGFloat(columns - 1) * Self.columnGap
        let layerSizes = Dictionary(grouping: graph.nodes, by: \.layer).mapValues(\.count)
        var centers: [String: CGPoint] = [:]
        for node in graph.nodes {
            let count = CGFloat(layerSizes[node.layer] ?? 1)
            let offset = CGFloat(node.column) - (count - 1) / 2
            centers[node.id] = CGPoint(
                x: Self.margin + contentWidth / 2 + offset * (Self.nodeSize.width + Self.columnGap),
                y: Self.margin + CGFloat(node.layer) * (Self.nodeSize.height + Self.layerGap) + Self.nodeSize.height / 2
            )
        }
        self.centers = centers
        let loopEdges = graph.edges.filter { $0.isLoopBack && $0.from != $0.to }
        let laneStart = Self.margin + contentWidth + 16
        var lanes: [String: CGFloat] = [:]
        for (index, edge) in loopEdges.enumerated() {
            lanes[edge.id] = laneStart + CGFloat(index) * Self.laneGap
        }
        self.lanes = lanes
        let hasSelfLoop = graph.edges.contains { $0.from == $0.to }
        let lanesWidth = loopEdges.isEmpty ? (hasSelfLoop ? 22 : 0) : 16 + CGFloat(loopEdges.count) * Self.laneGap
        self.size = CGSize(
            width: Self.margin * 2 + contentWidth + lanesWidth,
            height: Self.margin * 2 + CGFloat(max(graph.layerCount, 1)) * (Self.nodeSize.height + Self.layerGap) - Self.layerGap
        )
    }

    func points(for edge: RunGraph.Edge) -> [CGPoint] {
        guard let from = centers[edge.from], let to = centers[edge.to] else { return [] }
        let half = CGSize(width: Self.nodeSize.width / 2, height: Self.nodeSize.height / 2)
        if edge.from == edge.to {
            let x = from.x + half.width
            return [CGPoint(x: x, y: from.y - 8), CGPoint(x: x + 14, y: from.y - 8), CGPoint(x: x + 14, y: from.y + 8), CGPoint(x: x, y: from.y + 8)]
        }
        if edge.isLoopBack, let lane = lanes[edge.id] {
            return [
                CGPoint(x: from.x + half.width, y: from.y + 6),
                CGPoint(x: lane, y: from.y + 6),
                CGPoint(x: lane, y: to.y - 6),
                CGPoint(x: to.x + half.width, y: to.y - 6),
            ]
        }
        let start = CGPoint(x: from.x, y: from.y + half.height)
        let end = CGPoint(x: to.x, y: to.y - half.height)
        if abs(start.x - end.x) < 0.5 { return [start, end] }
        let bend = end.y - Self.layerGap / 2
        return [start, CGPoint(x: start.x, y: bend), CGPoint(x: end.x, y: bend), end]
    }
}

struct RunGraphView: View {
    let graph: RunGraph
    let roles: [RoleDefinition]

    var body: some View {
        let geometry = RunGraphGeometry(graph: graph)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in graph.edges.sorted(by: { $0.timesTaken < $1.timesTaken }) {
                    draw(edge, points: geometry.points(for: edge), in: &context)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .accessibilityHidden(true)
            ForEach(graph.nodes) { node in
                if let center = geometry.centers[node.id] {
                    RunGraphNode(node: node, role: node.agent?.builtInRole)
                        .frame(width: RunGraphGeometry.nodeSize.width, height: RunGraphGeometry.nodeSize.height)
                        .position(center)
                }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow graph")
    }

    private func draw(_ edge: RunGraph.Edge, points: [CGPoint], in context: inout GraphicsContext) {
        guard let first = points.first, let last = points.last, points.count > 1 else { return }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        let color = edgeColor(edge)
        let style = StrokeStyle(
            lineWidth: edge.timesTaken > 0 ? 1.8 : 1.2, lineCap: .round, lineJoin: .round,
            dash: edge.isLoopBack ? [5, 4] : []
        )
        context.stroke(path, with: .color(color), style: style)
        let previous = points[points.count - 2]
        let angle = atan2(last.y - previous.y, last.x - previous.x)
        var head = Path()
        head.move(to: last)
        head.addLine(to: CGPoint(x: last.x - 7 * cos(angle - .pi / 7), y: last.y - 7 * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: last.x - 7 * cos(angle + .pi / 7), y: last.y - 7 * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
        if !edge.isLoopBack, let label = edge.label {
            let anchor = points.count == 4 ? CGPoint(x: (points[1].x + points[2].x) / 2, y: points[1].y - 7) : CGPoint(x: first.x + 6, y: (first.y + last.y) / 2)
            let text = Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(edge.timesTaken > 0 ? Theme.secondaryText : Theme.tertiaryText)
            context.draw(text, at: anchor, anchor: points.count == 4 ? .center : .leading)
        }
    }

    private func edgeColor(_ edge: RunGraph.Edge) -> Color {
        if edge.isLoopBack { return edge.timesTaken > 0 ? Theme.warning : Theme.warning.opacity(0.35) }
        return edge.timesTaken > 0 ? Theme.success.opacity(0.85) : Color.white.opacity(0.22)
    }
}

private struct RunGraphNode: View {
    let node: RunGraph.Node
    let role: RoleDefinition?
    @State private var isPulsing = false

    var body: some View {
        let color = node.state.color
        HStack(spacing: 8) {
            StepGlyph(type: node.type, role: role, size: 24)
            Text(node.title)
                .font(.system(size: 12, weight: node.state.isLive ? .semibold : .medium))
                .foregroundStyle(node.state == .upcoming ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if node.visits > 1 {
                Text("×\(node.visits)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Theme.warning.opacity(0.15), in: Capsule())
            } else if node.state == .visited {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.successText)
            }
        }
        .padding(.horizontal, 8)
        .background(Color(hex: 0x232328), in: .rect(cornerRadius: node.isEnd ? 22 : 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: node.isEnd ? 22 : 11, style: .continuous)
                .strokeBorder(node.state == .upcoming ? Theme.hairline : color.opacity(node.state.isLive ? 1 : 0.45), lineWidth: node.state.isLive ? 1.6 : 1)
        }
        .shadow(color: node.state.isLive ? color.opacity(isPulsing ? 0.7 : 0.15) : .clear, radius: isPulsing ? 9 : 3)
        .opacity(node.state == .upcoming ? 0.72 : 1)
        .onAppear { startPulse() }
        .onChange(of: node.state) { startPulse() }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        let visits = node.visits == 0 ? "not visited" : (node.visits == 1 ? "visited once" : "visited \(node.visits) times")
        return "\(node.title), \(node.state.label), \(visits)"
    }

    private func startPulse() {
        guard node.state == .running else {
            isPulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isPulsing = true }
    }
}
