import Foundation

public enum ChatReaderError: Error, LocalizedError, Equatable {
    case unknownRequest(Int64)
    case unknownMessage(Int64, requestID: Int64)
    case unknownRun(Int64, requestID: Int64, runs: [Int64])
    case unknownAgent(String, requestID: Int64, agents: [String])
    case missingTranscript(agent: String, id: Int64)

    public var errorDescription: String? {
        switch self {
        case .unknownRequest(let id):
            "No request chat with id \(id); it may have been deleted."
        case .unknownMessage(let id, let requestID):
            "Message \(id) isn’t in request chat \(requestID); it may have been deleted. Call again without message_id to read the chat."
        case .unknownRun(let id, let requestID, let runs):
            "Run \(id) doesn’t belong to request \(requestID). "
                + (runs.isEmpty ? "This request has no runs." : "Its runs: \(runs.map(String.init).joined(separator: ", ")).")
        case .unknownAgent(let name, let requestID, let agents):
            "No agent “\(name)” in request \(requestID). "
                + (agents.isEmpty ? "This request has no agents." : "Its agents: \(agents.joined(separator: ", ")).")
        case .missingTranscript(let agent, let id):
            "\(agent) (id \(id)) has no transcript yet."
        }
    }
}

public struct ChatReader {
    public static let defaultLimit = 50
    public static let maxCharacters = 40_000
    static let toolTextLimit = 2_000
    static let headerTextLimit = 4_000
    static let contextBeforeReference = 2
    static let referenceStart = ">>> REFERENCED MESSAGE <<<"
    static let referenceEnd = ">>> END OF REFERENCED MESSAGE <<<"

    public let database: AppDatabase
    public let paths: AppPaths

    public init(database: AppDatabase, paths: AppPaths) {
        self.database = database
        self.paths = paths
    }

    public func read(_ request: ChatReadRequest) throws -> String {
        guard let task = try database.task(id: request.requestID), let taskID = task.id else {
            throw ChatReaderError.unknownRequest(request.requestID)
        }
        let messages = try database.leadMessages(taskId: taskID)
        if let messageID = request.messageID, !messages.contains(where: { $0.id == messageID }) {
            throw ChatReaderError.unknownMessage(messageID, requestID: taskID)
        }
        let text = switch request.section {
        case .overview: try overview(task, taskID: taskID, messages: messages, request: request)
        case .messages: messagesSection(taskID: taskID, messages: messages, request: request)
        case .run: try runSection(taskID: taskID, request: request)
        case .transcript: try transcriptSection(taskID: taskID, request: request)
        }
        return Self.capped(text)
    }

    private func overview(_ task: ProjectTask, taskID: Int64, messages: [LeadMessage], request: ChatReadRequest) throws -> String {
        var lines = ["Request chat \(taskID): \(task.title)"]
        if let project = try database.project(id: task.projectId) {
            lines.append("Project: \(project.name) (\(project.path))")
        } else {
            lines.append("Project: deleted (id \(task.projectId))")
        }
        lines.append("Source: \(task.source.rawValue)" + (task.sourceURL.map { " · \($0)" } ?? ""))
        let closing = task.closedAt.map { "closed as \(task.closeReason?.title ?? "closed") at \(Self.timestamp($0))" } ?? "open"
        lines.append("Status: \(task.status.rawValue) · \(closing)")
        lines.append("Created \(Self.timestamp(task.createdAt)) · updated \(Self.timestamp(task.updatedAt))")
        if let messageID = request.messageID { lines.append("Referenced message: \(messageID), marked \(Self.referenceStart) below.") }
        if !task.body.isEmpty { lines.append("\nRequest:\n" + Self.truncated(task.body, to: Self.headerTextLimit)) }

        let agents = try database.requestAgents(taskId: taskID)
        if let lead = agents.first(where: { $0.taskId == taskID }) { lines.append("\nLead: \(Self.describe(lead))") }
        let runs = try database.runs(taskId: taskID)
        lines.append("\nRuns (\(runs.count)):")
        if runs.isEmpty { lines.append("(none)") }
        for run in runs {
            lines.append(runLine(run, agents: agents.filter { $0.runId == run.id && run.id != nil }))
        }

        let header = lines.joined(separator: "\n")
        let hints = """
            How to read more with read_chat:
            - section=messages pages every message (offset, limit).
            - section=run with run_id for a run's steps, outcomes, verdicts and costs.
            - section=transcript with agent (name or id) for that agent's transcript with tool calls.
            """
        let budget = max(2_000, Self.maxCharacters - header.count - hints.count - 400)
        let page = messagePage(messages: messages, request: request, budget: budget, continuation: ", section=overview")
        return [header, "Messages:\n" + page, hints].joined(separator: "\n\n")
    }

