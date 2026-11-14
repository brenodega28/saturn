import EnsembleCore
import EnsembleUI
import SwiftUI

struct RequestChat: View {
    @Environment(AppModel.self) private var model
    let task: Chat
    let project: Project
    @State private var data: RequestThreadData?
    @State private var highlightedItemID: String?
    @State private var spec: SpecFile?
    @State private var sendCount = 0
    @State private var revealCount = 0

    var body: some View {
        let session = model.leadSession(for: task)
        let isThinking = session.map { $0.isRunning || $0.isQueued } ?? false
        let working = model.workingSessions(for: task)
        thread(isThinking: isThinking, session: session, working: working)
            .onChange(of: data?.thread.items.count, initial: true) { model.markViewed(task) }
    }

    private func thread(isThinking: Bool, session: AgentSession?, working: [AgentSession]) -> some View {
        let held = model.heldSends(for: model.leadSendTarget(for: task, in: project))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ChatHeaderPill(task: task, project: project)
                        .frame(maxWidth: .infinity)
                    if let data {
                        ForEach(data.thread.items) { item in
                            row(item, data: data)
                                .background {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Theme.accent.opacity(highlightedItemID == item.id ? 0.2 : 0))
                                        .padding(-8)
                                }
                                .id(item.id)
                                .transition(.asymmetric(insertion: insertion(of: item), removal: .opacity))
                        }
                    }
                    ForEach(held) { send in
                        RequestBubble(held: send, onCancel: model.cancelHeldSend)
                            .id(send.id.uuidString)
                    }
                    if !working.isEmpty {
                        WorkingAgentsRow(sessions: working, project: project)
                            .id(Self.workingID)
                    }
                    if isThinking {
                        ThinkingRow(role: data?.leadRole, name: data?.leadName ?? "Lead", session: session)
                            .id(Self.thinkingID)
                    }
                }
                .animation(.snappy(duration: 0.25), value: data?.thread.items.map(\.id))
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 22, leading: 28, bottom: 16, trailing: 28))
            }
            .defaultScrollAnchor(.bottom)
            .followsBottom(
                of: FollowSignature(
                    items: data?.thread.items.map(\.id) ?? [],
                    held: held.map(\.id),
                    isThinking: isThinking,
                    entries: [isThinking ? session.flatMap(Self.latestEntry) : nil] + working.map(Self.latestEntry)
                ),
                jumpingOn: sendCount,
                releasingOn: revealCount
            )
            .onChange(of: data?.thread.items.last?.id) { revealHighlight(proxy) }
            .onChange(of: held.map(\.id)) { old, new in
                if new.contains(where: { !old.contains($0) }) { sendCount += 1 }
            }
            .onChange(of: data.map(Self.userMessageCount)) { old, new in
                if let old, let new, new > old { sendCount += 1 }
            }
            .onChange(of: model.chatHighlight) { revealHighlight(proxy) }
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
    private static let workingID = "working-agents"

    private struct FollowSignature: Equatable {
        let items: [String]
        let held: [UUID]
        let isThinking: Bool
        let entries: [TranscriptEntry?]
    }

    private static func latestEntry(of session: AgentSession) -> TranscriptEntry? {
        session.transcript.liveEntry ?? session.transcript.entries.last
    }

    private static func userMessageCount(in data: RequestThreadData) -> Int {
        data.thread.items.count { if case .message(let message) = $0 { message.kind == .user } else { false } }
    }

    private func revealHighlight(_ proxy: ScrollViewProxy) {
        guard let link = model.chatHighlight, link.requestID == task.id, let data else { return }
        model.chatHighlight = nil
        guard let messageID = link.messageID,
              let target = data.thread.items.first(where: { if case .message(let message) = $0 { message.id == messageID } else { false } })?.id
        else { return }
        revealCount += 1
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
            withAnimation(.easeIn(duration: 0.2)) { highlightedItemID = target }
            try? await Task.sleep(for: .seconds(1.6))
            guard highlightedItemID == target else { return }
            withAnimation(.easeOut(duration: 1.2)) { highlightedItemID = nil }
        }
    }

    private func insertion(of item: RequestThread.Item) -> AnyTransition {
        if case .message(let message) = item, message.kind == .user { return .identity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private func reload() {
        let latestSpec = model.specDraft(for: task)
        if latestSpec != spec { spec = latestSpec }
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
            if message.id != nil {
                messageRow(message, data: data)
                    .contextMenu {
                        Button("Copy Link to Message") { model.copyLink(to: task, message: message) }
                    }
            } else {
                messageRow(message, data: data)
            }
        case .runStarted(let run):
            LeadBubble(role: data.leadRole, name: data.leadName, date: run.startedAt) {
                HStack(spacing: 8) {
                    if model.runWorkflow(run).map({ !$0.hasLead }) == true {
                        NoPlanPill()
                    }
                    Text("Started the run.").font(.system(size: 14))
                }
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
        case .notice(let request):
            ChatRequestCard(item: request)
                .padding(.leading, 42)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: LeadMessage, data: RequestThreadData) -> some View {
        switch message.kind {
        case .user:
            RequestBubble(text: message.text, date: message.createdAt, attachments: message.storedAttachments)
        case .lead:
            LeadBubble(role: data.leadRole, name: data.leadName, date: message.createdAt) {
                ChatText(message.text)
            }
        case .proposal:
            let hasActiveRun = data.thread.items.contains { if case .hold = $0 { true } else { false } } || activeRun(in: data) != nil
            if let spec, let document = ProposalCard.attachedSpec(spec, to: message) {
                let workflow = message.workflow.flatMap { model.config(for: project).workflow($0) }
                SpecCard(
                    spec: spec, document: document, proposal: message, project: project,
                    canStart: !hasActiveRun && !task.isClosed && workflow != nil,
                    startHelp: ProposalCard.startHelp(hasActiveRun: hasActiveRun, isRequestClosed: task.isClosed)
                )
                .padding(.leading, 42)
            } else {
                ProposalCard(proposal: message, project: project, hasActiveRun: hasActiveRun, isRequestClosed: task.isClosed)
                    .padding(.leading, 42)
            }
        case .note:
            ChatNote(text: message.text)
                .padding(.leading, 42)
        case .permission:
            PermissionCard(card: message, project: project)
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
        case .planApproval: return "Here’s the plan. Reorder tasks, change their skills, or drop tasks before I start."
        case .approval: return "It’s ready for your approval at “\(step)”."
        case .loopLimit: return "The work keeps going back and forth. Tell me whether to try once more."
        case .stepBudget, .runBudget: return "We hit a budget limit. Decide whether to spend more."
        case .stepFailed, .timedOut: return "“\(step)” didn’t finish. Retry it, or stop the run."
        case .gates: return "The gates found things you need to decide on: continue, or send the work back."
        }
    }
}

private struct ChatHeaderPill: View {
    @Environment(AppModel.self) private var model
    let task: Chat
    let project: Project

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(V4.label.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(task.closeReason.map { $0.color.opacity(0.12) } ?? Color.white.opacity(0.06), in: Capsule())
            .contextMenu { RequestCloseMenu(request: task, project: project) }
            .help("Right-click to copy a link to this chat or close it")
            .accessibilityAddTraits(.isHeader)
    }

    private var text: String {
        let title = task.title.isEmpty ? "Request #\(task.id ?? 0)" : task.title
        var parts = [title, "started \(task.createdAt.formatted(date: .omitted, time: .shortened))"]
        if let reason = task.closeReason {
            parts.append("closed as \(reason.title) · send a message to reopen")
        } else if let run = model.latestRun(of: task), run.isActive {
            parts.append("run in \(model.currentStepTitle(of: run) ?? model.statusLabel(of: run))")
        }
        return parts.joined(separator: " · ")
    }
}

struct ChatText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        MarkdownText(text: text, fontSize: 14)
    }
}

