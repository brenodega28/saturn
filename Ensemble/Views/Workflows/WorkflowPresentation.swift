import EnsembleCore
import EnsembleUI
import SwiftUI

enum NodeShape {
    case card
    case gate
    case pill
}

struct NodeStyle {
    let shape: NodeShape
    let size: CGSize
    let symbol: String
    let fill: AnyShapeStyle
    let kind: String
    let tag: String?

    static func trigger() -> NodeStyle {
        NodeStyle(shape: .pill, size: CGSize(width: 220, height: 38), symbol: "bubble.left.fill", fill: AnyShapeStyle(Color.white.opacity(0.14)), kind: "Trigger", tag: nil)
    }

    static func end(_ end: WorkflowEnd) -> NodeStyle {
        NodeStyle(shape: .pill, size: CGSize(width: 190, height: 40), symbol: end.action.symbol, fill: AnyShapeStyle(Color.white.opacity(0.14)), kind: "End", tag: nil)
    }

    static func step(_ step: WorkflowStep, role: RoleDefinition?) -> NodeStyle {
        switch step.type {
        case .agent:
            let appearance = RoleAppearance(role: role)
            return NodeStyle(shape: .card, size: CGSize(width: 200, height: 64), symbol: appearance.symbol, fill: AnyShapeStyle(appearance.palette.gradient), kind: "Agent step", tag: nil)
        case .spawn:
            let appearance = RoleAppearance(role: role)
            let limit = step.maxAgents.map { "parallel · up to \($0)" } ?? "parallel"
            return NodeStyle(shape: .card, size: CGSize(width: 200, height: 78), symbol: appearance.symbol, fill: AnyShapeStyle(appearance.palette.gradient), kind: "Parallel build", tag: limit)
        case .condition:
            return NodeStyle(shape: .gate, size: CGSize(width: 170, height: 54), symbol: "diamond", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFC24A), Color(hex: 0xC98400)], startPoint: .top, endPoint: .bottom)), kind: "Condition", tag: nil)
        case .approval:
            return NodeStyle(shape: .card, size: CGSize(width: 200, height: 64), symbol: "person.fill", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x9AA0AA), Color(hex: 0x5A606A)], startPoint: .top, endPoint: .bottom)), kind: "Human approval", tag: nil)
        case .notify:
            return NodeStyle(shape: .card, size: CGSize(width: 200, height: 58), symbol: "bell.fill", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF708C), Color(hex: 0xCF2149)], startPoint: .top, endPoint: .bottom)), kind: "Notify", tag: nil)
        case .check:
            let tag = [step.maxRounds.map { "up to \($0) rounds" }, step.testFirst ? "test first" : nil].compactMap(\.self).joined(separator: " · ")
            return NodeStyle(shape: .card, size: CGSize(width: 200, height: tag.isEmpty ? 58 : 72), symbol: "checkmark.shield.fill", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4BD97B), Color(hex: 0x1E8F55)], startPoint: .top, endPoint: .bottom)), kind: "Checks", tag: tag.isEmpty ? nil : tag)
        }
    }

    var cornerRadius: CGFloat {
        switch shape {
        case .card: 16
        case .gate, .pill: size.height / 2
        }
    }

    var iconSize: CGFloat {
        switch shape {
        case .card: 34
        case .gate: 26
        case .pill: 26
        }
    }
}

extension StepType {
    var paletteTitle: String {
        switch self {
        case .agent: "Agent"
        case .spawn: "Parallel build"
        case .condition: "Condition"
        case .approval: "Human approval"
        case .notify: "Notify"
        case .check: "Checks"
        }
    }

    var paletteSymbol: String {
        switch self {
        case .agent: "person.crop.square"
        case .spawn: "arrow.triangle.branch"
        case .condition: "diamond"
        case .approval: "checkmark"
        case .notify: "bell"
        case .check: "checkmark.shield"
        }
    }

    var paletteColor: Color {
        switch self {
        case .agent: Theme.secondaryText
        case .spawn: Color(hex: 0x7DB6FF)
        case .condition: Color(hex: 0xFFC24A)
        case .approval: Theme.successText
        case .notify: Color(hex: 0xFF8AA2)
        case .check: Color(hex: 0x4BD97B)
        }
    }

    var paletteHelp: String {
        switch self {
        case .agent: "One agent works on the task"
        case .spawn: "Agents build the plan’s tasks in parallel, each in its own worktree"
        case .condition: "Route on labels, changed paths, diff size or an earlier outcome"
        case .approval: "Pause until you approve or send the work back"
        case .notify: "Post a message to your Inbox and continue"
        case .check: "Ensemble runs the project’s checks on every branch and sends failures back to their authors"
        }
    }
}

extension EndAction {
    var title: String {
        switch self {
        case .pullRequest: "Prepare a pull request"
        case .merge: "Merge to the base branch"
        case .push: "Push the branch"
        case .leave: "Leave the branches"
        }
    }

    var symbol: String {
        switch self {
        case .pullRequest: "arrow.triangle.pull"
        case .merge: "arrow.triangle.merge"
        case .push: "arrow.up.circle"
        case .leave: "pause.circle"
        }
    }
}

extension FailureAction {
    var title: String {
        switch self {
        case .retry: "Retry once, then ask me"
        case .ask: "Ask me"
        case .fail: "Fail the run"
        }
    }
}

extension TaskSource {
    var title: String {
        switch self {
        case .chat: "Lead chat"
        case .github: "GitHub Issues"
        }
    }
}

enum OutcomeColor {
    static func color(for outcome: String?) -> Color {
        switch outcome {
        case StepOutcome.approved, StepOutcome.passed, StepOutcome.yes, StepOutcome.done: Theme.successText
        case StepOutcome.changesRequested, StepOutcome.no: Color(hex: 0xFFB340)
        case StepOutcome.failed, "rejected": Color(hex: 0xFF8AA2)
        case nil: Theme.secondaryText
        default: Color(hex: 0x7DB6FF)
        }
    }

    static func label(_ outcome: String) -> String {
        outcome.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

extension WorkflowTrigger {
    var summary: String {
        let sources = sources.map(\.title).joined(separator: " or ")
        let origin = sources.isEmpty ? "No source" : sources
        return labels.isEmpty ? "\(origin) · every new task" : "\(origin) · labelled \(labels.joined(separator: ", "))"
    }
}

enum PaletteItem {
    static let rolePrefix = "ensemble-role:"
    static let typePrefix = "ensemble-step:"

    case role(String)
    case type(StepType)

    init?(payload: String) {
        if payload.hasPrefix(Self.rolePrefix) {
            self = .role(String(payload.dropFirst(Self.rolePrefix.count)))
        } else if payload.hasPrefix(Self.typePrefix), let type = StepType(rawValue: String(payload.dropFirst(Self.typePrefix.count))) {
            self = .type(type)
        } else {
            return nil
        }
    }

    var payload: String {
        switch self {
        case .role(let id): Self.rolePrefix + id
        case .type(let type): Self.typePrefix + type.rawValue
        }
    }
}

struct WorkflowLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
    }
}