    private func messagesSection(taskID: Int64, messages: [LeadMessage], request: ChatReadRequest) -> String {
        var header = "Messages in request chat \(taskID)"
        if let messageID = request.messageID { header += "; message \(messageID) is marked \(Self.referenceStart)" }
        let budget = Self.maxCharacters - header.count - 400
        return header + "\n\n" + messagePage(messages: messages, request: request, budget: budget, continuation: ", section=messages")
    }

    private func messagePage(messages: [LeadMessage], request: ChatReadRequest, budget: Int, continuation: String) -> String {
        guard !messages.isEmpty else { return "(no messages)" }
        let items = messages.map { render($0, referenced: $0.id != nil && $0.id == request.messageID) }
        let limit = Self.limit(request)
        let anchor = request.messageID.flatMap { id in messages.firstIndex { $0.id == id } }
        let start = request.offset ?? anchor.map { Self.start(around: $0, items: items, limit: limit, budget: budget) } ?? 0
        let messageArgument = request.messageID.map { ", message_id=\($0)" } ?? ""
        return Self.page(items, start: start, limit: limit, budget: budget, noun: "messages", continuation: continuation + messageArgument)
    }

    private func render(_ message: LeadMessage, referenced: Bool) -> String {
        var fields = ["[message \(message.id.map(String.init) ?? "?")] \(message.kind.rawValue)", Self.timestamp(message.createdAt)]
        if let workflow = message.workflow { fields.append("workflow \(workflow)") }
        if let status = message.status { fields.append("status \(status.rawValue)") }
        if let runId = message.runId { fields.append("run \(runId)") }
        var lines = [fields.joined(separator: " · ")]
        if let title = message.title { lines.append("Title: \(title)") }
        if !message.text.isEmpty { lines.append(message.text) }
        if !message.storedAttachments.isEmpty {
            lines.append("Attachments: " + message.storedAttachments.map(\.label).joined(separator: ", "))
        }
        if referenced { lines = [Self.referenceStart] + lines + [Self.referenceEnd] }
        return lines.joined(separator: "\n")
    }

