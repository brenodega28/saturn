import EnsembleCore
import EnsembleUI
import SwiftUI

struct RequestChat: View {
    @Environment(AppModel.self) private var model
    let task: ProjectTask
    let project: Project
    @State private var data: RequestThreadData?

    var body: some View {
        let session = model.leadSession(for: task)
        let isThinking = session.map { $0.isRunning || $0.isQueued } ?? false
        VStack(spacing: 10) {
            RequestHeader(task: task, project: project)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            thread(isThinking: isThinking)
        }
    }

    private func thread(isThinking: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let data {
                        ForEach(data.thread.items) { item in
                            row(item, data: data)
                                .id(item.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    if isThinking {
                        ThinkingRow(role: data?.leadRole, name: data?.leadName ?? "Lead")
                            .id(Self.thinkingID)
                    }
                }
                .animation(.snappy(duration: 0.25), value: data?.thread.items.map(\.id))
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: data?.thread.items.last?.id) { scrollToEnd(proxy) }
            .onChange(of: isThinking) { scrollToEnd(proxy) }
        }
        .task(id: task.id) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: model.leadChatRevision) { reload() }
    }

    private static let thinkingID = "thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let isThinking = model.leadSession(for: task).map { $0.isRunning || $0.isQueued } ?? false
        let target = isThinking ? Self.thinkingID : data?.thread.items.last?.id
        guard let target else { return }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func reload() {
        guard let latest = model.requestThread(for: task, in: project) else { return }
        if latest.thread != data?.thread { data = latest }
    }

    @ViewBuilder
    private func row(_ item: RequestThread.Item, data: RequestThreadData) -> some View {
        switch item {
        case .request(let task):
            let request = ChatAttachment.splitPrompt(task.body)
            RequestBubble(
                text: request.text.isEmpty && request.pastes.isEmpty ? task.title : request.text,
                date: task.createdAt,
                attachments: request.pastes.compactMap { paste in
                    guard case .pastedText(let id, let index, let text) = paste else { return nil }
                    return .pastedText(id: id, index: index, text: text)
                }
            )
        case .message(let message):
            switch message.kind {
            case .user:
                RequestBubble(text: message.text, date: message.createdAt, attachments: message.storedAttachments)
            case .lead:
                LeadBubble(role: data.leadRole, name: data.leadName, date: message.createdAt) {
                    ChatText(message.text)
                }
            case .proposal:
                LeadBubble(role: data.leadRole, name: data.leadName, date: message.createdAt) {
                    ProposalCard(proposal: message, project: project, hasActiveRun: data.thread.items.contains { if case .hold = $0 { true } else { false } } || activeRun(in: data) != nil, isRequestClosed: task.isClosed)
                }
            case .note:
                DirectMessageNote(text: message.text)
                    .padding(.leading, 42)
            }
        case .runStarted(let run):
            LeadBubble(role: data.leadRole, name: data.leadName, date: run.startedAt) {
                Text("Started the run.").font(.system(size: 14))
                RunCard(run: live(run), workflow: model.runWorkflow(run), timeline: run.id.flatMap { data.timelines[$0] }, agentCount: agentCount(run))
            }
        case .step(let run, let entry):
            StepEvent(entry: entry, needsYou: model.stepNeedsYou(entry.status, in: live(run)))
        case .answeredQuestion(let question):
            AnsweredQuestion(item: question)
        case .runEnded(let run):
            FinalStateCard(run: run, reload: reload)
                .padding(.leading, 42)
        case .openQuestion(let question):
            QuestionCard(item: question, project: project, reload: reload)
                .padding(.leading, 42)
        case .hold(let run):
            let current = live(run)
            if let hold = run.id.flatMap({ model.engine.holds[$0] }), let timeline = run.id.flatMap({ data.timelines[$0] }) {
                LeadBubble(role: data.leadRole, name: data.leadName, date: .now) {
                    Text(holdSentence(hold, run: current)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    HoldCard(run: current, project: project, hold: hold, timeline: timeline, reload: reload)
                }
            }
        }
    }

    private func activeRun(in data: RequestThreadData) -> Run? {
        data.thread.items.lazy.compactMap { item -> Run? in
            if case .runStarted(let run) = item { return self.live(run) }
            return nil
        }.first { $0.isActive }
    }

    private func live(_ run: Run) -> Run {
        run.id.flatMap { model.engine.runs[$0] } ?? run
    }

    private func agentCount(_ run: Run) -> Int {
        model.agentSessions(in: project).filter { $0.agent.runId == run.id && $0.agent.taskId == nil }.count
    }

    private func holdSentence(_ hold: RunHold, run: Run) -> String {
        let step = model.currentStepTitle(of: run) ?? "the next step"
        switch hold.reason {
        case .planApproval: return "Here’s the plan. Reorder, change roles or counts, or drop tasks before I start."
        case .approval: return "It’s ready for your approval at “\(step)”."
        case .loopLimit: return "The work keeps going back and forth. Tell me whether to try once more."
        case .stepBudget, .runBudget: return "We hit a budget limit. Decide whether to spend more."
        case .stepFailed, .timedOut: return "“\(step)” didn’t finish. Retry it, or stop the run."
        }
    }
}

