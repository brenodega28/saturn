import SaturnCore
import SaturnUI
import SwiftUI

enum StepsLayout: String, CaseIterable, Identifiable {
    case list
    case canvas

    var id: Self { self }

    var title: String {
        switch self {
        case .list: "Steps"
        case .canvas: "Canvas"
        }
    }
}

extension ProjectConfig {
    var defaultWorkflowDefinition: WorkflowDefinition? {
        workflow(preferences.defaultWorkflow ?? "") ?? workflows.first
    }
}

struct StepTag: Hashable {
    enum Tone {
        case need
        case build
        case review
        case done
        case idle
    }

    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .need: Tokens.need
        case .build: Tokens.build
        case .review: Tokens.review
        case .done: Tokens.done
        case .idle: Tokens.idle
        }
    }

    var background: Color {
        switch tone {
        case .need: Tokens.needBackground
        case .build: Tokens.buildBackground
        case .review: Tokens.reviewBackground
        case .done: Tokens.doneBackground
        case .idle: Tokens.fill
        }
    }

    static func tags(for step: WorkflowStep) -> [StepTag] {
        switch step.type {
        case .approval:
            return [StepTag(text: "You approve", tone: .need)]
        case .spawn:
            return [StepTag(text: step.maxAgents.map { "Up to \($0)" } ?? "Parallel", tone: .build)]
        case .check:
            return [step.maxRounds.map { StepTag(text: "\($0) round\($0 == 1 ? "" : "s")", tone: .build) },
                    step.testFirst ? StepTag(text: "Test first", tone: .build) : nil].compactMap(\.self)
        case .condition:
            return [StepTag(text: "Condition", tone: .review)]
        case .gates:
            return [StepTag(text: "Gates", tone: .review)]
        case .notify:
            return [StepTag(text: "Notify", tone: .idle)]
        case .agent:
            return step.agent == .checker ? [StepTag(text: "Read-only", tone: .idle)] : []
        }
    }

    static func tags(for end: WorkflowEnd) -> [StepTag] {
        switch end.action {
        case .merge: [StepTag(text: "Local", tone: .done)]
        case .push: [StepTag(text: "Push", tone: .done)]
        case .leave: []
        }
    }
}

struct WorkflowStepList: View {
    @Bindable var editor: WorkflowEditor
    let roles: [RoleDefinition]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(editor.draft.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { connector }
                    card(number: index + 1, title: step.displayTitle, detail: detail(of: step), tags: StepTag.tags(for: step), selection: .step(step.id))
                }
                if !editor.draft.steps.isEmpty { connector }
                card(number: editor.draft.steps.count + 1, title: "End", detail: editor.draft.end.action.title, tags: StepTag.tags(for: editor.draft.end), selection: .end)
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .accessibilityLabel("Steps")
    }

    private var connector: some View {
        Rectangle()
            .fill(Tokens.hair2)
            .frame(width: 2, height: 14)
            .padding(.leading, 31)
            .accessibilityHidden(true)
    }

    private func card(number: Int, title: String, detail: String, tags: [StepTag], selection: WorkflowSelection) -> some View {
        let isSelected = editor.selection == selection
        return Button {
            editor.select(selection)
        } label: {
            HStack(spacing: 14) {
                Text("\(number)")
                    .font(Tokens.mono(12))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 34, height: 34)
                    .background(Tokens.fill, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(tags, id: \.self) { tag in
                    TagPill(text: tag.text, color: tag.color, background: tag.background)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .raisedCard(cornerRadius: 12, isSelected: isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(number), \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detail(of step: WorkflowStep) -> String {
        let instructions = step.instructions.split(whereSeparator: \.isNewline).first.map(String.init)
        switch step.type {
        case .agent, .spawn:
            let role = step.agent.flatMap { kind in roles.first { $0.id == kind.rawValue } }?.name ?? step.agent?.name ?? "Choose an agent"
            let who = step.model.map { "\(role) · \($0.modelTitle)" } ?? role
            return [who, instructions].compactMap(\.self).joined(separator: " — ")
        case .approval:
            return nonEmpty(step.message) ?? instructions ?? "Waits for you to approve or send it back"
        case .notify:
            return nonEmpty(step.message) ?? "Posts a message in the chat"
        case .check:
            return nonEmpty(step.checks?.joined(separator: ", ")) ?? "Every project check"
        case .condition:
            return "Routes on labels, paths, diff size or an outcome"
        case .gates:
            return "Secrets, dependencies, size, duplication, complexity"
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}
