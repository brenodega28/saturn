import EnsembleCore
import EnsembleUI
import SwiftUI

struct HoldCard: View {
    let run: Run
    let project: Project
    let hold: RunHold
    let timeline: RunTimeline
    let reload: () -> Void

    var body: some View {
        switch hold.reason {
        case .planApproval:
            if let plan = timeline.pendingPlan {
                PlanCard(run: run, project: project, plan: plan, reload: reload)
                    .id(hold.runStepId)
            } else {
                DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                    Text("The plan couldn’t be read. Ask for a new one.").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                }
            }
        case .approval:
            ApprovalCard(run: run, title: hold.message, detail: timeline.holdItem?.body, reload: reload)
        case .loopLimit:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                DecisionButtons(
                    primary: ("Continue Once More", "Allow one more loop back, then ask again"),
                    secondary: ("Fail Run", "Stop the run here"),
                    failureTitle: "Couldn’t resolve the loop limit",
                    reload: reload
                ) { engine, continueOnce in try engine.resolveLoopLimit(run, continueOnce: continueOnce) }
            }
        case .runBudget:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                RaiseBudgetControls(run: run, reload: reload)
            }
        case .stepBudget:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                DecisionButtons(
                    primary: ("Continue", "Keep the step’s result and carry on"),
                    secondary: ("Stop", "Fail the run here"),
                    failureTitle: "Couldn’t resolve the budget",
                    reload: reload
                ) { engine, proceed in try engine.resolveBudget(run, proceed: proceed) }
            }
        case .stepFailed, .timedOut:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                DecisionButtons(
                    primary: ("Retry", "Run the step again"),
                    secondary: ("Fail Run", "Stop the run here"),
                    failureTitle: "Couldn’t resolve the failure",
                    reload: reload
                ) { engine, retry in try engine.resolveFailure(run, retry: retry) }
            }
        }
    }
}

struct DecisionCard<Actions: View>: View {
    let title: String
    let detail: String?
    var tint: Color = Theme.warning
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty, detail != title {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.24)))
    }
}

private struct DecisionButtons: View {
    @Environment(AppModel.self) private var model
    let primary: (title: String, help: String)
    let secondary: (title: String, help: String)
    let failureTitle: String
    let reload: () -> Void
    let resolve: (RunEngine, Bool) throws -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(primary.title) { decide(true) }
                .buttonStyle(PillButtonStyle(.primary, height: 30))
                .help(primary.help)
            Button(secondary.title) { decide(false) }
                .buttonStyle(PillButtonStyle(height: 30))
                .help(secondary.help)
        }
    }

    private func decide(_ choice: Bool) {
        model.performRunAction(failureTitle) { try resolve(model.engine, choice) }
        reload()
    }
}

private struct RaiseBudgetControls: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let reload: () -> Void
    @State private var budget: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text("New budget").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            TextField("Budget", value: $budget, format: .currency(code: "USD"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .accessibilityLabel("New run budget in dollars")
            Button("Raise Budget") {
                model.performRunAction("Couldn’t raise the budget") {
                    try model.engine.resolveBudget(run, proceed: true, raiseRunBudgetTo: budget)
                }
                reload()
            }
            .buttonStyle(PillButtonStyle(.primary, height: 30))
            .disabled((budget ?? 0) <= run.costUSD)
            .help("Raise the run’s budget and continue")
            Button("Stop") {
                model.performRunAction("Couldn’t stop the run") { try model.engine.resolveBudget(run, proceed: false) }
                reload()
            }
            .buttonStyle(PillButtonStyle(height: 30))
            .help("Fail the run here")
        }
        .onAppear {
            if budget == nil { budget = ((max(run.budgetUSD ?? 0, run.costUSD) * 1.5) * 100).rounded() / 100 }
        }
    }
}

private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let title: String
    let detail: String?
    let reload: () -> Void
    @State private var isRequestingChanges = false
    @State private var note = ""

    var body: some View {
        DecisionCard(title: title, detail: detail) {
            if isRequestingChanges {
                NoteField(prompt: "What should change?", note: $note, sendTitle: "Request Changes", cancel: { isRequestingChanges = false }) {
                    resolve(approved: false)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Approve") { resolve(approved: true) }
                        .buttonStyle(PillButtonStyle(.primary, height: 30))
                        .help("Approve and move to the next step")
                    Button("Request Changes") { isRequestingChanges = true }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .help("Send the work back with a note")
                    Button("Review Changes") { model.openChanges(for: run) }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .help("Open the run’s diffs in Changes")
                }
            }
        }
    }

    private func resolve(approved: Bool) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.performRunAction("Couldn’t resolve the approval") {
            try model.engine.resolveApproval(run, approved: approved, note: trimmed.isEmpty ? nil : trimmed)
        }
        reload()
    }
}

struct NoteField: View {
    let prompt: String
    @Binding var note: String
    let sendTitle: String
    let cancel: () -> Void
    let send: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(prompt, text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .focused($isFocused)
                .padding(10)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(prompt)
                .onAppear { isFocused = true }
            HStack(spacing: 8) {
                Button(sendTitle, action: send)
                    .buttonStyle(PillButtonStyle(.primary, height: 30))
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", action: cancel)
                    .buttonStyle(PillButtonStyle(height: 30))
            }
        }
    }
}