private struct RequestHeader: View {
    @Environment(AppModel.self) private var model
    let task: ProjectTask
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Text(task.title.isEmpty ? "Request #\(task.id ?? 0)" : task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let reason = task.closeReason {
                closedBanner(reason)
            } else {
                closeMenu
            }
        }
    }

    private func closedBanner(_ reason: RequestCloseReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: reason == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(reason.color)
                .accessibilityHidden(true)
            Text("Closed as \(reason.title) · Send a message to reopen")
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(reason.color.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var closeMenu: some View {
        let hasActiveRun = model.requestHasActiveRun(task)
        return Menu {
            ForEach(RequestCloseReason.allCases, id: \.self) { reason in
                Button(reason.title) {
                    Task { await model.closeRequest(task, as: reason, in: project) }
                }
            }
        } label: {
            Label("Close", systemImage: "checkmark.circle")
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(height: 26))
        .font(.system(size: 12))
        .fixedSize()
        .disabled(hasActiveRun)
        .help(hasActiveRun ? RequestCloseReason.blockedHelp : "Close this request as done or dropped and clean up its worktrees")
    }
}

struct ChatText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 14))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ThinkingRow: View {
    let role: RoleDefinition?
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            RoleBadge(role: role, size: 30)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(name) is working…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: LeadMessage
    let project: Project
    let hasActiveRun: Bool
    let isRequestClosed: Bool

    var body: some View {
        let workflow = proposal.workflow.flatMap { model.config(for: project).workflow($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color(hex: 0x9CC6FF))
                    .accessibilityHidden(true)
                Text("Proposed run").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Text(workflow?.displayName ?? proposal.workflow ?? "").font(.system(size: 12)).foregroundStyle(Color(hex: 0x9CC6FF))
                Spacer(minLength: 0)
                statusLabel
            }
            Text(proposal.title ?? "Run").font(.system(size: 14.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ChatText(proposal.text)
                .foregroundStyle(Theme.secondaryText)
            if proposal.status == .open {
                HStack(spacing: 8) {
                    Button { model.startProposal(proposal, in: project) } label: { Label("Start Run", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle(.primary, height: 30))
                        .disabled(hasActiveRun || isRequestClosed || workflow == nil)
                        .help(startHelp)
                    Button("Dismiss") { model.dismissProposal(proposal) }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .help("Don’t run this; keep talking to the lead")
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.28)))
    }

    private var startHelp: String {
        if isRequestClosed { return "This request is closed. Send a message to reopen it first." }
        return hasActiveRun ? "Wait for the current run to end" : "Start the run; the lead plans it first"
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch proposal.status {
        case .started: Text("Started").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.successText)
        case .dismissed: Text("Dismissed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
        default: EmptyView()
        }
    }
}

private struct StepEvent: View {
    let entry: RunTimeline.Entry
    let needsYou: Bool

    var body: some View {
        StepRow(entry: entry, needsYou: needsYou)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .padding(.leading, 42)
    }
}

private struct AnsweredQuestion: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem

    var body: some View {
        let form = QuestionForm(item: item)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
                Text(item.status == .resolved ? "\(item.title) — you answered" : "\(item.title) — dismissed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(form.isMultiStep ? form.questions.enumerated().map { "\($0.offset + 1). \($0.element.question)" }.joined(separator: "\n") : form.questions.first?.question ?? item.body)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(6)
                .textSelection(.enabled)
            if let response = item.response, !response.isEmpty {
                Text(response)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.leading, 42)
    }
}

struct RequestBubble: View {
    let text: String
    let date: Date
    var attachments: [StoredChatAttachment] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.85), in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                    .accessibilityLabel("You: \(text)")
            }
            Text(date.formatted(.relative(presentation: .named))).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: 640, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: attachments.isEmpty ? .combine : .contain)
    }
}

private struct SentAttachments: View {
    let attachments: [StoredChatAttachment]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                switch attachment {
                case .image(_, _, let fileName, let path):
                    SentImage(url: URL(fileURLWithPath: path), name: fileName)
                case .pastedText(_, _, let text):
                    PastedTextChip(label: attachment.label, text: text)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You attached \(attachments.map(\.label).joined(separator: ", "))")
    }
}

private struct SentImage: View {
    let url: URL
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ImageAttachmentThumbnail(image: image, name: name, size: 120)
            .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

struct LeadBubble<Content: View>: View {
    let role: RoleDefinition?
    let name: String
    let date: Date
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoleBadge(role: role, size: 30)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Text(name).fontWeight(.semibold).foregroundStyle(.white)
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
                StatusDot(model.statusColor(of: run), size: 8)
                Text(run.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(model.statusLabel(of: run))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.statusColor(of: run))
                Button("Details") { model.openRunDetail(run) }
                    .buttonStyle(PillButtonStyle(height: 24))
                    .font(.system(size: 11.5))
                    .fixedSize()
                    .help("Show the workflow graph, timeline, agents and logs for this run")
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
        let color = model.statusColor(of: run)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color, size: 8)
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
        .background(color.opacity(0.09), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.3)))
    }

    private var headline: String {
        switch run.status {
        case .succeeded: run.pullRequestURL == nil ? "Run finished" : "Run finished with a pull request"
        case .failed: "Run failed"
        case .cancelled: "Run cancelled"
        default: model.statusLabel(of: run)
        }
    }
}

private struct StepRow: View {
    let entry: RunTimeline.Entry
    let needsYou: Bool

    var body: some View {
        let statusColor = entry.status.displayColor(needsYou: needsYou)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(statusColor)
                Text(entry.title).font(.system(size: 13, weight: .medium))
                if entry.iteration > 1 {
                    Text("pass \(entry.iteration)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
                }
                if let outcome = entry.outcomeTitle {
                    Chip(text: outcome, foreground: outcomeColor, background: outcomeColor.opacity(0.14))
                } else {
                    Chip(text: entry.status.displayLabel(needsYou: needsYou), foreground: statusColor, background: statusColor.opacity(0.14))
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
        case _ where needsYou: Theme.warning
        case StepOutcome.changesRequested, StepOutcome.failed, "rejected": Theme.warning
        default: entry.status == .failed ? Theme.danger : Theme.successText
        }
    }
}

private struct DirectMessageNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityLabel("Direct message summary: \(text)")
    }
}
