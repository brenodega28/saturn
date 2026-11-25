import SaturnCore
import SaturnUI
import SwiftUI

struct RequestChat: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let task: Chat
    let project: Project
    @State private var data: RequestThreadData?
    @State private var highlightedItemID: String?
    @State private var spec: SpecFile?
    @State private var sendCount = 0
    @State private var revealCount = 0

    var body: some View {
        let session = workspace.leadSession(for: task)
        let isThinking = session.map { $0.isRunning || $0.isQueued } ?? false
        let working = workspace.workingSessions(for: task)
        thread(isThinking: isThinking, session: session, working: working)
            .onChange(of: data?.thread.items.count, initial: true) { workspace.markViewed(task) }
    }

    private func thread(isThinking: Bool, session: LiveAgentSession?, working: [LiveAgentSession]) -> some View {
        let delivering = workspace.sendsDelivering(to: workspace.leadSendTarget(for: task, in: project))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if task.isClosed {
                        ClosedChatBanner(chat: task)
                    }
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
                    ForEach(delivering) { send in
                        RequestBubble(delivering: send)
                            .id(send.id.uuidString)
                    }
                    WorkerRoster(chat: task, project: project)
                        .id(Self.workingID)
                    if isThinking {
                        ThinkingRow(role: data?.leadRole, name: data?.leadName ?? "Lead", session: session)
                            .id(Self.thinkingID)
                    }
                }
                .animation(.snappy(duration: 0.25), value: data?.thread.items.map(\.id))
                .frame(maxWidth: Tokens.Size.transcript)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 22, leading: 28, bottom: 16, trailing: 28))
            }
            .defaultScrollAnchor(.bottom)
            .followsBottom(
                of: FollowSignature(
                    items: data?.thread.items.map(\.id) ?? [],
                    delivering: delivering.map(\.id),
                    isThinking: isThinking,
                    entries: [isThinking ? session.flatMap(Self.latestEntry) : nil] + working.map(Self.latestEntry)
                ),
                jumpingOn: sendCount,
                releasingOn: revealCount
            )
            .onChange(of: data?.thread.items.last?.id) { revealHighlight(proxy) }
            .onChange(of: delivering.map(\.id)) { old, new in
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
        .onChange(of: workspace.connection.revision) { reload() }
    }

    private static let thinkingID = "thinking"
    private static let workingID = "working-agents"

    private struct FollowSignature: Equatable {
        let items: [String]
        let delivering: [UUID]
        let isThinking: Bool
        let entries: [TranscriptEntry?]
    }

    private static func latestEntry(of session: LiveAgentSession) -> TranscriptEntry? {
        session.transcript.liveEntry ?? session.transcript.entries.last
    }

    private static func userMessageCount(in data: RequestThreadData) -> Int {
        data.thread.items.count { if case .message(let message) = $0 { message.kind == .user } else { false } }
    }

    private func revealHighlight(_ proxy: ScrollViewProxy) {
        guard let link = model.highlight(for: task, in: workspace), let data else { return }
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
        let latestSpec = workspace.specDraft(for: task)
        if latestSpec != spec { spec = latestSpec }
        guard let latest = workspace.requestThread(for: task, in: project) else { return }
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
                        Button("Copy Link to Message") { workspace.copyLink(to: task, message: message) }
                    }
            } else {
                messageRow(message, data: data)
            }
        case .runStarted(let run):
            LeadBubble(role: data.leadRole, name: data.leadName, date: run.startedAt) {
                HStack(spacing: 8) {
                    if workspace.runWorkflow(run).map({ !$0.hasLead }) == true {
                        NoPlanPill()
                    }
                    Text("Started the run.").font(.system(size: 14))
                }
                RunCard(run: live(run), workflow: workspace.runWorkflow(run), timeline: run.id.flatMap { data.timelines[$0] }, agentCount: agentCount(run))
            }
        case .step(let run, let entry):
            StepEvent(entry: entry, needsYou: workspace.stepNeedsYou(entry.status, in: live(run)))
        case .answeredQuestion(let question):
            AnsweredQuestion(item: question)
        case .runEnded(let run):
            FinalStateCard(run: run, reload: reload)
        case .openQuestion(let question):
            QuestionCard(item: question, project: project, reload: reload)
        case .hold(let run):
            let current = live(run)
            if let hold = run.id.flatMap({ workspace.connection.holds[$0] }), let timeline = run.id.flatMap({ data.timelines[$0] }) {
                LeadBubble(role: data.leadRole, name: data.leadName, date: .now) {
                    Text(holdSentence(hold, run: current)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    HoldCard(run: current, project: project, hold: hold, timeline: timeline, reload: reload)
                }
            }
        case .notice(let request):
            ChatRequestCard(item: request)
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
            let document = spec.flatMap { ProposalCard.attachedSpec($0, to: message) }
            ProposalCard(
                proposal: message, project: project, spec: document.flatMap { _ in spec }, document: document,
                hasActiveRun: hasActiveRun, isRequestClosed: task.isClosed
            )
        case .specFeedback:
            SpecFeedbackBubble(message: message) { workspace.openSpecTab(for: task, in: project) }
        case .specDraft:
            let hasActiveRun = data.thread.items.contains { if case .hold = $0 { true } else { false } } || activeRun(in: data) != nil
            SpecCard(card: message, task: task, project: project, spec: spec?.document, hasActiveRun: hasActiveRun)
        case .note:
            ChatNote(text: message.text)
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
        run
    }

    private func agentCount(_ run: Run) -> Int {
        workspace.agentSessions(in: project).filter { $0.agent.runId == run.id && $0.agent.taskId == nil }.count
    }

    private func holdSentence(_ hold: RunHold, run: Run) -> String {
        let step = workspace.currentStepTitle(of: run) ?? "the next step"
        switch hold.reason {
        case .planApproval: return "Here’s the plan. Reorder tasks, change their skills, or drop tasks before I start."
        case .approval: return "It’s ready for your approval at “\(step)”."
        case .loopLimit: return "The work keeps going back and forth. Tell me whether to try once more."
        case .stepFailed, .timedOut: return "“\(step)” didn’t finish. Retry it, or stop the run."
        case .gates: return "The gates found things you need to decide on: continue, or send the work back."
        }
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
    var session: LiveAgentSession? = nil

    var body: some View {
        let activity = session.map { TranscriptLayout.activity($0.transcript.entries, live: $0.transcript.liveEntry) } ?? .working
        let root = session.flatMap { $0.transcript.session?.cwd ?? $0.agent.worktreePath }
        HStack(alignment: activity.isReply ? .top : .center, spacing: 12) {
            RobotFace(kind: role.map { RobotFace.Kind(icon: $0.icon) } ?? .lead, size: 20, lookingAside: true)
            SessionActivityView(activity: activity, name: name, root: root)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy(duration: 0.2), value: activity.phase)
        }
        .accessibilityElement(children: activity.isReply ? .contain : .combine)
    }
}

