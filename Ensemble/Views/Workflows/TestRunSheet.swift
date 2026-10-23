import EnsembleCore
import EnsembleUI
import SwiftUI

struct TestRunSheet: View {
    @Bindable var editor: WorkflowEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Test run").font(.system(size: 20, weight: .bold))
                Text("Runs “\(editor.draft.name)” through the real workflow engine in memory with every agent stubbed. Nothing is spawned, nothing is written and nothing is spent. Plans are approved automatically.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sampleTask
            outcomes
            HStack {
                Button("Reset to happy path") { editor.script = .happyPath(for: editor.draft) }
                    .buttonStyle(.pill)
                    .help("Every agent answers with the outcome that moves the work forward")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await editor.runTest()
                        dismiss()
                    }
                } label: {
                    Label("Run test", systemImage: "play.fill")
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut(.defaultAction)
                .disabled(editor.draft.steps.isEmpty || editor.isTestRunning)
                .help(editor.draft.steps.isEmpty ? "Add a step first" : "Run the workflow with stubbed agents")
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 480)
    }

    private var sampleTask: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowLabel("Sample task")
            TextField("Task title", text: $editor.script.taskTitle).textFieldStyle(.roundedBorder)
            InspectorField("Labels") {
                TokenEditor(items: $editor.script.labels, placeholder: "Add a label", suggestions: editor.draft.trigger.labels)
            }
            HStack(alignment: .top, spacing: 16) {
                InspectorField("Diff lines") {
                    TextField("Lines", value: $editor.script.diff.lines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                        .help("How many lines the stubbed agents changed, for conditions")
                }
                InspectorField("Changed paths") {
                    TokenEditor(items: $editor.script.diff.paths, placeholder: "e.g. src/payments/refund.py", suggestions: [])
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private var outcomes: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkflowLabel("What each step answers the first time")
            Text("Later visits follow the happy path, so a loop back runs once.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(editor.draft.steps) { step in
                        GridRow {
                            Text(step.displayTitle).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(NodeStyle.step(step, role: nil).kind)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                            outcomeControl(for: step)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    @ViewBuilder
    private func outcomeControl(for step: WorkflowStep) -> some View {
        let options = DryRunScript.options(for: step)
        if step.type == .condition {
            Text("Decided by its rule").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        } else if options.count <= 1 {
            Text(OutcomeColor.label(options.first ?? StepOutcome.done))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OutcomeColor.color(for: options.first))
        } else {
            let happy = DryRunScript.happyOutcome(for: step)
            Picker("Outcome for \(step.displayTitle)", selection: Binding(
                get: { editor.script.outcomes[step.id]?.first ?? happy },
                set: { outcome in editor.script.outcomes[step.id] = outcome == happy ? nil : [outcome] }
            )) {
                ForEach(options, id: \.self) { option in
                    Text(OutcomeColor.label(option) + (option == happy ? " (happy path)" : "")).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("What the stubbed agent answers on its first visit")
        }
    }
}
