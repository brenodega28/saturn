import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkflowCanvas: View {
    @Bindable var editor: WorkflowEditor
    let roles: [RoleDefinition]
    @State private var zoom: CGFloat = 1
    @State private var frozenShift: CGSize?
    @State private var isDropTargeted = false

    var body: some View {
        let layout = CanvasLayout(workflow: editor.draft, roles: roles, frozenShift: frozenShift)
        ScrollView([.horizontal, .vertical]) {
            WorkflowCanvasContent(editor: editor, roles: roles, layout: layout, frozenShift: $frozenShift, isDropTargeted: $isDropTargeted)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
        }
        .background(Tokens.code)
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(isDropTargeted ? Theme.accent : Theme.hairline, lineWidth: isDropTargeted ? 2 : 1))
        .overlay(alignment: .bottom) { toolbar.padding(.bottom, 14) }
        .onDeleteCommand { editor.deleteSelectedStep() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow canvas")
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button {
                editor.tidyUp()
            } label: {
                Image(systemName: "wand.and.stars").frame(width: 34, height: 30)
            }
            .help("Tidy up: lay out every step automatically")
            .accessibilityLabel("Tidy up")
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button {
                zoom = max(0.5, zoom - 0.1)
            } label: {
                Image(systemName: "minus").frame(width: 30, height: 30)
            }
            .help("Zoom out")
            .accessibilityLabel("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 44)
                .monospacedDigit()
            Button {
                zoom = min(1.6, zoom + 0.1)
            } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
            }
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.text)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.hair2))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
    }
}

struct WorkflowCanvasContent: View {
    @Bindable var editor: WorkflowEditor
    let roles: [RoleDefinition]
    let layout: CanvasLayout
    @Binding var frozenShift: CGSize?
    @Binding var isDropTargeted: Bool
    @State private var dragStart: (id: String, position: CanvasPosition)?
    @State private var pendingLink: (from: String, point: CGPoint)?

    private static let space = "workflow-canvas"

    var body: some View {
        content(layout)
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
    }

    private func content(_ layout: CanvasLayout) -> some View {
        let report = editor.report
        let transitions = report?.transitions
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { editor.select(.workflow) }
            Canvas { context, size in
                drawGrid(in: &context, size: size)
                for edge in layout.edges {
                    let taken = transitions?.contains(DryRunTransition(from: edge.edge.from, to: edge.edge.to))
                    draw(edge, taken: taken, in: &context)
                }
                if let pendingLink, let from = layout.nodes.first(where: { $0.id == pendingLink.from }) {
                    var path = Path()
                    path.move(to: CGPoint(x: from.frame.midX, y: from.frame.maxY))
                    path.addLine(to: pendingLink.point)
                    context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                }
            }
            .allowsHitTesting(false)
            ForEach(layout.edges) { edge in
                if let label = edge.label, !label.isEmpty {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .overlay(alignment: edge.labelAlignment) {
                            EdgeLabel(text: label, color: edge.edge.isLoopBack ? edge.color : OutcomeColor.color(for: edge.edge.outcome), isLoopBack: edge.edge.isLoopBack)
                        }
                        .position(edge.labelPoint)
                        .opacity(dimmed(edge, transitions) ? 0.35 : 1)
                        .allowsHitTesting(false)
                }
            }
            ForEach(layout.nodes) { node in
                nodeView(node, layout: layout, report: report)
            }
        }
        .dropDestination(for: String.self) { items, location in
            drop(items, at: location, layout: layout)
        } isTargeted: { isDropTargeted = $0 }
    }

    private func dimmed(_ edge: CanvasEdge, _ transitions: Set<DryRunTransition>?) -> Bool {
        guard let transitions else { return false }
        return !transitions.contains(DryRunTransition(from: edge.edge.from, to: edge.edge.to))
    }

    private func nodeView(_ node: CanvasNode, layout: CanvasLayout, report: DryRunReport?) -> some View {
        let isSelected = editor.selection == node.selection
        let visits = report.map { $0.path.contains(node.id) ? max(1, $0.visits(of: node.id)) : 0 }
        let isStep = { if case .step = node.selection { return true } else { return false } }()
        return WorkflowNodeView(node: node, isSelected: isSelected, visits: visits)
            .position(x: node.frame.midX, y: node.frame.midY)
            .onTapGesture { editor.select(node.selection) }
            .gesture(moveGesture(node, layout: layout), including: isStep ? .all : .subviews)
            .overlay {
                if node.id != WorkflowDefinition.endStepID {
                    ConnectHandle()
                        .position(x: node.frame.midX, y: node.frame.maxY + 1)
                        .gesture(linkGesture(from: node.id, layout: layout))
                }
            }
            .accessibilityAction { editor.select(node.selection) }
    }

    private func moveGesture(_ node: CanvasNode, layout: CanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart?.id != node.id {
                    let start = layout.modelPosition(of: CGPoint(x: node.frame.midX, y: node.frame.midY))
                    dragStart = (node.id, start)
                    frozenShift = layout.shift
                    editor.select(node.selection)
                }
                guard let dragStart else { return }
                let position = CanvasPosition(
                    x: CanvasLayout.snap(dragStart.position.x + value.translation.width),
                    y: CanvasLayout.snap(dragStart.position.y + value.translation.height)
                )
                editor.edit { $0.move(node.id, to: position) }
            }
            .onEnded { _ in
                dragStart = nil
                frozenShift = nil
            }
    }

    private func linkGesture(from id: String, layout: CanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if pendingLink == nil { frozenShift = layout.shift }
                pendingLink = (id, value.location)
            }
            .onEnded { value in
                pendingLink = nil
                frozenShift = nil
                guard let target = layout.node(at: value.location), target.id != WorkflowDefinition.triggerNodeID else { return }
                if target.id == id && id == WorkflowDefinition.triggerNodeID { return }
                editor.edit { $0.connect(from: id, to: target.id) }
                editor.select(WorkflowSelection(nodeID: id))
            }
    }

    private func drop(_ items: [String], at location: CGPoint, layout: CanvasLayout) -> Bool {
        guard let item = items.first.flatMap(PaletteItem.init(payload:)) else { return false }
        switch item {
        case .role(let roleID):
            guard let role = roles.first(where: { $0.id == roleID }) else { return false }
            if let target = layout.node(at: location), case .step(let stepID) = target.selection,
               let step = editor.draft.step(stepID), [.agent, .spawn].contains(step.type) {
                editor.assignRole(role, to: stepID)
            } else {
                editor.addStep(.agent, role: role, at: layout.modelPosition(of: location))
            }
        case .type(let type):
            editor.addStep(type, role: nil, at: layout.modelPosition(of: location))
        }
        return true
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
        var y: CGFloat = 10
        while y < size.height {
            var x: CGFloat = 10
            while x < size.width {
                context.fill(dot.offsetBy(dx: x - 1, dy: y - 1), with: .color(.white.opacity(0.08)))
                x += 20
            }
            y += 20
        }
    }

    private func draw(_ edge: CanvasEdge, taken: Bool?, in context: inout GraphicsContext) {
        guard let first = edge.points.first, edge.points.count > 1 else { return }
        var path = Path()
        path.move(to: first)
        for point in edge.points.dropFirst() { path.addLine(to: point) }
        let isTaken = taken == true
        let color: Color = isTaken ? Theme.accent : edge.color.opacity(taken == false ? 0.35 : 1)
        let dash: [CGFloat] = edge.edge.isLoopBack ? [5, 4] : edge.edge.kind == .implicit ? [2, 3] : []
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: isTaken ? 2.6 : 1.6, lineCap: .round, lineJoin: .round, dash: dash))
        let tip = edge.points[edge.points.count - 1]
        let previous = edge.points[edge.points.count - 2]
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - 8 * cos(angle - .pi / 7), y: tip.y - 8 * sin(angle - .pi / 7)))
        arrow.addLine(to: CGPoint(x: tip.x - 8 * cos(angle + .pi / 7), y: tip.y - 8 * sin(angle + .pi / 7)))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }
}

