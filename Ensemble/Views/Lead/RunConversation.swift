import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunConversation: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let project: Project
    @State private var timeline: RunTimeline?
    @State private var request: ProjectTask?

    var body: some View {
        let lead = model.leadRole(for: run, in: project)
        let workflow = model.runWorkflow(run)
        let hold = run.id.flatMap { model.engine.holds[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RequestBubble(
                    text: request?.body ?? run.title,
                    caption: [lead?.name, workflow?.displayName].compactMap(\.self).joined(separator: " · ")
                )
                LeadMessage(role: lead, date: run.startedAt) {
                    Text(statusSentence(hold: hold))
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                    RunCard(run: run, workflow: workflow, timeline: timeline, agentCount: agentCount)
                    if let timeline {
                        ForEach(timeline.questions) { item in
                            QuestionCard(item: item, project: project, reload: reload)
                        }
                        if let hold {
                            HoldCard(run: run, project: project, hold: hold, timeline: timeline, reload: reload)
                        }
                        if !run.isActive {
                            FinalStateCard(run: run, reload: reload)
                        }
                        if !timeline.entries.isEmpty {
                            StepHistory(entries: timeline.entries)
                        }
                    }
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .task(id: run.id) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: run) { reload() }
        .onChange(of: hold) { reload() }
    }

    private var agentCount: Int {
        model.agentSessions(in: project).filter { $0.agent.runId == run.id }.count
    }

    private func reload() {
        let latest = run.id.flatMap { model.engine.runs[$0] ?? (try? model.database.run(id: $0)) ?? nil } ?? run
        timeline = model.timeline(for: latest)
        if request == nil { request = model.requestTask(for: run) }
    }

    private func statusSentence(hold: RunHold?) -> String {
        let step = model.currentStepTitle(of: run) ?? "the next step"
        if let hold {
            switch hold.reason {
            case .planApproval: return "Here’s the plan. Reorder, change roles or counts, or drop tasks before I start."
            case .approval: return "It’s ready for your approval at “\(step)”."
            case .loopLimit: return "The work keeps going back and forth. Tell me whether to try once more."
            case .stepBudget, .runBudget: return "We hit a budget limit. Decide whether to spend more."
            case .stepFailed, .timedOut: return "“\(step)” didn’t finish. Retry it, or stop the run."
            }
        }
        switch run.status {
        case .pending, .running: return "The run is going: \(step)."
        case .waitingOnYou: return "The run is waiting for you at “\(step)”."
        case .paused: return "The run is paused at “\(step)”."
        case .interrupted: return "The run was interrupted at “\(step)”. Resume it to continue."
        case .succeeded: return "Done. The run finished."
        case .failed: return "The run failed at “\(step)”."
        case .cancelled: return "The run was cancelled."
        }
    }
}

private struct RequestBubble: View {
    let text: String
    let caption: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.accent.opacity(0.85), in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
            if !caption.isEmpty {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: 640, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your request: \(text)")
    }
}

private struct LeadMessage<Content: View>: View {
    let role: RoleDefinition?
    let date: Date
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoleBadge(role: role, size: 30)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Text(role?.name ?? "Workflow").fontWeight(.semibold).foregroundStyle(.white)
                    Text("· \(date.formatted(.relative(presentation: .named)))").foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 12))
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RunCard: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let workflow: WorkflowDefinition?
    let timeline: RunTimeline?
    let agentCount: Int

    var body: some View {
        let step = run.isActive ? model.currentStepTitle(of: run) : nil
        let meta = [
            workflow?.displayName, step, agentCount > 0 ? "\(agentCount) agent\(agentCount == 1 ? "" : "s")" : nil,
            run.budgetUSD.map { "\(run.costUSD.formatted(.currency(code: "USD"))) of \($0.formatted(.currency(code: "USD")))" }
                ?? run.costUSD.formatted(.currency(code: "USD")),
            run.elapsedDescription,
        ].compactMap(\.self)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusDot(run.status.color, size: 8)
                Text(run.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(run.status.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(run.status.color)
            }
            if let stages = timeline?.stages, !stages.isEmpty {
                HStack(spacing: 4) {
                    ForEach(stages) { stage in
                        Capsule()
                            .fill(stage.state.color)
                            .frame(height: 5)
                            .help("\(stage.title) — \(stage.state.label)")
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Progress: " + stages.map { "\($0.title) \($0.state.label)" }.joined(separator: ", "))
            }
            if run.isActive {
                RunControls(run: run)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .card(cornerRadius: 16)
    }
}

private struct RunControls: View {
    @Environment(AppModel.self) private var model
    let run: Run
    @State private var isConfirmingCancel = false

    var body: some View {
        let hold = run.id.flatMap { model.engine.holds[$0] }
        let canRetry = hold.map { [.stepFailed, .timedOut].contains($0.reason) } == true
        HStack(spacing: 8) {
            if run.status == .running || run.status == .pending {
                Button {
                    Task { await model.performRunAction("Couldn’t pause the run") { try await model.engine.pause(run) } }
                } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Stop after interrupting the current step; resume later")
            } else if [.paused, .interrupted].contains(run.status) {
                Button {
                    model.performRunAction("Couldn’t resume the run") { try model.engine.resume(run) }
                } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Continue the run from where it stopped")
            }
            if canRetry {
                Button {
                    model.performRunAction("Couldn’t retry the step") { try model.engine.retryStep(run) }
                } label: { Label("Retry Step", systemImage: "arrow.clockwise") }
                    .help("Run the failed step again")
            }
            Spacer()
            Button(role: .destructive) {
                isConfirmingCancel = true
            } label: { Label("Cancel Run", systemImage: "xmark") }
                .help("Stop the run and dismiss what it’s waiting on")
        }
        .buttonStyle(PillButtonStyle(height: 28))
        .font(.system(size: 12))
        .confirmationDialog("Cancel “\(run.title)”?", isPresented: $isConfirmingCancel) {
            Button("Cancel Run", role: .destructive) {
                Task { await model.performRunAction("Couldn’t cancel the run") { try await model.engine.cancel(run) } }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Agents stop and open questions are dismissed. Branches and worktrees stay.")
        }
    }
}

private struct FinalStateCard: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(run.status.color, size: 8)
                Text(headline).font(.system(size: 14, weight: .semibold))
                if let ended = run.endedAt {
                    Text(ended.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if let outcome = run.outcome, !outcome.isEmpty {
                Text(outcome).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            if run.status == .failed, let error = run.lastError {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let link = run.pullRequestURL, let url = URL(string: link) {
                    Link(destination: url) { Label("Open Pull Request", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.primaryPill)
                        .help(link)
                }
                if run.status == .failed {
                    Button {
                        model.performRunAction("Couldn’t retry the step") { try model.engine.retryStep(run) }
                        reload()
                    } label: { Label("Retry Step", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pill)
                        .help("Run the failed step again")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(run.status.color.opacity(0.09), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(run.status.color.opacity(0.3)))
    }

    private var headline: String {
        switch run.status {
        case .succeeded: run.pullRequestURL == nil ? "Run finished" : "Run finished with a pull request"
        case .failed: "Run failed"
        case .cancelled: "Run cancelled"
        default: run.status.label
        }
    }
}

private struct StepHistory: View {
    let entries: [RunTimeline.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Steps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                StepRow(entry: entry)
                if entry.id != entries.last?.id {
                    Divider().overlay(Color.white.opacity(0.05))
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        .card(cornerRadius: 16)
    }
}

private struct StepRow: View {
    let entry: RunTimeline.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(entry.status.color)
                Text(entry.title).font(.system(size: 13, weight: .medium))
                if entry.iteration > 1 {
                    Text("pass \(entry.iteration)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
                }
                if let outcome = entry.outcomeTitle {
                    Chip(text: outcome, foreground: outcomeColor, background: outcomeColor.opacity(0.14))
                } else {
                    Chip(text: entry.status.label, foreground: entry.status.color, background: entry.status.color.opacity(0.14))
                }
                Spacer(minLength: 8)
                if entry.costUSD > 0 {
                    Text(entry.costUSD.formatted(.currency(code: "USD")))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
            }
            ForEach(entry.issues.indices, id: \.self) { index in
                let issue = entry.issues[index]
                Text("• " + [issue.agent, issue.file].compactMap(\.self).joined(separator: " · ") + (issue.agent == nil && issue.file == nil ? "" : ": ") + issue.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 15)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case StepOutcome.changesRequested, StepOutcome.failed, "rejected": Theme.warning
        default: entry.status == .failed ? Theme.danger : Theme.successText
        }
    }
}