struct ThinkingRow: View {
    let role: RoleDefinition?
    let name: String
    var session: AgentSession? = nil

    var body: some View {
        let activity = session.map { TranscriptLayout.activity($0.transcript.entries, live: $0.transcript.liveEntry) } ?? .working
        let root = session.flatMap { $0.transcript.session?.cwd ?? $0.agent.worktreePath }
        HStack(alignment: activity.isReply ? .top : .center, spacing: 12) {
            LeadAvatar(appearance: RoleAppearance(role: role))
            SessionActivityView(activity: activity, name: name, root: root)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy(duration: 0.2), value: activity.phase)
        }
        .accessibilityElement(children: activity.isReply ? .contain : .combine)
    }
}

private struct WorkingAgentsRow: View {
    @Environment(AppModel.self) private var model
    let sessions: [AgentSession]
    let project: Project

    var body: some View {
        if sessions.count == 1, let session = sessions.first {
            Button { model.openAgentSession(session.agent, in: project) } label: {
                BackgroundAgentRow(session: session, role: model.role(for: session.agent, in: project), name: model.displayName(of: session.agent, in: project))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(model.displayName(of: session.agent, in: project))’s session")
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(sessions.count) agents working")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(minHeight: 30)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(sessions) { session in
                        let name = model.displayName(of: session.agent, in: project)
                        Button { model.openAgentSession(session.agent, in: project) } label: {
                            BackgroundAgentLine(session: session, role: model.role(for: session.agent, in: project), name: name)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(name)’s session")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct BackgroundAgentRow: View {
    let session: AgentSession
    let role: RoleDefinition?
    let name: String

    var body: some View {
        let activity = TranscriptLayout.activity(session.transcript.entries, live: session.transcript.liveEntry)
        let root = session.transcript.session?.cwd ?? session.agent.worktreePath
        HStack(alignment: .top, spacing: 12) {
            RoleBadge(role: role, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(name).fontWeight(.semibold).foregroundStyle(.white)
                    Text(session.agent.runId == nil ? "· working in the background" : "· working on the run").foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 12))
                SessionActivityView(activity: activity, name: name, root: root)
                    .animation(.snappy(duration: 0.2), value: activity.phase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: activity.isReply ? .contain : .combine)
    }
}

private struct BackgroundAgentLine: View {
    let session: AgentSession
    let role: RoleDefinition?
    let name: String

    var body: some View {
        let activity = TranscriptLayout.activity(session.transcript.entries, live: session.transcript.liveEntry)
        let root = session.transcript.session?.cwd ?? session.agent.worktreePath
        HStack(spacing: 8) {
            RoleBadge(role: role, size: 18)
            Text(name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            compactActivity(activity, root: root)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.snappy(duration: 0.2), value: activity.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(activity.summary(relativeTo: root))")
    }

    @ViewBuilder
    private func compactActivity(_ activity: SessionActivity, root: String?) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            switch activity {
            case .tool(let tool):
                Text(tool.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.link)
                Text(tool.target(relativeTo: root))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let start = tool.startedAt { ElapsedLabel(start: start) }
            case .replying(let text):
                Text(text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            case .thinking:
                Text("Thinking…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            case .working:
                Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

private extension SessionActivity {
    func summary(relativeTo root: String?) -> String {
        switch self {
        case .working: "working"
        case .replying: "writing a reply"
        case .thinking: "thinking"
        case .tool(let tool): "\(tool.name) \(tool.target(relativeTo: root))"
        }
    }

    var isReply: Bool {
        if case .replying = self { return true }
        return false
    }

    var phase: Int {
        switch self {
        case .working: 0
        case .replying: 1
        case .thinking: 2
        case .tool: 3
        }
    }
}

struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    let proposal: LeadMessage
    let project: Project
    let hasActiveRun: Bool
    let isRequestClosed: Bool
    @State private var showsBrief = false

    static func attachedSpec(_ spec: SpecFile, to proposal: LeadMessage) -> SpecDocument? {
        guard let document = spec.document else { return nil }
        if proposal.status == .open { return document.status == .done ? nil : document }
        return proposal.runId.map(document.linkedRuns.contains) == true ? document : nil
    }

    static func startHelp(hasActiveRun: Bool, isRequestClosed: Bool) -> String {
        if isRequestClosed { return "This request is closed. Send a message to reopen it first." }
        return hasActiveRun ? "Wait for the current run to end" : "Start the run; the lead plans it first"
    }

    var body: some View {
        let workflow = proposal.workflow.flatMap { model.config(for: project).workflow($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Proposed run").font(.system(size: 12, weight: .semibold)).foregroundStyle(V4.secondary)
                Text(workflow?.displayName ?? proposal.workflow ?? "").font(.system(size: 12)).foregroundStyle(V4.link)
                if workflow.map({ !$0.hasLead }) == true {
                    NoPlanPill()
                }
                Spacer(minLength: 0)
                statusLabel
            }
            Text(proposal.title ?? "Run").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if showsBrief {
                ChatText(proposal.text)
                    .foregroundStyle(Theme.secondaryText)
            }
            Button(showsBrief ? "Show less" : "Show more") {
                withAnimation(.snappy(duration: 0.2)) { showsBrief.toggle() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(V4.link)
            .help(showsBrief ? "Hide the full brief" : "Show the full brief the run will start from")
            if proposal.status == .open {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Dismiss") { model.dismissProposal(proposal) }
                        .buttonStyle(V4Pill(kind: .secondary))
                        .help("Don’t run this; keep talking to the lead")
                    Button("Start run") { model.startProposal(proposal, in: project) }
                        .buttonStyle(V4Pill(kind: .primary, horizontalPadding: 16))
                        .disabled(hasActiveRun || isRequestClosed || workflow == nil)
                        .help(Self.startHelp(hasActiveRun: hasActiveRun, isRequestClosed: isRequestClosed))
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(proposal.status == .open ? V4.blue.opacity(0.35) : Color.white.opacity(0.08)))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch proposal.status {
        case .started: Text("Started").font(.system(size: 12, weight: .semibold)).foregroundStyle(V4.greenText)
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
    let item: ChatRequest

    var body: some View {
        let form = QuestionForm(item: item)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
                Text(item.status == .answered ? "\(item.title) — you answered" : "\(item.title) — dismissed")
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
    private let attachments: [SentAttachment]
    private let onCancel: (() -> Void)?

    init(text: String, date: Date, attachments: [StoredChatAttachment] = []) {
        self.text = text
        self.date = date
        self.attachments = attachments.map(SentAttachment.init)
        onCancel = nil
    }

    init(held: HeldSend, onCancel: @escaping (HeldSend) -> Void) {
        text = held.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        date = held.date
        attachments = held.message.attachments.map(SentAttachment.init)
        self.onCancel = held.isCancellable ? { onCancel(held) } : nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            if !text.isEmpty {
                Text(Self.linked(text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.85), in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                    .accessibilityLabel("You: \(text)")
            }
            if let onCancel {
                HStack(spacing: 10) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.link)
                        .help("Stop this message and put it back in the composer (Esc)")
                        .accessibilityLabel("Cancel send")
                    Text(date.formatted(.relative(presentation: .named))).font(.system(size: 11.5)).foregroundStyle(V4.secondary)
                }
            }
        }
        .help(date.formatted(date: .abbreviated, time: .shortened))
        .frame(maxWidth: 593, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: attachments.isEmpty && onCancel == nil ? .combine : .contain)
    }

    private static func linked(_ text: String) -> AttributedString {
        var linked = MarkdownText.linkingChatLinks(AttributedString(text))
        for run in linked.runs where run.link != nil {
            linked[run.range].foregroundColor = .white
            linked[run.range].underlineStyle = .single
        }
        return linked
    }
}

private struct SentAttachment {
    enum Content {
        case imageFile(URL)
        case imageData(Data)
        case pastedText(String)
    }

    let label: String
    let content: Content

    init(_ stored: StoredChatAttachment) {
        label = stored.label
        switch stored {
        case .image(_, _, _, let path): content = .imageFile(URL(fileURLWithPath: path))
        case .pastedText(_, _, let text): content = .pastedText(text)
        }
    }

    init(_ attachment: ChatAttachment) {
        label = attachment.label
        switch attachment {
        case .image(_, _, _, let data): content = .imageData(data)
        case .pastedText(_, _, let text): content = .pastedText(text)
        }
    }
}

private struct SentAttachments: View {
    let attachments: [SentAttachment]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                switch attachment.content {
                case .imageFile(let url):
                    SentImage(source: .imageFile(url), name: attachment.label)
                case .imageData(let data):
                    SentImage(source: .imageData(data), name: attachment.label)
                case .pastedText(let text):
                    PastedTextChip(label: attachment.label, text: text)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You attached \(attachments.map(\.label).joined(separator: ", "))")
    }
}

private struct SentImage: View {
    enum Source: Hashable {
        case imageFile(URL)
        case imageData(Data)
    }

    let source: Source
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ImageAttachmentThumbnail(image: image, name: name, size: 120)
            .task(id: source) {
                switch source {
                case .imageFile(let url): image = NSImage(contentsOf: url)
                case .imageData(let data): image = NSImage(data: data)
                }
            }
    }
}

struct LeadBubble<Content: View>: View {
    let role: RoleDefinition?
    let name: String
    let date: Date
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LeadAvatar(appearance: RoleAppearance(role: role))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Text(name).fontWeight(.semibold).foregroundStyle(.white)
                    Text("· \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(V4.secondary)
                }
                .font(.system(size: 12))
                .help(date.formatted(date: .abbreviated, time: .shortened))
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
    @State private var isChoosingMergeMethod = false
    @State private var isMerging = false
    @State private var isPushing = false

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
                if canMerge, let delivery = run.deliveryBranch {
                    Button { isChoosingMergeMethod = true } label: {
                        if isMerging {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Merging…")
                            }
                        } else {
                            Label("Merge Now", systemImage: "arrow.triangle.merge")
                        }
                    }
                    .buttonStyle(.pill)
                    .disabled(isMerging)
                    .help("Merge \(delivery) into \(baseName) on this Mac")
                    .confirmationDialog("Merge \(delivery) into \(baseName)?", isPresented: $isChoosingMergeMethod, titleVisibility: .visible) {
                        ForEach(MergeMethod.allCases, id: \.self) { method in
                            Button(method.title) { merge(method) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Ensemble merges \(delivery) into \(baseName) on this Mac and deletes \(delivery). You can push \(baseName) afterwards.")
                    }
                }
                if canPush {
                    Button(action: push) {
                        if isPushing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Pushing…")
                            }
                        } else {
                            Label("Push to origin", systemImage: "arrow.up.circle")
                        }
                    }
                    .buttonStyle(.primaryPill)
                    .disabled(isPushing)
                    .help("Push \(baseName) to origin")
                }
                if run.pushedAt != nil {
                    Label("Pushed \(baseName) to origin", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                } else if run.mergedAt != nil {
                    Label("Merged into \(baseName) on this Mac", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
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

    private var canMerge: Bool {
        run.status == .succeeded && run.deliveryBranch != nil && run.mergedAt == nil
    }

    private var canPush: Bool {
        run.mergedAt != nil && run.pushedAt == nil
    }

    private func push() {
        isPushing = true
        Task {
            await model.performRunAction("Couldn’t push \(baseName)") { _ = try await model.engine.push(run) }
            isPushing = false
            reload()
        }
    }

    private var baseName: String {
        run.baseBranch ?? "the base branch"
    }

    private func merge(_ method: MergeMethod) {
        isMerging = true
        Task {
            await model.performRunAction("Couldn’t merge") { try await model.engine.mergeDelivery(run, method: method) }
            isMerging = false
            reload()
        }
    }

    private var headline: String {
        switch run.status {
        case .succeeded where run.pushedAt != nil: "Run finished, merged and pushed"
        case .succeeded where run.mergedAt != nil: "Run finished and merged"
        case .succeeded where run.deliveryBranch != nil: "Run finished, ready to merge"
        case .succeeded: "Run finished"
        case .failed: "Run failed"
        case .cancelled: "Run cancelled"
        default: model.statusLabel(of: run)
        }
    }
}

private extension MergeMethod {
    var title: String {
        switch self {
        case .mergeCommit: "Merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
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

private struct ChatNote: View {
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
        .accessibilityLabel("Note: \(text)")
    }
}
