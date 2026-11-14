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
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body, isStuck: true) {
                DecisionButtons(
                    primary: ("Allow another round", "Allow one more loop back, then ask again"),
                    secondary: ("Stop here", "Stop the run here"),
                    failureTitle: "Couldn’t resolve the loop limit",
                    reload: reload
                ) { engine, continueOnce in try engine.resolveLoopLimit(run, continueOnce: continueOnce) }
            }
        case .runBudget:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body, isStuck: true) {
                RaiseBudgetControls(run: run, reload: reload)
            }
        case .stepBudget:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                DecisionButtons(
                    primary: ("Keep going", "Keep the step’s result and carry on"),
                    secondary: ("Stop here", "Fail the run here"),
                    failureTitle: "Couldn’t resolve the budget",
                    reload: reload
                ) { engine, proceed in try engine.resolveBudget(run, proceed: proceed) }
            }
        case .gates:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body) {
                DecisionButtons(
                    primary: ("Allow and continue", "Accept these findings, including any new dependencies, and carry on"),
                    secondary: ("Ask for an alternative", "Send the findings back to the authors to fix"),
                    failureTitle: "Couldn’t resolve the gate findings",
                    reload: reload
                ) { engine, proceed in try engine.resolveGates(run, proceed: proceed) }
            }
        case .stepFailed where hold.isChecksExhausted(in: run.snapshotWorkflow):
            ChecksExhaustedCard(run: run, project: project, rounds: run.checkRounds(at: hold.stepId, in: project), reload: reload)
        case .stepFailed, .timedOut:
            DecisionCard(title: hold.message, detail: timeline.holdItem?.body, isStuck: true) {
                DecisionButtons(
                    primary: ("Retry", "Run the step again"),
                    secondary: ("Stop here", "Stop the run here"),
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
    var isStuck = false
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty, detail != title {
                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isStuck ? Tokens.stuckBackground : Tokens.needBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isStuck ? Tokens.stuckLine : Tokens.needLine))
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
                .buttonStyle(PrimaryPillStyle())
                .help(primary.help)
            Button(secondary.title) { decide(false) }
                .buttonStyle(SecondaryPillStyle())
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
                    Button("Approve & merge into \(run.baseBranch ?? "main")") { resolve(approved: true) }
                        .buttonStyle(PrimaryPillStyle())
                        .help("Approve the work; the run then merges it on this Mac")
                    Button("Request changes") { isRequestingChanges = true }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Send the work back with a note")
                    Button("Open in Changes →") { model.openChanges(for: run) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.link)
                        .font(.system(size: 13.5))
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
