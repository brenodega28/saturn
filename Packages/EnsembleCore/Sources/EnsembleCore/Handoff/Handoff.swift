import Foundation

public struct PlanTask: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var details: String
    public var role: String
    public var files: [String]

    public init(id: String = UUID().uuidString, title: String, details: String = "", role: String, files: [String] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.role = role
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case id, title, details, role, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decode(String.self, forKey: .title)
        self.details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        self.role = try container.decode(String.self, forKey: .role)
        self.files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    }
}

public struct PlanSpec: Sendable, Hashable, Codable {
    public var interfaces: [String]
    public var outOfScope: [String]
    public var acceptanceCriteria: [String]
    public var verification: String

    public init(interfaces: [String] = [], outOfScope: [String] = [], acceptanceCriteria: [String] = [], verification: String = "") {
        self.interfaces = interfaces
        self.outOfScope = outOfScope
        self.acceptanceCriteria = acceptanceCriteria
        self.verification = verification
    }

    enum CodingKeys: String, CodingKey {
        case interfaces, verification
        case outOfScope = "out_of_scope"
        case acceptanceCriteria = "acceptance_criteria"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.interfaces = try container.decodeIfPresent([String].self, forKey: .interfaces) ?? []
        self.outOfScope = try container.decodeIfPresent([String].self, forKey: .outOfScope) ?? []
        self.acceptanceCriteria = try container.decodeIfPresent([String].self, forKey: .acceptanceCriteria) ?? []
        self.verification = try container.decodeIfPresent(String.self, forKey: .verification) ?? ""
    }

    public var isEmpty: Bool {
        interfaces.isEmpty && outOfScope.isEmpty && acceptanceCriteria.isEmpty && verification.isEmpty
    }

    public var markdown: String {
        var parts: [String] = []
        if !interfaces.isEmpty { parts.append("Interfaces:\n" + interfaces.map { "- \($0)" }.joined(separator: "\n")) }
        if !acceptanceCriteria.isEmpty { parts.append("Acceptance criteria:\n" + acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")) }
        if !outOfScope.isEmpty { parts.append("Out of scope:\n" + outOfScope.map { "- \($0)" }.joined(separator: "\n")) }
        if !verification.isEmpty { parts.append("Verification: \(verification)") }
        return parts.joined(separator: "\n\n")
    }
}

public struct Plan: Sendable, Hashable, Codable {
    public var summary: String
    public var tasks: [PlanTask]
    public var spec: PlanSpec?

    public init(summary: String, tasks: [PlanTask], spec: PlanSpec? = nil) {
        self.summary = summary
        self.tasks = tasks
        self.spec = spec
    }

    enum CodingKeys: String, CodingKey {
        case summary, tasks, spec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.tasks = try container.decode([PlanTask].self, forKey: .tasks)
        self.spec = try container.decodeIfPresent(PlanSpec.self, forKey: .spec).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct ReviewIssue: Sendable, Hashable, Codable {
    public var description: String
    public var file: String?
    public var agent: String?

    public init(description: String, file: String? = nil, agent: String? = nil) {
        self.description = description
        self.file = file
        self.agent = agent
    }
}

public struct CriterionResult: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case pass
        case fail
        case notVerified = "not_verified"

        public init(lenient text: String) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_") {
            case "pass", "passed", "passes", "ok", "met", "true", "yes": self = .pass
            case "fail", "failed", "fails", "not_met", "false", "no": self = .fail
            default: self = .notVerified
            }
        }
    }

    public var criterion: String
    public var status: Status
    public var evidence: String

    public init(criterion: String, status: Status, evidence: String = "") {
        self.criterion = criterion
        self.status = status
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case criterion, status, evidence
    }

