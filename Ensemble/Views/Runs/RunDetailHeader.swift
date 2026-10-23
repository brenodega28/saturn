import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunDetailHeader: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunDetailSnapshot
    let project: Project
    let reload: () -> Void

    private var run: Run { snapshot.run }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    titleBlock
                    Spacer(minLength: 12)
                    RunDetailControls(snapshot: snapshot, reload: reload).fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    RunDetailControls(snapshot: snapshot, reload: reload)
                }
            }
            if let hold = snapshot.hold {
                HoldBanner(hold: hold)
            } else if run.status == .failed, let error = run.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RunStats(snapshot: snapshot)
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.closeRunDetail(in: project)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Theme.fillRaised, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .help("Close the run details")
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(RunDetailFormat.runTitle(run))
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    StatusChip(text: model.statusLabel(of: run), color: model.statusColor(of: run))
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private var subtitle: String {
        let workflow = snapshot.workflow.map { "\($0.name) v\(run.workflowVersion ?? String($0.version))" } ?? run.workflow
        let step = run.isActive ? model.currentStepTitle(of: run).map { "at \($0)" } : nil
        return [workflow, step, "started \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"]
            .compactMap(\.self).joined(separator: " · ")
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

private struct HoldBanner: View {
    let hold: RunHold

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: hold.reason.inboxKind.symbol)
                .foregroundStyle(hold.reason.inboxKind.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hold.reason.title).font(.system(size: 12.5, weight: .semibold))
                Text(hold.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hold.reason.inboxKind.tint.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct RunStats: View {
    let snapshot: RunDetailSnapshot

    private var run: Run { snapshot.run }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            stat("Cost", value: costText) {
                if let budget = run.budgetUSD, budget > 0 {
                    ProgressView(value: min(run.costUSD, budget), total: budget)
                        .tint(run.costUSD > budget ? Theme.danger : Theme.accent)
                        .accessibilityLabel("Budget used")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                stat("Duration", value: RunDetailFormat.duration((run.endedAt ?? context.date).timeIntervalSince(run.startedAt))) { EmptyView() }
            }
            stat("Steps", value: stepsText) { EmptyView() }
            if let task = snapshot.task {
                sourceStat(task)
            }
            if let link = run.pullRequestURL, let url = URL(string: link) {
                linkStat("Pull request", title: Self.pullRequestTitle(link), url: url)
            }
        }
    }

    private var stepsText: String {
        let steps = snapshot.history?.entries.count ?? snapshot.steps.count
        let loops = snapshot.history?.loops.count ?? 0
        return "\(steps) run · \(loops) loop\(loops == 1 ? "" : "s")"
    }

    private var costText: String {
        guard let budget = run.budgetUSD else { return RunDetailFormat.dollars(run.costUSD) }
        return "\(RunDetailFormat.dollars(run.costUSD)) of \(RunDetailFormat.dollars(budget))"
    }

    @ViewBuilder
    private func sourceStat(_ task: ProjectTask) -> some View {
        if task.source == .github, let link = task.sourceURL, let url = URL(string: link) {
            linkStat("Task", title: task.externalNumber.map { "Issue #\($0)" } ?? "GitHub issue", url: url)
        } else {
            stat("Task", value: task.source == .chat ? "Lead chat" : task.source.rawValue) { EmptyView() }
        }
    }

    private func stat<Extra: View>(_ title: String, value: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            extra()
        }
        .accessibilityElement(children: .combine)
    }

    private func linkStat(_ title: String, title linkTitle: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Link(destination: url) {
                Label(linkTitle, systemImage: "arrow.up.forward.square")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .help(url.absoluteString)
        }
    }

    static func pullRequestTitle(_ link: String) -> String {
        guard let number = link.split(separator: "/").last, Int(number) != nil else { return "Open" }
        return "PR #\(number)"
    }
}

struct RunDetailControls: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunDetailSnapshot
    let reload: () -> Void
    @State private var isConfirmingCancel = false

    private var run: Run { snapshot.run }

    var body: some View {
        let canRetry = run.status == .failed || snapshot.hold?.reason.allowsRetry == true
        FlowLayout(spacing: 8) {
            if run.status == .running || run.status == .pending {
                Button {
                    Task {
                        await model.performRunAction("Couldn’t pause the run") { try await model.engine.pause(run) }
                        reload()
                    }
                } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Interrupt the current step and hold the run; resume later")
            } else if run.status == .paused || run.status == .interrupted {
                Button {
                    model.performRunAction("Couldn’t resume the run") { try model.engine.resume(run) }
                    reload()
                } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Continue the run from where it stopped")
            }
            if canRetry {
                Button {
                    model.performRunAction("Couldn’t retry the step") { try model.engine.retryStep(run) }
                    reload()
                } label: { Label("Retry Step", systemImage: "arrow.clockwise") }
                    .help("Run the failed step again")
            }
            if run.isActive {
                Button(role: .destructive) {
                    isConfirmingCancel = true
                } label: { Label("Cancel", systemImage: "xmark") }
                    .help("Stop the run and dismiss what it’s waiting on")
            }
            Button {
                model.openRunInLead(run)
            } label: { Label("Open in Lead Chat", systemImage: "bubble.left.and.text.bubble.right") }
                .help("Show this run in the Lead tab")
        }
        .buttonStyle(PillButtonStyle(height: 28))
        .font(.system(size: 12))
        .confirmationDialog("Cancel “\(RunDetailFormat.runTitle(run))”?", isPresented: $isConfirmingCancel) {
            Button("Cancel Run", role: .destructive) {
                Task {
                    await model.performRunAction("Couldn’t cancel the run") { try await model.engine.cancel(run) }
                    reload()
                }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Agents stop and open questions are dismissed. Branches and worktrees stay.")
        }
    }
}
