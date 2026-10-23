import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunTimelineView: View {
    let snapshot: RunDetailSnapshot
    let project: Project
    @State private var expanded: Set<Int64> = []

    var body: some View {
        let entries = snapshot.history?.entries ?? []
        if entries.isEmpty {
            Text(snapshot.run.isActive ? "The first step hasn’t started yet." : "This run has no steps.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 16)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    TimelineRow(
                        entry: entry, snapshot: snapshot, project: project,
                        isExpanded: Binding(
                            get: { expanded.contains(entry.id) },
                            set: { isOn in
                                if isOn { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
                            }
                        )
                    )
                    if entry.id != entries.last?.id {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .card(cornerRadius: 16)
        }
    }
}

private struct TimelineRow: View {
    @Environment(AppModel.self) private var model
    let entry: RunHistory.Entry
    let snapshot: RunDetailSnapshot
    let project: Project
    @Binding var isExpanded: Bool

    var body: some View {
        let roles = model.config(for: project).roles
        let agents = snapshot.agents.filter { agent in agent.id.map(entry.agentIDs.contains) == true }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                header(role: entry.role.flatMap { id in roles.first { $0.id == id } })
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses the step details" : "Shows the step details")
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            }
            if let hop = entry.hop {
                HopLine(hop: hop).padding(.leading, 32)
            }
            if !agents.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(agents) { agent in
                        AgentLink(agent: agent, role: roles.first { $0.id == agent.role }, project: project)
                    }
                }
                .padding(.leading, 32)
            }
            if isExpanded {
                TimelineDetails(entry: entry, workflow: snapshot.workflow, needsYou: needsYou)
                    .padding(.leading, 32)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
    }

    private func header(role: RoleDefinition?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            StepGlyph(type: entry.type, role: role, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if entry.iteration > 1 {
                        Text("pass \(entry.iteration)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    }
                    if entry.attempts.count > 1 {
                        Text("\(entry.attempts.count) attempts")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                FlowLayout(spacing: 6) {
                    StatusChip(text: entry.outcomeTitle ?? entry.status.displayLabel(needsYou: needsYou), color: outcomeColor)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(metrics(now: context.date))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func metrics(now: Date) -> String {
        [
            entry.startedAt.formatted(date: .omitted, time: .shortened),
            RunDetailFormat.duration(entry.duration(now: now)),
            entry.costUSD > 0 ? RunDetailFormat.dollars(entry.costUSD) : nil,
        ].compactMap(\.self).joined(separator: " · ")
    }

    private var needsYou: Bool {
        model.stepNeedsYou(entry.status, in: snapshot.run, agentIDs: entry.agentIDs)
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case _ where needsYou: Theme.warning
        case StepOutcome.changesRequested, StepOutcome.failed, "rejected": Theme.warning
        case nil: entry.status.color
        default: entry.status == .failed ? Theme.danger : Theme.successText
        }
    }
}

private struct HopLine: View {
    let hop: RunHistory.Hop

    var body: some View {
        let limit = hop.maxLoops.map { " of \($0)" } ?? ""
        HStack(spacing: 5) {
            Image(systemName: hop.isLoopBack ? "arrow.uturn.backward" : "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(hop.isLoopBack ? "Looped back to \(hop.toTitle) · loop \(hop.loopNumber)\(limit)" : "Then \(hop.toTitle)")
                .lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(hop.isLoopBack ? Theme.warning : Theme.tertiaryText)
    }
}

struct AgentLink: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let role: RoleDefinition?
    let project: Project

    var body: some View {
        let live = model.agents.session(for: agent)?.agent ?? agent
        let status = model.displayStatus(of: live)
        Button {
            model.openAgentSession(agent, in: project)
        } label: {
            HStack(spacing: 5) {
                AgentAvatar(size: 16, appearance: RoleAppearance(role: role))
                Text(live.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                StatusDot(status.color, size: 5)
            }
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(Theme.fillRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(live.name)’s session · \(role?.name ?? live.role) · \(status.label)")
        .accessibilityLabel("Open \(live.name)’s session, \(role?.name ?? live.role), \(status.label)")
    }
}

private struct TimelineDetails: View {
    let entry: RunHistory.Entry
    let workflow: WorkflowDefinition?
    let needsYou: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedback = entry.feedback {
                detailBlock("Received feedback") {
                    Text("\(RunTimeline.title(forOutcome: feedback.outcome)) from \(stepTitle(feedback.fromStep)): \(feedback.summary)")
                    issues(feedback.issues)
                }
            }
            if let plan = entry.handoff.plan {
                detailBlock("Plan · \(plan.tasks.count) task\(plan.tasks.count == 1 ? "" : "s")") {
                    Text(plan.summary)
                    ForEach(plan.tasks) { task in
                        Text("• \(task.title) — \(task.role)\(task.count > 1 ? " ×\(task.count)" : "")")
                    }
                }
            }
            if let verdict = entry.handoff.verdict {
                detailBlock("Verdict · \(RunTimeline.title(forOutcome: verdict.outcome))") {
                    if !verdict.summary.isEmpty { Text(verdict.summary) }
                    issues(verdict.issues)
                }
            }
            if let result = entry.handoff.result, !result.isEmpty, entry.handoff.plan == nil {
                detailBlock("Result") { Text(result) }
            }
            if !entry.handoff.taskResults.isEmpty {
                detailBlock("Task results") {
                    ForEach(entry.handoff.taskResults, id: \.self) { result in
                        Text("• \(result.agentName.map { "\($0): " } ?? "")\(result.summary)")
                    }
                }
            }
            detailBlock(entry.attempts.count == 1 ? "Attempt" : "Attempts") {
                ForEach(entry.attempts) { attempt in
                    AttemptRow(attempt: attempt, needsYou: needsYou && attempt.id == entry.latest?.id)
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.secondaryText)
        .textSelection(.enabled)
    }

    private func stepTitle(_ stepId: String) -> String {
        workflow.map { RunTimeline.title(ofStep: stepId, in: $0) } ?? stepId
    }

    @ViewBuilder
    private func issues(_ issues: [ReviewIssue]) -> some View {
        ForEach(issues.indices, id: \.self) { index in
            let issue = issues[index]
            let place = [issue.agent, issue.file].compactMap(\.self).joined(separator: " · ")
            Text("• \(place.isEmpty ? "" : "\(place): ")\(issue.description)")
        }
    }

    private func detailBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityAddTraits(.isHeader)
            content().fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct AttemptRow: View {
    let attempt: RunHistory.Attempt
    let needsYou: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusDot(attempt.status.displayColor(needsYou: needsYou), size: 6)
                Text("#\(attempt.number) \(attempt.status.displayLabel(needsYou: needsYou))").fontWeight(.medium)
                Text(details).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            if let summary = attempt.summary, !summary.isEmpty, attempt.status != .succeeded {
                Text(summary).padding(.leading, 12)
            }
        }
    }

    private var details: String {
        [
            attempt.startedAt.formatted(date: .omitted, time: .standard),
            attempt.endedAt.map { RunDetailFormat.duration($0.timeIntervalSince(attempt.startedAt)) },
            attempt.costUSD > 0 ? RunDetailFormat.dollars(attempt.costUSD) : nil,
        ].compactMap(\.self).joined(separator: " · ")
    }
}