    init?(lenient value: JSONValue) {
        let criterion = value["criterion"]?.string ?? value["criterion"]?.int.map(String.init)
        guard let criterion = criterion?.trimmingCharacters(in: .whitespacesAndNewlines), !criterion.isEmpty else { return nil }
        self.criterion = criterion
        self.status = Status(lenient: value["status"]?.string ?? "")
        self.evidence = value["evidence"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct Verdict: Sendable, Hashable, Codable {
    public var outcome: String
    public var summary: String
    public var issues: [ReviewIssue]
    public var criteria: [CriterionResult]

    public init(outcome: String, summary: String, issues: [ReviewIssue] = [], criteria: [CriterionResult] = []) {
        self.outcome = outcome
        self.summary = summary
        self.issues = issues
        self.criteria = criteria
    }

    enum CodingKeys: String, CodingKey {
        case outcome, summary, issues, criteria
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decode(String.self, forKey: .outcome)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.issues = try container.decodeIfPresent([ReviewIssue].self, forKey: .issues) ?? []
        let criteria = (try? container.decodeIfPresent(JSONValue.self, forKey: .criteria))?.array ?? []
        self.criteria = criteria.compactMap(CriterionResult.init(lenient:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(summary, forKey: .summary)
        try container.encode(issues, forKey: .issues)
        if !criteria.isEmpty { try container.encode(criteria, forKey: .criteria) }
    }
}

public struct SpecDraftRequest: Sendable, Hashable, Codable {
    public var title: String
    public var owner: String?
    public var summary: String
    public var interfaces: [String]
    public var outOfScope: [String]
    public var acceptanceCriteria: [String]
    public var verification: String

    public init(
        title: String, owner: String? = nil, summary: String = "", interfaces: [String] = [], outOfScope: [String] = [],
        acceptanceCriteria: [String] = [], verification: String = ""
    ) {
        self.title = title
        self.owner = owner
        self.summary = summary
        self.interfaces = interfaces
        self.outOfScope = outOfScope
        self.acceptanceCriteria = acceptanceCriteria
        self.verification = verification
    }

    enum CodingKeys: String, CodingKey {
        case title, owner, summary, interfaces, verification
        case outOfScope = "out_of_scope"
        case acceptanceCriteria = "acceptance_criteria"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func clean(_ items: [String]?) -> [String] {
            (items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        self.title = try container.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = try container.decodeIfPresent(String.self, forKey: .owner)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.interfaces = clean(try container.decodeIfPresent([String].self, forKey: .interfaces))
        self.outOfScope = clean(try container.decodeIfPresent([String].self, forKey: .outOfScope))
        self.acceptanceCriteria = clean(try container.decodeIfPresent([String].self, forKey: .acceptanceCriteria))
        self.verification = try container.decodeIfPresent(String.self, forKey: .verification)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct PinDraft: Sendable, Hashable, Codable {
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var title: String
    public var tags: [String]
    public var explanation: String
    public var confidence: Double?
    public var category: String?

    public init(file: String, startLine: Int, endLine: Int, title: String, tags: [String] = [], explanation: String, confidence: Double? = nil, category: String? = nil) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.title = title
        self.tags = tags
        self.explanation = explanation
        self.confidence = confidence
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case file, title, tags, explanation, confidence, category
        case startLine = "start_line"
        case endLine = "end_line"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.file = try container.decode(String.self, forKey: .file)
        self.startLine = try container.decode(Int.self, forKey: .startLine)
        self.endLine = try container.decodeIfPresent(Int.self, forKey: .endLine) ?? startLine
        self.title = try container.decode(String.self, forKey: .title)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence).map { min(1, max(0, $0)) }
        self.category = try container.decodeIfPresent(String.self, forKey: .category)?.lowercased()
    }
}

public struct EvidenceDraft: Sendable, Hashable, Codable {
    public var kind: EvidenceKind
    public var file: String
    public var title: String
    public var note: String

    public init(kind: EvidenceKind, file: String, title: String, note: String = "") {
        self.kind = kind
        self.file = file
        self.title = title
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case kind, file, title, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(EvidenceKind.self, forKey: .kind)
        self.file = try container.decode(String.self, forKey: .file)
        self.title = try container.decode(String.self, forKey: .title)
        self.note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

public struct HumanQuestion: Sendable, Hashable, Codable {
    public var question: String
    public var options: [String]

    public init(question: String, options: [String] = []) {
        self.question = question
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case question, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.question = try container.decode(String.self, forKey: .question)
        self.options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

public enum HandoffMessage: Sendable, Hashable {
    case plan(Plan)
    case verdict(Verdict)
    case pin(PinDraft)
    case evidence(EvidenceDraft)
    case question(String, [HumanQuestion] = [])
    case result(String)
    case proposal(RunProposal)
    case agentMessage(agent: String, message: String)
    case listAgents
    case spawnAgent(AgentSpawnRequest)
    case stopAgent(String)
    case deleteAgent(String, deleteBranch: Bool)
    case openWorktree
    case readChat(ChatReadRequest)
    case draftSpec(SpecDraftRequest)
}

public struct ChatReadRequest: Sendable, Hashable {
    public enum Section: String, Sendable, Hashable, CaseIterable {
        case overview
        case messages
        case run
        case transcript
    }

    public var requestID: Int64
    public var messageID: Int64?
    public var section: Section
    public var runID: Int64?
    public var agent: String?
    public var offset: Int?
    public var limit: Int?

    public init(
        requestID: Int64, messageID: Int64? = nil, section: Section = .overview, runID: Int64? = nil,
        agent: String? = nil, offset: Int? = nil, limit: Int? = nil
    ) {
        self.requestID = requestID
        self.messageID = messageID
        self.section = section
        self.runID = runID
        self.agent = agent
        self.offset = offset
        self.limit = limit
    }
}

public struct AgentSpawnRequest: Sendable, Hashable, Codable {
    public var role: String
    public var task: String
    public var name: String?
    public var model: String?
    public var count: Int

    public init(role: String, task: String, name: String? = nil, model: String? = nil, count: Int = 1) {
        self.role = role
        self.task = task
        self.name = name
        self.model = model
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case role, task, name, model, count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.task = try container.decode(String.self, forKey: .task)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 1)
    }
}

public enum HandoffTool: String, Sendable, CaseIterable {
    case submitPlan = "submit_plan"
    case submitVerdict = "submit_verdict"
    case submitResult = "submit_result"
    case createPin = "create_pin"
    case attachEvidence = "attach_evidence"
    case askHuman = "ask_human"
    case proposeRun = "propose_run"
    case messageAgent = "message_agent"
    case listAgents = "list_agents"
    case spawnAgent = "spawn_agent"
    case stopAgent = "stop_agent"
    case deleteAgent = "delete_agent"
    case openWorktree = "open_worktree"
    case readChat = "read_chat"
    case draftSpec = "draft_spec"

    public static let leadTools: Set<HandoffTool> = [.messageAgent, .listAgents, .spawnAgent, .stopAgent, .deleteAgent]

    public static let serverName = "ensemble"

    public var qualifiedName: String { "mcp__\(Self.serverName)__\(rawValue)" }

    public var description: String {
        switch self {
        case .submitPlan:
            "Submit your plan: a short summary, the list of tasks with the role that builds each and the files it owns, and a short spec (interfaces, acceptance criteria, out of scope, verification). Skip the spec only when the request fits in one sentence. Call once when planning is done, then end your turn."
        case .submitVerdict:
            "Submit your review or test verdict. outcome is approved or changes_requested for reviews, passed or failed for tests. List concrete issues. Then end your turn."
        case .submitResult:
            "Summarize what you built and how you verified it. Call when your task is finished, then end your turn."
        case .createPin:
            "Flag lines a human must read before this work ships: risky logic, security, migrations, money, data loss. Lines refer to the file in your worktree. Reviewers: give your confidence that it’s a real problem and a category; only pin what is worth a person’s time."
        case .attachEvidence:
            "Attach evidence for the user to see with your change: a screenshot or recording of UI you changed, or benchmark output for performance work. The file must be in your worktree or a folder you can read; Ensemble keeps a copy."
        case .proposeRun:
            "Propose a workflow run for this request. The user sees it with a Start button; nothing runs until they click it. If they start it, you plan it. Give the workflow id, a short title and a brief with everything the planner needs from this conversation. Then end your turn."
        case .messageAgent:
            "Send an instruction to another agent in this project, by its name. It arrives as that agent's next message. Use it to pass on the user's instructions or to steer agents you lead. An agent a lead started can message only that lead."
        case .listAgents:
            "List every agent in this project with its role, status, branch, worktree and task."
        case .spawnAgent:
            "Start new agents of a role with a task. Agents of roles that edit code get their own worktree and branch. They start working on the task right away. When each one ends its turn, its report arrives as your next message, so end your turn after calling this instead of checking on them."
        case .stopAgent:
            "Stop another agent's current turn and drop its queued messages. It keeps its worktree, branch and history and can be messaged again later."
        case .deleteAgent:
            "Delete another agent: stop it, remove its worktree and history, and delete its branch when delete_branch is true. Agents in a running workflow can't be deleted; stop them instead."
        case .openWorktree:
            "Get your own git worktree and branch so you can change code yourself. Call it only when you must edit files, then end your turn; your next turn runs inside the worktree with write access."
        case .askHuman:
            "Ask the user questions you can't answer from the code or docs. Put shared context in question. When you need several decisions, list each one in questions, with options when there are clear choices; the user answers them one at a time. After calling it, end your turn; the answers arrive as your next message, numbered like your questions."
        case .readChat:
            "Read an Ensemble request chat from any project: its messages, runs, run step history and agent transcripts. A link ensemble://chat/<request_id>?message=<message_id> maps to request_id and message_id; call this tool whenever a message contains such a link. Start with the overview section, then page with offset and limit or pull the messages, run or transcript section."
        case .draftSpec:
            "Create or replace this request’s spec draft: a Markdown file with a summary, interfaces, out of scope, checkable acceptance criteria and how to verify the whole change. The user can open and edit it from the chat, and that file is the source of truth: when the user edited it, you get the current text, so keep their edits and send the complete spec each time. Draft a spec before proposing a run for any non-trivial request; starting the run commits it."
        }
    }

    public var inputSchema: JSONValue {
        func string(_ description: String) -> JSONValue { .object(["type": .string("string"), "description": .string(description)]) }
        func array(_ items: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": items]) }
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string))])
        }
        switch self {
        case .submitPlan:
            return object([
                "summary": string("One paragraph describing the approach"),
                "tasks": array(object([
                    "title": string("Short imperative task title"),
                    "details": string("What to build, constraints, and how to verify it"),
                    "role": string("Role id that should build this task"),
                    "files": array(string("A file or folder this task owns")),
                ], required: ["title", "role"])),
                "spec": object([
                    "interfaces": array(string("A function, endpoint, type or command the work adds or changes, with its signature")),
                    "acceptance_criteria": array(string("A checkable statement that is true when the work is done")),
                    "out_of_scope": array(string("Something this work deliberately doesn't do")),
                    "verification": string("How to verify the whole change end to end"),
                ], required: []),
            ], required: ["summary", "tasks"])
        case .submitVerdict:
            return object([
                "outcome": .object(["type": .string("string"), "enum": .array(["approved", "changes_requested", "passed", "failed"].map(JSONValue.string))]),
                "summary": string("What you checked and what you found"),
                "issues": array(object([
                    "description": string("The problem and the expected fix"),
                    "file": string("File path, if specific"),
                    "agent": string("Name of the agent whose work this is, if specific"),
                ], required: ["description"])),
                "criteria": array(object([
                    "criterion": string("The acceptance criterion's number and text, as listed in your instructions"),
                    "status": .object(["type": .string("string"), "enum": .array(CriterionResult.Status.allCases.map { JSONValue.string($0.rawValue) })]),
                    "evidence": string("What shows it: a file and line, a test name, or command output"),
                ], required: ["criterion", "status", "evidence"])),
            ], required: ["outcome", "summary"])
        case .submitResult:
            return object(["summary": string("What you changed and how you verified it")], required: ["summary"])
        case .createPin:
            return object([
                "file": string("Path relative to the repository root"),
                "start_line": .object(["type": .string("integer")]),
                "end_line": .object(["type": .string("integer")]),
                "title": string("One line a reviewer reads first"),
                "tags": array(string("Short tag such as security, migration, money")),
                "explanation": string("Why a human must read this"),
                "confidence": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1), "description": .string("How sure you are this is a real problem, from 0 to 1")]),
                "category": .object(["type": .string("string"), "enum": .array(["correctness", "security", "data", "performance", "tests", "design", "style", "nit"].map(JSONValue.string))]),
            ], required: ["file", "start_line", "end_line", "title", "explanation"])
        case .attachEvidence:
            return object([
                "kind": .object(["type": .string("string"), "enum": .array(EvidenceKind.allCases.map { JSONValue.string($0.rawValue) })]),
                "file": string("Path to the screenshot, recording or benchmark output"),
                "title": string("What it shows, in one line"),
                "note": string("Anything the reviewer should know, such as the numbers before and after"),
            ], required: ["kind", "file", "title"])
        case .proposeRun:
            return object([
                "workflow": string("Workflow id from the list in your instructions"),
                "title": string("Short imperative title for the run"),
                "brief": string("What to build and every decision the user made in this conversation"),
            ], required: ["workflow", "title", "brief"])
        case .messageAgent:
            return object([
                "agent": string("The agent's name, as shown in the run status"),
                "message": string("The instruction to pass on"),
            ], required: ["agent", "message"])
        case .listAgents, .openWorktree:
            return object([:], required: [])
        case .spawnAgent:
            return object([
                "role": string("Role id of the new agents"),
                "task": string("What the agents should do, with everything they need to start"),
                "name": string("Base name for the agents; defaults to the role's name"),
                "model": string("Model alias or full name; defaults to the role's model"),
                "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(Double(AgentRuntime.maxSpawnCount))]),
            ], required: ["role", "task"])
        case .stopAgent:
            return object(["agent": string("The agent's name, as list_agents shows it")], required: ["agent"])
        case .deleteAgent:
            return object([
                "agent": string("The agent's name, as list_agents shows it"),
                "delete_branch": .object(["type": .string("boolean"), "description": .string("Also delete the agent's git branch. Defaults to false.")]),
            ], required: ["agent"])
        case .askHuman:
            return object([
                "question": string("The question, or the context shared by all questions when you list them in questions"),
                "questions": array(object([
                    "question": string("One decision, with what it affects"),
                    "options": array(string("A short answer the user can pick")),
                ], required: ["question"])),
            ], required: ["question"])
        case .readChat:
            func integer(_ description: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(description)]) }
            return object([
                "request_id": integer("The request id, the number after ensemble://chat/ in a link"),
                "message_id": integer("A message id from ?message= in a link; that message is marked in the output"),
                "section": .object([
                    "type": .string("string"),
                    "enum": .array(ChatReadRequest.Section.allCases.map { JSONValue.string($0.rawValue) }),
                    "description": .string("overview (default): request, runs and the first messages; messages: every message; run: one run's step history; transcript: one agent's transcript"),
                ]),
                "run_id": integer("The run to read; required for the run section, optional for transcript"),
                "agent": string("Agent name or id; required for the transcript section"),
                "offset": .object(["type": .string("integer"), "minimum": .number(0), "description": .string("Index of the first item to show")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "description": .string("How many items to show; defaults to \(ChatReader.defaultLimit)")]),
            ], required: ["request_id"])
        case .draftSpec:
            return object([
                "title": string("Short title of the spec; it also names the file"),
                "owner": string("Who owns the spec, if the user said"),
                "summary": string("One paragraph: what the change does and why"),
                "interfaces": array(string("A function, endpoint, type, setting or command the work adds or changes, with its signature")),
                "out_of_scope": array(string("Something this work deliberately doesn't do")),
                "acceptance_criteria": array(string("A checkable statement that is true when the work is done")),
                "verification": string("How to verify the whole change end to end"),
            ], required: ["title", "summary", "acceptance_criteria"])
        }
    }

    public func decode(_ arguments: JSONValue) throws -> HandoffMessage {
        let data = Data(arguments.compactJSON.utf8)
        let decoder = JSONDecoder()
        switch self {
        case .submitPlan: return .plan(try decoder.decode(Plan.self, from: data))
        case .submitVerdict: return .verdict(try decoder.decode(Verdict.self, from: data))
        case .createPin: return .pin(try decoder.decode(PinDraft.self, from: data))
        case .attachEvidence: return .evidence(try decoder.decode(EvidenceDraft.self, from: data))
        case .askHuman:
            guard let question = arguments["question"]?.string, !question.isEmpty else { throw HandoffError.missing("question") }
            let questions = try arguments["questions"].map { try decoder.decode([HumanQuestion].self, from: Data($0.compactJSON.utf8)) } ?? []
            return .question(question, questions.filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        case .submitResult:
            guard let summary = arguments["summary"]?.string else { throw HandoffError.missing("summary") }
            return .result(summary)
        case .proposeRun:
            let proposal = try decoder.decode(RunProposal.self, from: data)
            for (field, value) in [("workflow", proposal.workflow), ("title", proposal.title), ("brief", proposal.brief)]
            where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw HandoffError.missing(field)
            }
            return .proposal(proposal)
        case .messageAgent:
            guard let agent = arguments["agent"]?.string, !agent.isEmpty else { throw HandoffError.missing("agent") }
            guard let message = arguments["message"]?.string, !message.isEmpty else { throw HandoffError.missing("message") }
            return .agentMessage(agent: agent, message: message)
        case .listAgents:
            return .listAgents
        case .spawnAgent:
            let request = try decoder.decode(AgentSpawnRequest.self, from: data)
            for (field, value) in [("role", request.role), ("task", request.task)]
            where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw HandoffError.missing(field)
            }
            return .spawnAgent(request)
        case .stopAgent:
            guard let agent = arguments["agent"]?.string, !agent.isEmpty else { throw HandoffError.missing("agent") }
            return .stopAgent(agent)
        case .deleteAgent:
            guard let agent = arguments["agent"]?.string, !agent.isEmpty else { throw HandoffError.missing("agent") }
            return .deleteAgent(agent, deleteBranch: arguments["delete_branch"]?.bool ?? false)
        case .openWorktree:
            return .openWorktree
        case .readChat:
            func integer(_ key: String) -> Int? { arguments[key]?.int ?? arguments[key]?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            guard let requestID = integer("request_id") else { throw HandoffError.missing("request_id") }
            let sectionName = arguments["section"]?.string?.trimmingCharacters(in: .whitespaces).lowercased()
            guard let section = sectionName.map(ChatReadRequest.Section.init(rawValue:)) ?? .overview else {
                let names = ChatReadRequest.Section.allCases.map(\.rawValue).joined(separator: ", ")
                throw HandoffError.notAllowed("Unknown section “\(sectionName ?? "")”. Use one of: \(names).")
            }
            let runID = integer("run_id")
            let agent = arguments["agent"]?.string?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? integer("agent").map(String.init)
            if section == .run, runID == nil { throw HandoffError.missing("run_id") }
            if section == .transcript, agent == nil { throw HandoffError.missing("agent") }
            return .readChat(ChatReadRequest(
                requestID: Int64(requestID), messageID: integer("message_id").map(Int64.init), section: section,
                runID: runID.map(Int64.init), agent: agent, offset: integer("offset"), limit: integer("limit")
            ))
        case .draftSpec:
            let request = try decoder.decode(SpecDraftRequest.self, from: data)
            guard !request.title.isEmpty else { throw HandoffError.missing("title") }
            return .draftSpec(request)
        }
    }
}

public enum HandoffError: Error, LocalizedError, Equatable {
    case missing(String)
    case unknownTool(String)
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let field): "Missing required field “\(field)”."
        case .unknownTool(let name): "Unknown tool \(name)."
        case .notAllowed(let reason): reason
        }
    }
}
