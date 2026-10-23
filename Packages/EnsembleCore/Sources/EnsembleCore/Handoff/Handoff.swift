import Foundation

public struct PlanTask: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var details: String
    public var role: String
    public var count: Int
    public var files: [String]

    public init(id: String = UUID().uuidString, title: String, details: String = "", role: String, count: Int = 1, files: [String] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.role = role
        self.count = count
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case id, title, details, role, count, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decode(String.self, forKey: .title)
        self.details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        self.role = try container.decode(String.self, forKey: .role)
        self.count = max(1, try container.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        self.files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    }
}

public struct Plan: Sendable, Hashable, Codable {
    public var summary: String
    public var tasks: [PlanTask]

    public init(summary: String, tasks: [PlanTask]) {
        self.summary = summary
        self.tasks = tasks
    }

    public var agentCount: Int { tasks.reduce(0) { $0 + $1.count } }
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

public struct Verdict: Sendable, Hashable, Codable {
    public var outcome: String
    public var summary: String
    public var issues: [ReviewIssue]

    public init(outcome: String, summary: String, issues: [ReviewIssue] = []) {
        self.outcome = outcome
        self.summary = summary
        self.issues = issues
    }

    enum CodingKeys: String, CodingKey {
        case outcome, summary, issues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decode(String.self, forKey: .outcome)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.issues = try container.decodeIfPresent([ReviewIssue].self, forKey: .issues) ?? []
    }
}

public struct PinDraft: Sendable, Hashable, Codable {
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var title: String
    public var tags: [String]
    public var explanation: String

    public init(file: String, startLine: Int, endLine: Int, title: String, tags: [String] = [], explanation: String) {
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.title = title
        self.tags = tags
        self.explanation = explanation
    }

    enum CodingKeys: String, CodingKey {
        case file, title, tags, explanation
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
    case question(String, [HumanQuestion] = [])
    case result(String)
}

public enum HandoffTool: String, Sendable, CaseIterable {
    case submitPlan = "submit_plan"
    case submitVerdict = "submit_verdict"
    case submitResult = "submit_result"
    case createPin = "create_pin"
    case askHuman = "ask_human"

    public static let serverName = "ensemble"

    public var qualifiedName: String { "mcp__\(Self.serverName)__\(rawValue)" }

    public var description: String {
        switch self {
        case .submitPlan:
            "Submit your plan: a short summary and the list of tasks, each with the role that should build it. Call once when planning is done, then end your turn."
        case .submitVerdict:
            "Submit your review or test verdict. outcome is approved or changes_requested for reviews, passed or failed for tests. List concrete issues. Then end your turn."
        case .submitResult:
            "Summarize what you built and how you verified it. Call when your task is finished, then end your turn."
        case .createPin:
            "Flag lines a human must read before this work ships: risky logic, security, migrations, money, data loss. Lines refer to the file in your worktree."
        case .askHuman:
            "Ask the user questions you can't answer from the code or docs. Put shared context in question. When you need several decisions, list each one in questions, with options when there are clear choices; the user answers them one at a time. After calling it, end your turn; the answers arrive as your next message, numbered like your questions."
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
                    "count": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "files": array(string("A file or folder this task owns")),
                ], required: ["title", "role"])),
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
            ], required: ["file", "start_line", "end_line", "title", "explanation"])
        case .askHuman:
            return object([
                "question": string("The question, or the context shared by all questions when you list them in questions"),
                "questions": array(object([
                    "question": string("One decision, with what it affects"),
                    "options": array(string("A short answer the user can pick")),
                ], required: ["question"])),
            ], required: ["question"])
        }
    }

    public func decode(_ arguments: JSONValue) throws -> HandoffMessage {
        let data = Data(arguments.compactJSON.utf8)
        let decoder = JSONDecoder()
        switch self {
        case .submitPlan: return .plan(try decoder.decode(Plan.self, from: data))
        case .submitVerdict: return .verdict(try decoder.decode(Verdict.self, from: data))
        case .createPin: return .pin(try decoder.decode(PinDraft.self, from: data))
        case .askHuman:
            guard let question = arguments["question"]?.string, !question.isEmpty else { throw HandoffError.missing("question") }
            let questions = try arguments["questions"].map { try decoder.decode([HumanQuestion].self, from: Data($0.compactJSON.utf8)) } ?? []
            return .question(question, questions.filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        case .submitResult:
            guard let summary = arguments["summary"]?.string else { throw HandoffError.missing("summary") }
            return .result(summary)
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
