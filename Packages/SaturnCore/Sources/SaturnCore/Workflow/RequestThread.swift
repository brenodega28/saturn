import Foundation

public struct RequestThread: Sendable, Hashable {
    public enum Item: Sendable, Hashable, Identifiable {
        case request(Chat)
        case message(LeadMessage)
        case runStarted(Run)
        case step(Run, RunTimeline.Entry)
        case answeredQuestion(ChatRequest)
        case runEnded(Run)
        case openQuestion(ChatRequest)
        case hold(Run)
        case notice(ChatRequest)

        public var id: String {
            switch self {
            case .request(let task): "request-\(task.id ?? 0)"
            case .message(let message): "message-\(message.id ?? 0)"
            case .runStarted(let run): "run-\(run.id ?? 0)"
            case .step(_, let entry): "step-\(entry.id)"
            case .answeredQuestion(let item): "answer-\(item.id ?? 0)"
            case .runEnded(let run): "end-\(run.id ?? 0)"
            case .openQuestion(let item): "question-\(item.id ?? 0)"
            case .hold(let run): "hold-\(run.id ?? 0)"
            case .notice(let request): "notice-\(request.id ?? 0)"
            }
        }

        public var isLive: Bool {
            switch self {
            case .openQuestion, .hold: true
            case .notice(let request): request.status == .open
            default: false
            }
        }
    }

    public var items: [Item]

    public init(
        task: Chat,
        messages: [LeadMessage],
        runs: [Run],
        timelines: [Int64: RunTimeline],
        requests: [ChatRequest],
        heldRunIDs: Set<Int64>
    ) {
        let questions = requests.filter { $0.kind == .question }
        let holdRequestIDs = Set(timelines.values.compactMap { $0.holdItem?.id })
        let notices = requests.filter { request in
            request.kind != .question && request.kind != .permission && !holdRequestIDs.contains(request.id ?? -1)
        }
        var dated: [(date: Date, order: Int, item: Item)] = []
        func add(_ date: Date, _ item: Item) { dated.append((date, dated.count, item)) }

        if !task.isOnboarding, !messages.contains(where: { $0.kind == .user }) {
            add(task.createdAt, .request(task))
        }
        var proposalsAwaitingReply: [LeadMessage] = []
        func addProposalsAwaitingReply(at date: Date? = nil) {
            for proposal in proposalsAwaitingReply { add(date ?? proposal.createdAt, .message(proposal)) }
            proposalsAwaitingReply = []
        }
        for message in messages {
            switch message.kind {
            case .proposal:
                proposalsAwaitingReply.append(message)
            case .lead:
                add(message.createdAt, .message(message))
                addProposalsAwaitingReply(at: message.createdAt)
            case .permission:
                continue
            default:
                addProposalsAwaitingReply()
                add(message.createdAt, .message(message))
            }
        }
        addProposalsAwaitingReply()
        for run in runs {
            add(run.startedAt, .runStarted(run))
            for entry in timelines[run.id ?? -1]?.entries ?? [] where entry.status != .running && entry.status != .waitingOnYou {
                add(entry.endedAt ?? entry.startedAt, .step(run, entry))
            }
            if !run.isActive, let ended = run.endedAt {
                add(ended, .runEnded(run))
            }
        }
        for question in questions where question.status != .open {
            add(question.resolvedAt ?? question.createdAt, .answeredQuestion(question))
        }
        for notice in notices where notice.status != .open {
            add(notice.createdAt, .notice(notice))
        }

        var items = dated.sorted { ($0.date, $0.order) < ($1.date, $1.order) }.map(\.item)
        items += questions.filter { $0.status == .open }.sorted { $0.createdAt < $1.createdAt }.map(Item.openQuestion)
        items += runs.filter { run in run.isActive && run.id.map(heldRunIDs.contains) == true }.map(Item.hold)
        items += notices.filter { $0.status == .open }.sorted { $0.createdAt < $1.createdAt }.map(Item.notice)
        self.items = items
    }
}