    private func runLine(_ run: Run, agents: [Agent]) -> String {
        var fields = ["- run \(run.id.map(String.init) ?? "?")", "workflow \(run.workflow)", "status \(run.status.rawValue)"]
        fields.append("step \(run.currentStep ?? "none")")
        fields.append("started \(Self.timestamp(run.startedAt))")
        fields.append("ended \(run.endedAt.map(Self.timestamp) ?? "not yet")")
        if let url = run.pullRequestURL { fields.append("PR \(url)") }
        var lines = [fields.joined(separator: " · ")]
        if !run.title.isEmpty { lines.append("  Title: \(run.title)") }
        lines.append("  Agents: " + (agents.isEmpty ? "none" : agents.map(Self.describe).joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    private func requireRun(_ runID: Int64, taskID: Int64) throws -> Run {
        guard let run = try database.run(id: runID), run.taskId == taskID else {
            throw ChatReaderError.unknownRun(runID, requestID: taskID, runs: try database.runs(taskId: taskID).compactMap(\.id))
        }
        return run
    }

    private func runSection(taskID: Int64, request: ChatReadRequest) throws -> String {
        guard let runID = request.runID else { throw HandoffError.missing("run_id") }
        let run = try requireRun(runID, taskID: taskID)
        let workflow = (try? YAMLWorkflow.decode(run.workflowSnapshot)) ?? WorkflowDefinition(id: run.workflow, name: run.workflow, steps: [])
        let agents = try database.agents(inRun: runID)
        let history = RunHistory(workflow: workflow, steps: try database.runSteps(runId: runID), agents: agents)
        let names = Dictionary(agents.compactMap { agent in agent.id.map { ($0, agent.name) } }, uniquingKeysWith: { first, _ in first })

        var lines = ["Run \(runID) of request \(taskID)" + (run.title.isEmpty ? "" : ": \(run.title)")]
        var summary = ["Workflow \(run.workflow)\(run.workflowVersion.map { " v\($0)" } ?? "")", "status \(run.status.rawValue)"]
        if let outcome = run.outcome { summary.append("outcome \(outcome)") }
        summary.append("cost \(Self.cost(run.costUSD))")
        lines.append(summary.joined(separator: " · "))
        lines.append("Started \(Self.timestamp(run.startedAt)) · ended \(run.endedAt.map(Self.timestamp) ?? "not yet")")
        if let step = run.currentStep { lines.append("Current step: \(step)") }
        if let url = run.pullRequestURL { lines.append("PR: \(url)") }
        if let branch = run.deliveryBranch { lines.append("Delivery branch: \(branch)" + (run.baseBranch.map { " into \($0)" } ?? "")) }
        if let error = run.lastError { lines.append("Last error: \(error)") }
        lines.append("Agents: " + (agents.isEmpty ? "none" : agents.map(Self.describe).joined(separator: ", ")))
        if let brief = run.brief, !brief.isEmpty { lines.append("Brief:\n" + Self.truncated(brief, to: Self.headerTextLimit)) }
        let header = lines.joined(separator: "\n")

        let items = history.entries.enumerated().map { index, entry in render(entry, number: index + 1, names: names) }
        let budget = max(2_000, Self.maxCharacters - header.count - 400)
        let body = items.isEmpty
            ? "(no steps yet)"
            : Self.page(items, start: request.offset ?? 0, limit: Self.limit(request), budget: budget, noun: "steps", continuation: ", section=run, run_id=\(runID)")
        return header + "\n\nSteps:\n" + body
    }

    private func render(_ entry: RunHistory.Entry, number: Int, names: [Int64: String]) -> String {
        var fields = ["[step \(number)] \(entry.title) (\(entry.stepId)\(entry.type.map { ", \($0.rawValue)" } ?? ""))"]
        fields.append("iteration \(entry.iteration)")
        fields.append(entry.status.rawValue)
        if let outcome = entry.outcome { fields.append("outcome \(outcome)") }
        fields.append(Self.cost(entry.costUSD))
        fields.append("\(Self.timestamp(entry.startedAt)) to \(entry.endedAt.map(Self.timestamp) ?? "now")")
        var lines = [fields.joined(separator: " · ")]
        if let role = entry.role { lines.append("Role: \(role)") }
        if let feedback = entry.feedback { lines.append("Feedback from \(feedback.fromStep): \(feedback.summary)") }
        if entry.attempts.count > 1 {
            for attempt in entry.attempts {
                lines.append("Attempt \(attempt.number): \(attempt.status.rawValue)" + (attempt.outcome.map { " · \($0)" } ?? "") + (attempt.summary.map { " · \($0)" } ?? ""))
            }
        }
        if let plan = entry.handoff.plan {
            lines.append("Plan: \(plan.summary)")
            lines += plan.tasks.map { "  - \($0.title) (\($0.role)\($0.count > 1 ? " ×\($0.count)" : ""))" }
            if let spec = plan.spec { lines.append("Spec:\n" + spec.markdown) }
        }
        if let verdict = entry.handoff.verdict {
            lines.append("Verdict: \(verdict.outcome) · \(verdict.summary)")
            lines += verdict.issues.map { issue in
                let context = [issue.agent, issue.file].compactMap(\.self)
                return "  - \(issue.description)" + (context.isEmpty ? "" : " (\(context.joined(separator: ", ")))")
            }
        }
        if let result = entry.handoff.result, !result.isEmpty { lines.append("Result: \(result)") }
        if !entry.handoff.taskResults.isEmpty {
            lines.append("Task results:")
            lines += entry.handoff.taskResults.map { "  - \($0.agentName ?? $0.planTaskId): \($0.summary)" }
        }
        if !entry.agentIDs.isEmpty {
            lines.append("Agents: " + entry.agentIDs.map { "\(names[$0] ?? "agent") (id \($0))" }.joined(separator: ", "))
        }
        if let hop = entry.hop {
            var next = "Next: \(hop.toTitle)" + (hop.outcome.map { " on \($0)" } ?? "")
            if hop.isLoopBack { next += ", loop \(hop.loopNumber)" + (hop.maxLoops.map { " of \($0)" } ?? "") }
            lines.append(next)
        }
        return lines.joined(separator: "\n")
    }

    private func transcriptSection(taskID: Int64, request: ChatReadRequest) throws -> String {
        guard let name = request.agent else { throw HandoffError.missing("agent") }
        var candidates = try database.requestAgents(taskId: taskID)
        if let runID = request.runID {
            _ = try requireRun(runID, taskID: taskID)
            candidates = candidates.filter { $0.runId == runID || $0.taskId == taskID }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let agent = candidates.first(where: { $0.id.map(String.init) == trimmed })
            ?? candidates.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }),
            let agentID = agent.id else {
            throw ChatReaderError.unknownAgent(name, requestID: taskID, agents: candidates.map(Self.describe))
        }
        let url = paths.transcript(agentID)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ChatReaderError.missingTranscript(agent: agent.name, id: agentID)
        }
        let transcript = Transcript(lines: contents.split(separator: "\n").map(String.init))
        let items = transcript.entries.compactMap(Self.render).enumerated().map { "[entry \($0.offset)] \($0.element)" }

        var header = "Transcript of \(Self.describe(agent)) in request \(taskID)"
        if let runID = agent.runId { header += ", run \(runID)" } else if agent.taskId == taskID { header += ", the request’s lead" }
        let budget = max(2_000, Self.maxCharacters - header.count - 400)
        let continuation = ", section=transcript, agent=\(agentID)" + (request.runID.map { ", run_id=\($0)" } ?? "")
        let body = items.isEmpty
            ? "(empty)"
            : Self.page(items, start: request.offset ?? 0, limit: Self.limit(request), budget: budget, noun: "entries", continuation: continuation)
        return header + "\n\n" + body
    }

    private static func render(_ entry: TranscriptEntry) -> String? {
        switch entry.content {
        case .user(let text):
            return "user:\n\(text)"
        case .assistant(let text):
            return "assistant:\n\(text)"
        case .thinking:
            return nil
        case .tool(let tool):
            let input = tool.input == .null ? "" : " " + truncated(tool.input.compactJSON, to: toolTextLimit)
            var lines = ["tool call \(tool.name)\(input)"]
            if let result = tool.result {
                lines.append("tool result\(tool.isError ? " (error)" : ""): " + truncated(result, to: toolTextLimit))
            }
            return lines.joined(separator: "\n")
        case .notice(let notice, let detail):
            return "notice: \(notice.rawValue)" + (detail.map { " · \($0)" } ?? "")
        case .interrupted:
            return "interrupted"
        case .turnFinished(let result):
            return "turn finished" + (result.isError ? " with an error" : "") + " · \(cost(result.totalCostUSD))"
        }
    }

    static func limit(_ request: ChatReadRequest) -> Int {
        max(1, request.limit ?? defaultLimit)
    }

    static func start(around anchor: Int, items: [String], limit: Int, budget: Int) -> Int {
        let leading = items[...anchor].reduce(0) { $0 + $1.count + 2 }
        if anchor < limit, leading <= budget { return 0 }
        var start = anchor
        var used = items[anchor].count + 2
        while start > 0, anchor - start < contextBeforeReference, anchor - start + 1 < limit, used + items[start - 1].count + 2 <= budget {
            start -= 1
            used += items[start].count + 2
        }
        return start
    }

    static func page(_ items: [String], start: Int, limit: Int, budget: Int, noun: String, continuation: String) -> String {
        let start = min(max(0, start), items.count)
        var end = start
        var used = 0
        var shown: [String] = []
        while end < items.count, end - start < limit {
            let item = items[end]
            if used + item.count + 2 > budget {
                if shown.isEmpty {
                    shown.append(truncated(item, to: max(500, budget - 200)))
                    end += 1
                }
                break
            }
            shown.append(item)
            used += item.count + 2
            end += 1
        }
        var footer: [String] = []
        if shown.isEmpty {
            footer.append("No \(noun) at offset \(start); there are \(items.count).")
        } else {
            footer.append("Showing \(noun) \(start)–\(end - 1) of \(items.count) (offsets start at 0).")
        }
        if end < items.count { footer.append("More: call again with offset=\(end)\(continuation).") }
        if start > 0 { footer.append("Earlier \(noun) start at offset=0.") }
        return (shown + [footer.joined(separator: " ")]).joined(separator: "\n\n")
    }

    static func describe(_ agent: Agent) -> String {
        "\(agent.name) (\(agent.role), id \(agent.id.map(String.init) ?? "?"))"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… [\(text.count - limit) more characters]"
    }

    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters - 60)) + "\n… [output cut at \(maxCharacters) characters]"
    }
}
