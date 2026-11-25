#if DEBUG
import CryptoKit
import Foundation

final class DebugTrace: @unchecked Sendable {
    static let defaultSizeLimit: Int64 = 1 << 30
    static let toolResultLimit = 2048
    static let chatTextLimit = 8192
    static let inlineLimit = 2048
    static let previewLength = 500
    static let hashLength = 16
    static let systemPromptFlag = "--append-system-prompt"

    let directory: URL
    let sizeLimit: Int64
    private let retentionInterval: TimeInterval
    private let retentionBytes: Int
    private let promptTouchInterval: TimeInterval = 600
    private let runTitle: @Sendable (Int64) -> String?
    private let queue = DispatchQueue(label: "app.saturn.debug-trace", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var runFolders: [Int64: URL] = [:]
    private var turns: [Int64: DebugTurnStats] = [:]
    private var agentSteps: [Int64: (stepId: String, runStepId: Int64?)] = [:]
    private var questionsAskedAt: [Int64: Date] = [:]
    private var promptsTouchedAt: [String: Date] = [:]
    private var bytesSinceRetention = 0
    private var lastRetention = Date.distantPast
    private var recentFolders: Set<URL> = []

    init(
        paths: AppPaths,
        sizeLimit: Int64 = defaultSizeLimit,
        retentionInterval: TimeInterval = 60,
        retentionBytes: Int = 8 << 20,
        runTitle: @escaping @Sendable (Int64) -> String? = { _ in nil }
    ) {
        self.directory = paths.debugLogsDirectory
        self.sizeLimit = sizeLimit
        self.retentionInterval = retentionInterval
        self.retentionBytes = retentionBytes
        self.runTitle = runTitle
        queue.async { [self] in
            writeReadme()
            enforceRetention(at: .now)
        }
    }

    var runsDirectory: URL { directory.appending(path: "runs", directoryHint: .isDirectory) }
    var chatsDirectory: URL { directory.appending(path: "chats", directoryHint: .isDirectory) }
    var promptsDirectory: URL { directory.appending(path: "prompts", directoryHint: .isDirectory) }

    func flush() {
        queue.sync {}
    }

    @discardableResult
    func storePrompt(_ text: String) -> String {
        let hash = Self.hash(text)
        queue.async { [self] in writePrompt(text, hash: hash, at: .now) }
        return hash
    }

    func launched(_ launch: ClaudeLaunch, turn: AgentTurn, agent: Agent, at date: Date = .now) {
        let arguments = launch.arguments
        let environmentNames = launch.processEnvironment.keys.sorted()
        let sentLine = ClaudeEvent.userLine(turn.text, images: turn.images, includingImageData: false)
        queue.async { [self] in
            let systemHash = writePrompt(launch.systemPrompt, hash: Self.hash(launch.systemPrompt), at: date)
            let turnHash = writePrompt(turn.text, hash: Self.hash(turn.text), at: date)
            turns[agent.id ?? -1] = DebugTurnStats(startedAt: date)
            var fields: DebugFields = [
                "role": JSONValue(agent.role),
                "model": JSONValue(launch.model),
                "readOnly": JSONValue(launch.readOnly),
                "cwd": JSONValue(launch.workingDirectory.path),
                "worktree": JSONValue(agent.worktreePath),
                "branch": JSONValue(agent.branch),
                "executable": JSONValue(launch.executable.path),
                "arguments": JSONValue(Self.replacingSystemPrompt(in: arguments, hash: systemHash)),
                "extraAllowedTools": JSONValue(launch.extraAllowedTools),
                "additionalDirectories": JSONValue(launch.additionalDirectories.map(\.path)),
                "envVarNames": JSONValue(environmentNames),
                "systemPromptHash": JSONValue(systemHash),
                "turnPromptHash": JSONValue(turnHash),
                "imageCount": JSONValue(turn.images.count),
            ]
            switch launch.session {
            case .new(let id): fields["session"] = .object(["mode": JSONValue("new"), "id": JSONValue(id)])
            case .resume(let id): fields["session"] = .object(["mode": JSONValue("resume"), "id": JSONValue(id)])
            }
            writeAgent("launch", agent: agent, at: date, fields: fields)
            writeRaw(sentLine, direction: "stdin", agent: agent, at: date)
        }
    }

    func received(_ line: String, agent: Agent, at date: Date = .now) {
        queue.async { [self] in
            let json = writeRaw(line, direction: "stdout", agent: agent, at: date)
            guard let json else { return }
            turns[agent.id ?? -1, default: DebugTurnStats()].ingest(json)
            if json["type"]?.string == "system", json["subtype"]?.string == "init" {
                writeAgent("session_init", agent: agent, at: date, fields: [
                    "sessionId": json["session_id"] ?? .null,
                    "claudeCodeVersion": json["claude_code_version"] ?? .null,
                    "apiKeySource": json["apiKeySource"] ?? .null,
                    "model": json["model"] ?? .null,
                    "cwd": json["cwd"] ?? .null,
                    "permissionMode": json["permissionMode"] ?? .null,
                    "tools": json["tools"] ?? .null,
                    "mcpServers": json["mcp_servers"] ?? .null,
                    "slashCommands": json["slash_commands"] ?? .null,
                ])
            }
        }
    }

    func turnCompleted(_ result: TurnResult, costUSD: Double, agent: Agent, at date: Date = .now) {
        queue.async { [self] in
            let id = agent.id ?? -1
            let stats = turns.removeValue(forKey: id) ?? DebugTurnStats()
            var fields = stats.summary(result: result, costUSD: costUSD, endedAt: date)
            fields["processTotalCostUSD"] = JSONValue(result.totalCostUSD)
            writeAgent("turn_summary", agent: agent, at: date, fields: fields)
        }
    }

    func lifecycle(_ event: String, detail: String? = nil, agent: Agent, at date: Date = .now) {
        queue.async { [self] in
            var fields: DebugFields = ["event": JSONValue(event), "status": JSONValue(agent.status.rawValue)]
            if let detail { fields["detail"] = JSONValue(detail) }
            writeAgent("lifecycle", agent: agent, at: date, fields: fields)
        }
    }

    func processExited(code: Int32, standardError: String, agent: Agent, at date: Date = .now) {
        queue.async { [self] in
            writeAgent("process_exited", agent: agent, at: date, fields: [
                "exitCode": JSONValue(Int(code)),
                "stderr": JSONValue(DebugText.preview(standardError, limit: Self.toolResultLimit)),
                "stderrLength": JSONValue(standardError.count),
            ])
        }
    }

    func chatMessage(_ text: String, direction: String, chat: String, agent: Agent, at date: Date = .now) {
        queue.async { [self] in
            var fields: DebugFields = ["direction": JSONValue(direction), "chat": JSONValue(chat)]
            DebugText.truncatedField(text, limit: Self.chatTextLimit, into: &fields, key: "text")
            writeAgent("chat_message", agent: agent, at: date, fields: fields)
        }
    }

    func assign(_ agent: Agent, toStep stepId: String, runStepId: Int64?, runTitle title: String, message: String?, at date: Date = .now) {
        queue.async { [self] in
            guard let id = agent.id else { return }
            agentSteps[id] = (stepId, runStepId)
            guard let runId = agent.runId else { return }
            _ = runFolder(runId, title: title)
            var fields: DebugFields = [
                "agentName": JSONValue(agent.name),
                "role": JSONValue(agent.role),
                "model": JSONValue(agent.model),
                "readOnly": JSONValue(agent.readOnly),
                "branch": JSONValue(agent.branch),
                "agentLog": JSONValue(relativePath(of: agentFile(agent).file)),
            ]
            if let message {
                fields["messageHash"] = JSONValue(writePrompt(message, hash: Self.hash(message), at: date))
                fields["messageLength"] = JSONValue(message.count)
            }
            writeRun("agent_assigned", runId: runId, title: title, stepId: stepId, runStepId: runStepId, agentId: id, at: date, fields: fields)
        }
    }

    func handoff(_ message: HandoffMessage, from agent: Agent, at date: Date = .now) {
        let (tool, payload) = Self.describe(message)
        queue.async { [self] in
            let fields: DebugFields = ["tool": JSONValue(tool), "agentName": JSONValue(agent.name), "payload": payload]
            if let runId = agent.runId, let id = agent.id {
                writeRun("handoff", runId: runId, title: nil, stepId: agentSteps[id]?.stepId, runStepId: agentSteps[id]?.runStepId, agentId: id, at: date, fields: fields)
            } else {
                writeAgent("handoff", agent: agent, at: date, fields: fields)
            }
        }
    }

    static func describe(_ message: HandoffMessage) -> (tool: String, payload: JSONValue) {
        switch message {
        case .plan(let plan): (HandoffTool.submitPlan.rawValue, JSONValue(encoding: plan) ?? .null)
        case .verdict(let verdict): (HandoffTool.submitVerdict.rawValue, JSONValue(encoding: verdict) ?? .null)
        case .pin(let draft): (HandoffTool.createPin.rawValue, JSONValue(encoding: draft) ?? .null)
        case .evidence(let draft): (HandoffTool.attachEvidence.rawValue, JSONValue(encoding: draft) ?? .null)
        case .question(let body, let questions): (HandoffTool.askHuman.rawValue, .object(["question": JSONValue(body), "questions": JSONValue(encoding: questions) ?? .null]))
        case .result(let summary): (HandoffTool.submitResult.rawValue, .object(["summary": JSONValue(summary)]))
        case .proposal(let proposal): (HandoffTool.proposeRun.rawValue, JSONValue(encoding: proposal) ?? .null)
        case .agentMessage(let name, let text): (HandoffTool.messageAgent.rawValue, .object(["agent": JSONValue(name), "message": JSONValue(text)]))
        case .listAgents: (HandoffTool.listAgents.rawValue, .null)
        case .spawnAgent(let request): (HandoffTool.spawnAgent.rawValue, JSONValue(encoding: request) ?? .null)
        case .stopAgent(let name): (HandoffTool.stopAgent.rawValue, .object(["agent": JSONValue(name)]))
        case .deleteAgent(let name, let deleteBranch): (HandoffTool.deleteAgent.rawValue, .object(["agent": JSONValue(name), "deleteBranch": JSONValue(deleteBranch)]))
        case .openWorktree: (HandoffTool.openWorktree.rawValue, .null)
        case .readChat(let request): (HandoffTool.readChat.rawValue, .object([
            "requestId": JSONValue(request.requestID), "messageId": JSONValue(request.messageID), "section": JSONValue(request.section.rawValue),
            "runId": JSONValue(request.runID), "agent": JSONValue(request.agent),
            "offset": request.offset.map { JSONValue($0) } ?? .null, "limit": request.limit.map { JSONValue($0) } ?? .null,
        ]))
        case .draftSpec(let request): (HandoffTool.draftSpec.rawValue, JSONValue(encoding: request) ?? .null)
        case .setupProposal(let proposal): (HandoffTool.proposeSetup.rawValue, JSONValue(encoding: proposal) ?? .null)
        case .replySpec(let text): (HandoffTool.replySpec.rawValue, .object(["text": JSONValue(text)]))
        case .setChatStatus(let status, let reason): (HandoffTool.setChatStatus.rawValue, .object(["status": JSONValue(status.rawValue), "reason": JSONValue(reason)]))
        }
    }

    func runEvent(
        _ type: String, runId: Int64, title: String, stepId: String? = nil, runStepId: Int64? = nil, agentId: Int64? = nil,
        fields: DebugFields = [:], at date: Date = .now
    ) {
        queue.async { [self] in
            writeRun(type, runId: runId, title: title, stepId: stepId, runStepId: runStepId, agentId: agentId, at: date, fields: fields)
        }
    }

    func questionAsked(by agent: Agent, routedTo target: String, body: String, questions: [HumanQuestion], at date: Date = .now) {
        queue.async { [self] in
            guard let id = agent.id else { return }
            questionsAskedAt[id] = date
            let fields: DebugFields = [
                "agentName": JSONValue(agent.name),
                "target": JSONValue(target),
                "body": JSONValue(body),
                "questions": JSONValue(encoding: questions) ?? .null,
            ]
            if let runId = agent.runId {
                writeRun("question_relayed", runId: runId, title: nil, stepId: agentSteps[id]?.stepId, runStepId: agentSteps[id]?.runStepId, agentId: id, at: date, fields: fields)
            } else {
                writeAgent("question_relayed", agent: agent, at: date, fields: fields)
            }
        }
    }

    func questionAnswered(for agent: Agent, answer: String?, via source: String, at date: Date = .now) {
        queue.async { [self] in
            guard let id = agent.id else { return }
            var fields: DebugFields = ["agentName": JSONValue(agent.name), "via": JSONValue(source)]
            if let asked = questionsAskedAt.removeValue(forKey: id) {
                fields["waitMS"] = JSONValue(Int(date.timeIntervalSince(asked) * 1000))
            }
            if let answer { DebugText.truncatedField(answer, limit: Self.chatTextLimit, into: &fields, key: "answer") }
            if let runId = agent.runId {
                writeRun("question_answered", runId: runId, title: nil, stepId: agentSteps[id]?.stepId, runStepId: agentSteps[id]?.runStepId, agentId: id, at: date, fields: fields)
            } else {
                writeAgent("question_answered", agent: agent, at: date, fields: fields)
            }
        }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(hashLength).description
    }

    static func replacingSystemPrompt(in arguments: [String], hash: String) -> [String] {
        var replaced = arguments
        if let index = arguments.firstIndex(of: systemPromptFlag), index + 1 < arguments.count {
            replaced[index + 1] = "prompt:\(hash)"
        }
        return replaced
    }

    private func writeAgent(_ type: String, agent: Agent, at date: Date, fields: DebugFields) {
        var event = fields
        event["type"] = JSONValue(type)
        event["at"] = JSONValue(formatter.string(from: date))
        event["agentId"] = JSONValue(agent.id)
        event["agentName"] = JSONValue(agent.name)
        if let runId = agent.runId { event["runId"] = JSONValue(runId) }
        if let taskId = agent.taskId { event["taskId"] = JSONValue(taskId) }
        if let id = agent.id, let step = agentSteps[id], agent.runId != nil {
            event["stepId"] = JSONValue(step.stepId)
            event["runStepId"] = JSONValue(step.runStepId)
        }
        let location = agentFile(agent)
        append(event, to: location.file, folder: location.folder, at: date)
    }

    private func writeRun(
        _ type: String, runId: Int64, title: String?, stepId: String?, runStepId: Int64?, agentId: Int64?, at date: Date, fields: DebugFields
    ) {
        var event = fields
        event["type"] = JSONValue(type)
        event["at"] = JSONValue(formatter.string(from: date))
        event["runId"] = JSONValue(runId)
        if let stepId { event["stepId"] = JSONValue(stepId) }
        if let runStepId { event["runStepId"] = JSONValue(runStepId) }
        if let agentId { event["agentId"] = JSONValue(agentId) }
        let folder = runFolder(runId, title: title)
        append(event, to: folder.appending(path: "trace.jsonl"), folder: folder, at: date)
    }

    @discardableResult
    private func writeRaw(_ line: String, direction: String, agent: Agent, at date: Date) -> JSONValue? {
        let json = JSONValue.parse(line)
        var fields: DebugFields = [
            "direction": JSONValue(direction),
            "transcribed": JSONValue(direction == "stdin" || !ClaudeEvent.parse(line: line).isEmpty),
        ]
        if let json, json.object != nil {
            fields["line"] = json["type"]?.string == "user" ? DebugText.truncatingStrings(in: json, over: Self.toolResultLimit) : json
        } else {
            DebugText.truncatedField(line, limit: Self.toolResultLimit, into: &fields, key: "text")
        }
        writeAgent("raw", agent: agent, at: date, fields: fields)
        return json
    }

    @discardableResult
    private func writePrompt(_ text: String, hash: String, at date: Date) -> String {
        if let touched = promptsTouchedAt[hash], date.timeIntervalSince(touched) < promptTouchInterval { return hash }
        let file = promptsDirectory.appending(path: "\(hash).md")
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        } else {
            try? FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: file, options: .atomic)
            bytesSinceRetention += text.utf8.count
        }
        promptsTouchedAt[hash] = date
        return hash
    }

    private func agentFile(_ agent: Agent) -> (file: URL, folder: URL) {
        let id = agent.id ?? -1
        let name = Self.slug(agent.name, fallback: "agent")
        if let runId = agent.runId {
            let folder = runFolder(runId, title: nil)
            return (folder.appending(path: "agents/\(id)-\(name).jsonl"), folder)
        }
        let folder = chatsDirectory.appending(path: "\(id)-\(name)", directoryHint: .isDirectory)
        return (folder.appending(path: "agent.jsonl"), folder)
    }

    private func runFolder(_ runId: Int64, title: String?) -> URL {
        if let folder = runFolders[runId] { return folder }
        let prefix = "\(runId)-"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: runsDirectory.path))?
            .first { $0 == "\(runId)" || $0.hasPrefix(prefix) }
        let name = existing ?? {
            let slug = Self.slug(title ?? runTitle(runId) ?? "", fallback: "")
            return slug.isEmpty ? "\(runId)" : prefix + slug
        }()
        let folder = runsDirectory.appending(path: name, directoryHint: .isDirectory)
        runFolders[runId] = folder
        return folder
    }

    private func append(_ event: DebugFields, to file: URL, folder: URL, at date: Date) {
        let data = Data((JSONValue.object(event).compactJSON + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
        bytesSinceRetention += data.count
        recentFolders.insert(folder)
        if bytesSinceRetention >= retentionBytes || date.timeIntervalSince(lastRetention) >= retentionInterval {
            enforceRetention(at: date, current: folder)
        }
    }

    private func enforceRetention(at date: Date, current: URL? = nil) {
        DebugRetention(root: directory, limit: sizeLimit, promptTouchInterval: promptTouchInterval).enforce(protecting: recentFolders)
        bytesSinceRetention = 0
        lastRetention = date
        recentFolders = current.map { [$0] } ?? []
        promptsTouchedAt = promptsTouchedAt.filter { hash, _ in
            FileManager.default.fileExists(atPath: promptsDirectory.appending(path: "\(hash).md").path)
        }
    }

    private func writeReadme() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "README.md")
        let current = try? String(contentsOf: file, encoding: .utf8)
        guard current != DebugTraceReadme.text else { return }
        try? Data(DebugTraceReadme.text.utf8).write(to: file, options: .atomic)
    }

    private func relativePath(of url: URL) -> String {
        let root = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private static func slug(_ text: String, fallback: String) -> String {
        let slug = Slug.make(text)
        return slug.isEmpty ? fallback : slug
    }
}
#endif