private struct EdgeLabel: View {
    let text: String
    let color: Color
    let isLoopBack: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Tokens.menu, in: Capsule())
            .overlay(Capsule().strokeBorder(isLoopBack ? color.opacity(0.35) : Tokens.hair2))
    }
}

private struct ConnectHandle: View {
    @State private var isHovering = false

    var body: some View {
        Circle()
            .fill(isHovering ? Theme.accent : Tokens.fill2)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            .frame(width: 12, height: 12)
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            .help("Drag to another step to connect")
            .accessibilityHidden(true)
    }
}

struct WorkflowNodeView: View {
    let node: CanvasNode
    let isSelected: Bool
    let visits: Int?

    var body: some View {
        let style = node.style
        HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: style.iconSize * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: style.iconSize, height: style.iconSize)
                .background(style.fill, in: iconShape)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: style.shape == .pill ? 12.5 : 13.5, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                if let tag = style.tag {
                    Text(tag)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, style.shape == .card ? 12 : 7)
        .padding(.trailing, 12)
        .frame(width: style.size.width, height: style.size.height)
        .background(background, in: .rect(cornerRadius: style.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).strokeBorder(ring, lineWidth: isSelected || visits.map({ $0 > 0 }) == true ? 2 : 1.5))
        .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 10 : 9, y: 6)
        .overlay(alignment: .topTrailing) {
            if let visits, visits > 1 {
                Text("×\(visits)")
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Theme.accent, in: Capsule())
                    .offset(x: 6, y: -8)
                    .accessibilityLabel("Visited \(visits) times")
            }
        }
        .opacity(visits == 0 ? 0.45 : 1)
        .contentShape(.rect(cornerRadius: style.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(node.accessibilityLabel)
    }

    private var iconShape: some Shape {
        RoundedRectangle(cornerRadius: style.shape == .pill ? style.iconSize / 2 : style.shape == .gate ? 8 : 10, style: .continuous)
    }

    private var style: NodeStyle { node.style }

    private var background: Color {
        switch style.shape {
        case .gate: Color.adaptive(dark: 0x2B2617, light: 0xFFF6DD)
        case .pill: Tokens.raised
        case .card: Tokens.raised
        }
    }

    private var ring: Color {
        if isSelected { return Theme.accent }
        if let visits, visits > 0 { return Theme.success }
        return style.shape == .gate ? Color(hex: 0xFFC24A, opacity: 0.45) : Tokens.fill2
    }
}
