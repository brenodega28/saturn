import EnsembleCore
import EnsembleUI
import SwiftUI

struct TaskCardView: View {
    @Environment(AppModel.self) private var model
    let card: TaskCard
    let column: TaskColumn
    let project: Project
    @State private var chosenWorkflowID: String?

    private var task: ProjectTask { card.task }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(task.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            TaskSourceBadge(task: task)
            if !visibleLabels.isEmpty {
                TaskLabels(labels: visibleLabels)
            }
            if column == .incoming {
                incomingControls
            } else {
                startedDetails
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x232328), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
        .accessibilityElement(children: .contain)
    }

    private var visibleLabels: [String] {
        task.labels.filter { !$0.hasPrefix("ensemble:") }
    }

    private var selectedWorkflowID: String? {
        chosenWorkflowID ?? model.defaultWorkflowID(for: task, in: project)
    }

    @ViewBuilder
    private var incomingControls: some View {
        let workflows = model.workflows(for: project)
        let selected = workflows.first { $0.id == selectedWorkflowID }
        Menu {
            ForEach(workflows, id: \.id) { workflow in
                Button {
                    chosenWorkflowID = workflow.id
                } label: {
                    if workflow.id == selected?.id {
                        Label(workflow.displayName, systemImage: "checkmark")
                    } else {
                        Text(workflow.displayName)
                    }
                }
            }
        } label: {
            Label(selected?.displayName ?? "No workflows", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(workflows.isEmpty)
        .accessibilityLabel("Workflow: \(selected?.displayName ?? "none"). Choose a workflow")
        .help("The workflow this task runs when you accept it")

        HStack(spacing: 6) {
            Button("Accept") {
                if let id = selected?.id { model.acceptTask(task, workflowID: id, in: project) }
            }
            .buttonStyle(PillButtonStyle(.primary, height: 28))
            .frame(maxWidth: .infinity)
            .disabled(selected == nil)
            .help("Start \(selected?.displayName ?? "a workflow") for this task")
            Button("Dismiss") { model.dismissTask(task) }
                .buttonStyle(PillButtonStyle(height: 28))
                .frame(maxWidth: .infinity)
                .help("Hide this task. It won’t be imported again.")
        }
    }

    @ViewBuilder
    private var startedDetails: some View {
        if let run = card.run {
            Text(workflowName(for: run))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                StepChip(text: stepText(for: run), column: column)
                Spacer(minLength: 4)
                Text(run.costUSD.formatted(.currency(code: "USD")))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Cost \(run.costUSD.formatted(.currency(code: "USD")))")
            }
            action(for: run)
        } else if let workflow = task.workflow {
            Text(workflow).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private func action(for run: Run) -> some View {
        switch column {
        case .waitingOnYou:
            Button(waitingActionTitle(for: run)) {
                model.openLead(forRun: run.id, in: run.projectId)
            }
            .buttonStyle(WarningPillStyle())
            .help("Open the Lead tab for this run")
        case .failed:
            Button("Retry step") { model.retryFailedRun(run) }
                .buttonStyle(PillButtonStyle(height: 28))
                .frame(maxWidth: .infinity)
                .help("Run the failed step again")
        case .done:
            if let url = run.pullRequestURL.flatMap(URL.init(string:)) {
                Link("Open pull request", destination: url)
                    .font(.system(size: 12))
                    .help(url.absoluteString)
            }
        case .incoming, .running:
            EmptyView()
        }
    }

    private func workflowName(for run: Run) -> String {
        run.workflowDefinition?.displayName ?? run.workflow
    }

    private func waitingActionTitle(for run: Run) -> String {
        guard let id = run.id, let hold = model.engine.waitingReason(runID: id) else { return "Open" }
        return hold.reason == .planApproval ? "Review plan" : "Open in Lead"
    }

    private func stepText(for run: Run) -> String {
        switch column {
        case .running:
            return stepTitle(run) ?? "Starting"
        case .waitingOnYou:
            if run.status == .paused { return "Paused" }
            guard let id = run.id, let hold = model.engine.waitingReason(runID: id) else { return "Waiting" }
            return Self.holdTitle(hold.reason)
        case .done:
            return run.pullRequestURL == nil ? "Done" : "PR opened"
        case .failed:
            return run.lastError ?? "Failed"
        case .incoming:
            return ""
        }
    }

    private func stepTitle(_ run: Run) -> String? {
        guard let stepID = run.currentStep else { return nil }
        return run.workflowDefinition?.step(stepID)?.displayTitle ?? stepID
    }

    static func holdTitle(_ reason: HoldReason) -> String {
        switch reason {
        case .planApproval: "Plan approval"
        case .approval: "Approval"
        case .loopLimit: "Loop limit"
        case .stepBudget, .runBudget: "Budget"
        case .stepFailed: "Step failed"
        case .timedOut: "Timed out"
        }
    }
}

private struct StepChip: View {
    let text: String
    let column: TaskColumn

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: .rect(cornerRadius: 6, style: .continuous))
            .help(text)
    }

    private var foreground: Color {
        switch column {
        case .running: Theme.successText
        case .waitingOnYou: Color(hex: 0xFFB340)
        case .failed: Color(hex: 0xFF7A70)
        case .done, .incoming: Theme.secondaryText
        }
    }

    private var background: Color {
        switch column {
        case .running: Theme.success.opacity(0.14)
        case .waitingOnYou: Theme.warning.opacity(0.16)
        case .failed: Theme.danger.opacity(0.16)
        case .done, .incoming: Color.white.opacity(0.08)
        }
    }
}

private struct WarningPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(hex: 0x1A1205))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Theme.warning, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct TaskSourceBadge: View {
    let task: ProjectTask

    var body: some View {
        HStack(spacing: 6) {
            switch task.source {
            case .github:
                Image(systemName: "smallcircle.filled.circle").accessibilityHidden(true)
                if let url = task.sourceURL.flatMap(URL.init(string:)) {
                    Link(title, destination: url)
                        .help("Open \(title) on GitHub")
                } else {
                    Text(title)
                }
            case .chat:
                Image(systemName: "bubble.left").accessibilityHidden(true)
                Text(title)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.secondaryText)
    }

    private var title: String {
        switch task.source {
        case .github: task.externalNumber.map { "GitHub #\($0)" } ?? "GitHub"
        case .chat: "Lead chat"
        }
    }
}

private struct TaskLabels: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(4), id: \.self) { label in
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Theme.fillRaised, in: Capsule())
            }
            if labels.count > 4 {
                Text("+\(labels.count - 4)").font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
            }
        }
        .foregroundStyle(Theme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: \(labels.joined(separator: ", "))")
    }
}