extension SessionActivity {
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

struct ClearingNotice: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let agents: [Agent]

    var body: some View {
        if !agents.isEmpty {
            Text("Starting this run clears \(workspace.database.previousRunSummary(of: agents))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .help(agents.map { workspace.displayName(of: $0) }.joined(separator: ", "))
        }
    }
}

struct ProposalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let proposal: LeadMessage
    let project: Project
    var spec: SpecFile? = nil
    var document: SpecDocument? = nil
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
        let workflow = proposal.workflow.flatMap { workspace.config(for: project).workflow($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Proposed run").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
                Text(workflow?.displayName ?? proposal.workflow ?? "").font(.system(size: 12)).foregroundStyle(Tokens.link)
                if workflow.map({ !$0.hasLead }) == true {
                    NoPlanPill()
                }
                Spacer(minLength: 0)
                statusLabel
            }
            Text(proposal.title ?? "Run").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let workers = document?.workers, !workers.isEmpty {
                ProposalAgents(workers: workers, project: project)
            }
            if showsBrief {
                ChatText(proposal.text)
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 14) {
                if let spec {
                    Button("Spec attached") { workspace.openSpec(spec, in: project) }
                        .help("Open the spec in its review tab")
                }
                Button(showsBrief ? "Show less" : "Show more") {
                    withAnimation(.snappy(duration: 0.2)) { showsBrief.toggle() }
                }
                .help(showsBrief ? "Hide the full brief" : "Show the full brief the run will start from")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Tokens.link)
            if proposal.status == .open {
                ClearingNotice(agents: workspace.previousRunAgents(of: proposal, in: project))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Dismiss") { workspace.dismissProposal(proposal) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Don’t run this; keep talking to the lead")
                    Button("Start run") { workspace.startProposal(proposal) }
                        .buttonStyle(PrimaryPillStyle())
                        .disabled(hasActiveRun || isRequestClosed || workflow == nil)
                        .help(Self.startHelp(hasActiveRun: hasActiveRun, isRequestClosed: isRequestClosed))
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(proposal.status == .open ? Tokens.hair2 : Tokens.hair))
        .opacity(document?.status == .rejected ? 0.6 : 1)
        .contextMenu {
            if let spec { Button("Open Spec") { workspace.openSpec(spec, in: project) } }
            if proposal.status == .open, spec != nil {
                Button("Reject Spec") { workspace.rejectProposal(proposal) }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if document?.status == .rejected {
            Text("Spec rejected").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
        } else {
            switch proposal.status {
            case .started: Text("Started").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.done)
            case .dismissed: Text("Dismissed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            default: EmptyView()
            }
        }
    }
}

private struct ProposalAgents: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let workers: [SpecWorker]
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(workers.count) agent\(workers.count == 1 ? "" : "s")")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Tokens.text2)
            ForEach(Array(workers.enumerated()), id: \.offset) { _, worker in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RobotFace(kind: RobotFace.Kind(icon: workspace.config(for: project).role(worker.role)?.icon ?? worker.role), size: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(line(for: worker))
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(line(for: worker))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func line(for worker: SpecWorker) -> String {
        let who = worker.role.isEmpty || worker.role.caseInsensitiveCompare(worker.name) == .orderedSame ? worker.name : "\(worker.name) (\(worker.role))"
        return worker.reason.map { "\(who) — \($0)" } ?? who
    }
}

struct SpecCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let card: LeadMessage
    let task: Chat
    let project: Project
    let spec: SpecDocument?
    let hasActiveRun: Bool

    static func approveHelp(hasActiveRun: Bool, isRequestClosed: Bool, spec: SpecDocument?) -> String? {
        if isRequestClosed { return "This request is closed. Send a message to reopen it first." }
        if hasActiveRun { return "Wait for the current run to end" }
        if let status = spec?.status, status == .inProgress || status == .done { return "The spec is already committed on a run branch" }
        return nil
    }

    var body: some View {
        let info = card.specDraft
        let blocked = Self.approveHelp(hasActiveRun: hasActiveRun, isRequestClosed: task.isClosed, spec: spec)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Spec", systemImage: "doc.text").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
                if let info { Text("v\(info.version)").font(.system(size: 12)).foregroundStyle(Tokens.text2) }
                Spacer(minLength: 0)
                statusLabel
            }
            Text(card.title ?? "Spec").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let info {
                Text("\(info.criteria) acceptance criteri\(info.criteria == 1 ? "on" : "a")")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                if let reason = info.reason, card.status == .open {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Open spec") { workspace.openSpecTab(for: task, in: project) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Tokens.link)
                    .help("Open the spec’s review page")
                Spacer(minLength: 0)
                if card.status == .open {
                    Button("Request changes") { workspace.openSpecTab(for: task, in: project) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Annotate the spec page; your notes go to the lead")
                    Button("Approve") { workspace.approveSpec(for: task) }
                        .buttonStyle(PrimaryPillStyle())
                        .disabled(blocked != nil)
                        .help(blocked ?? "Approve the spec and start the run")
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(card.status == .open ? Tokens.hair2 : Tokens.hair))
        .opacity(card.status == .dismissed ? 0.6 : 1)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch card.status {
        case .dismissed:
            Text("Superseded").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
        case .started:
            Text(card.runId.map { "Run \($0) started" } ?? "Run started").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.done)
        default:
            let status = spec?.status ?? .draft
            Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(status.color)
        }
    }
}

private struct SpecFeedbackBubble: View {
    let message: LeadMessage
    let openSpec: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: openSpec) {
                Label("Spec feedback", systemImage: "text.bubble")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Tokens.link)
            }
            .buttonStyle(.plain)
            .help("Open the spec review page these notes came from")
            RequestBubble(text: message.text, date: message.createdAt)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct StepEvent: View {
    let entry: RunTimeline.Entry
    let needsYou: Bool

    var body: some View {
        StepRow(entry: entry, needsYou: needsYou)
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(Tokens.hover, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
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
        .background(Tokens.hover, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct RequestBubble: View {
    let text: String
    let date: Date
    private let attachments: [SentAttachment]

    init(text: String, date: Date, attachments: [StoredChatAttachment] = []) {
        self.text = text
        self.date = date
        self.attachments = attachments.map(SentAttachment.init)
    }

    init(delivering send: DeliveringSend) {
        text = send.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        date = send.date
        attachments = send.message.attachments.map(SentAttachment.init)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                SentAttachments(attachments: attachments)
            }
            if !text.isEmpty {
                Text(Self.linked(text))
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Tokens.bubble, in: .rect(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("You: \(text)")
            }
        }
        .help(date.formatted(date: .abbreviated, time: .shortened))
        .frame(maxWidth: Tokens.Size.transcript * 0.8, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: attachments.isEmpty ? .combine : .contain)
    }

    private static func linked(_ text: String) -> AttributedString {
        var linked = MarkdownText.linkingChatLinks(AttributedString(text))
        for run in linked.runs where run.link != nil {
            linked[run.range].foregroundColor = Tokens.link
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
    @Environment(AppModel.self) private var model
    let role: RoleDefinition?
    let name: String
    let date: Date
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RobotFace(kind: role.map { RobotFace.Kind(icon: $0.icon) } ?? .lead, size: 20)
                Text(name).fontWeight(.semibold).foregroundStyle(Tokens.text)
                if let modelName = role?.model.modelTitle {
                    Text("· \(modelName)").foregroundStyle(Tokens.text2)
                }
                Text("· \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(Tokens.text3)
            }
            .font(.system(size: 13))
            .help(date.formatted(date: .abbreviated, time: .shortened))
            content
                .font(.system(size: 14.5))
                .lineSpacing(5)
                .foregroundStyle(Tokens.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RunCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let run: Run
    let workflow: WorkflowDefinition?
    let timeline: RunTimeline?
    let agentCount: Int

    var body: some View {
        let step = run.isActive ? workspace.currentStepTitle(of: run) : nil
        let meta = [
            workflow?.displayName, step, agentCount > 0 ? "\(agentCount) agent\(agentCount == 1 ? "" : "s")" : nil,
            run.costUSD.formatted(.currency(code: "USD")),
            run.elapsedDescription,
        ].compactMap(\.self)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusDot(workspace.statusColor(of: run), size: 8)
                Text(run.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(workspace.statusLabel(of: run))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(workspace.statusColor(of: run))
                Button("Details") { workspace.openRunDetail(run) }
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
    @Environment(DaemonWorkspace.self) private var workspace
    let run: Run
    @State private var isConfirmingCancel = false

    var body: some View {
        let hold = run.id.flatMap { workspace.connection.holds[$0] }
        let canRetry = hold.map { [.stepFailed, .timedOut].contains($0.reason) } == true
        HStack(spacing: 8) {
            if run.status == .running || run.status == .pending {
                Button {
                    workspace.pauseRun(run)
                } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Stop after interrupting the current step; resume later")
            } else if [.paused, .interrupted].contains(run.status) {
                Button {
                    workspace.resumeRun(run)
                } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Continue the run from where it stopped")
            }
            if canRetry {
                Button {
                    workspace.retryStep(run)
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
                workspace.cancelRun(run)
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Agents stop and open questions are dismissed. Branches and worktrees stay.")
        }
    }
}

private struct FinalStateCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let run: Run
    let reload: () -> Void
    @State private var isChoosingMergeMethod = false
    @State private var isMerging = false
    @State private var isPushing = false
    @State private var ahead: Int?

    var body: some View {
        let color = workspace.statusColor(of: run)
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
            if canPush, let ahead, ahead > 0 {
                Text("\(baseName) is \(ahead) commit\(ahead == 1 ? "" : "s") ahead of origin")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text2)
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
                        Text("Saturn merges \(delivery) into \(baseName) on this Mac and deletes \(delivery). You can push \(baseName) afterwards.")
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
                if run.mergedAt != nil, let chat = workspace.requestTask(for: run), !chat.isClosed, let project = workspace.project(withID: run.projectId) {
                    Button(run.pushedAt != nil ? "Close chat as done" : "Close chat") {
                        Task { await workspace.closeRequest(chat, as: .done, in: project) }
                    }
                    .buttonStyle(SecondaryPillStyle())
                }
                if run.status == .failed {
                    Button {
                        workspace.retryStep(run)
                        reload()
                    } label: { Label("Retry Step", systemImage: "arrow.clockwise") }
                        .buttonStyle(.pill)
                        .help("Run the failed step again")
                }
            }
        }
        .task(id: "\(run.mergedAt?.timeIntervalSince1970 ?? 0)-\(run.pushedAt?.timeIntervalSince1970 ?? 0)") {
            ahead = canPush ? await workspace.commitsAhead(of: run) : nil
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
            await workspace.pushRun(run, baseName: baseName)
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
            await workspace.mergeRun(run, method: method)
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
        default: workspace.statusLabel(of: run)
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
