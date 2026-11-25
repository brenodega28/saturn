import Foundation
import Yams

public enum SpecStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case draft
    case approved
    case inProgress = "in-progress"
    case done
    case rejected

    public init(lenient text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        self = Self(rawValue: key) ?? .draft
    }

    public var title: String {
        switch self {
        case .draft: "Draft"
        case .approved: "Approved"
        case .inProgress: "In progress"
        case .done: "Done"
        case .rejected: "Rejected"
        }
    }
}

public struct SpecWorker: Sendable, Hashable, Codable {
    public var role: String
    public var name: String
    public var reason: String?
    public var skills: [String]
    public var model: String?

    public init(role: String, name: String, reason: String? = nil, skills: [String] = [], model: String? = nil) {
        self.role = role
        self.name = name
        self.reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.skills = skills.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var kind: AgentKind { AgentKind.guessing(roleID: role) }

    enum CodingKeys: String, CodingKey {
        case role, name, reason, skills, model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role).trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.skills = (try container.decodeIfPresent([String].self, forKey: .skills) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.model = try container.decodeIfPresent(String.self, forKey: .model)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct SpecCriterion: Sendable, Hashable, Codable {
    public var text: String
    public var checked: Bool

    public init(text: String, checked: Bool = false) {
        self.text = text
        self.checked = checked
    }
}

public struct SpecSection: Sendable, Hashable, Codable {
    public var heading: String
    public var body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

public enum SpecDocumentError: Error, LocalizedError, Equatable {
    case invalidFrontMatter(String)
    case missingTitle

    public var errorDescription: String? {
        switch self {
        case .invalidFrontMatter(let reason): "The spec’s front matter isn’t valid YAML: \(reason)"
        case .missingTitle: "The spec has no title. Add “title:” to its front matter."
        }
    }
}

public struct SpecDocument: Sendable, Hashable {
    public var title: String
    public var status: SpecStatus
    public var version: Int
    public var workers: [SpecWorker]
    public var workflow: String?
    public var owner: String
    public var linkedRuns: [Int64]
    public var created: Date
    public var summary: String
    public var interfaces: [String]
    public var outOfScope: [String]
    public var acceptanceCriteria: [SpecCriterion]
    public var verification: String
    public var preamble: String
    public var extraSections: [SpecSection]
    public var extraFrontMatter: String

    public init(
        title: String, status: SpecStatus = .draft, version: Int = 1, workers: [SpecWorker] = [], workflow: String? = nil, owner: String = "", linkedRuns: [Int64] = [], created: Date = .now,
        summary: String = "", interfaces: [String] = [], outOfScope: [String] = [], acceptanceCriteria: [SpecCriterion] = [],
        verification: String = "", preamble: String = "", extraSections: [SpecSection] = [], extraFrontMatter: String = ""
    ) {
        self.title = title
        self.status = status
        self.version = max(1, version)
        self.workers = workers
        self.workflow = workflow?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.owner = owner
        self.linkedRuns = linkedRuns
        self.created = Self.day(of: created)
        self.summary = summary
        self.interfaces = interfaces
        self.outOfScope = outOfScope
        self.acceptanceCriteria = acceptanceCriteria
        self.verification = verification
        self.preamble = preamble
        self.extraSections = extraSections
        self.extraFrontMatter = extraFrontMatter
    }

    enum Heading: String, CaseIterable {
        case summary = "Summary"
        case interfaces = "Interfaces"
        case outOfScope = "Out of scope"
        case acceptanceCriteria = "Acceptance criteria"
        case verification = "Verification"

        init?(lenient text: String) {
            let key = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
            self = match
        }
    }

    static let knownKeys: Set<String> = ["title", "status", "version", "workers", "workflow", "owner", "linked_runs", "created"]

    public init(markdown: String) throws {
        let (frontMatter, body) = Self.splitFrontMatter(markdown)
        var fields: [String: Any] = [:]
        if let frontMatter, !frontMatter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                guard let loaded = try Yams.load(yaml: frontMatter) else { throw SpecDocumentError.invalidFrontMatter("it is empty") }
                guard let map = loaded as? [String: Any] else { throw SpecDocumentError.invalidFrontMatter("it isn’t a list of keys and values") }
                fields = map
            } catch let error as SpecDocumentError {
                throw error
            } catch {
                throw SpecDocumentError.invalidFrontMatter(String(describing: error))
            }
        }

        let (preamble, sections) = Self.sections(of: body)
        let heading = preamble.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        guard let title = Self.string(fields["title"])?.nilIfEmpty ?? heading?.nilIfEmpty else { throw SpecDocumentError.missingTitle }

        var known: [Heading: String] = [:]
        var extra: [SpecSection] = []
        for section in sections {
            if let kind = Heading(lenient: section.heading), known[kind] == nil {
                known[kind] = section.body
            } else {
                extra.append(section)
            }
        }

        self.init(
            title: title,
            status: Self.string(fields["status"]).map(SpecStatus.init(lenient:)) ?? .draft,
            version: Self.string(fields["version"]).flatMap { Int($0) } ?? 1,
            workers: Self.workers(fields["workers"]),
            workflow: Self.string(fields["workflow"]),
            owner: Self.string(fields["owner"]) ?? "",
            linkedRuns: Self.runIDs(fields["linked_runs"]),
            created: Self.date(fields["created"]) ?? Self.day(of: .now),
            summary: Self.paragraph(known[.summary]),
            interfaces: Self.listItems(known[.interfaces]),
            outOfScope: Self.listItems(known[.outOfScope]),
            acceptanceCriteria: Self.checklist(known[.acceptanceCriteria]),
            verification: Self.paragraph(known[.verification]),
            preamble: preamble.trimmingCharacters(in: .whitespacesAndNewlines),
            extraSections: extra,
            extraFrontMatter: frontMatter.map(Self.unknownFrontMatter) ?? ""
        )
    }

    public var markdown: String {
        var front = [
            "title: \(Self.yamlScalar(title))",
            "status: \(status.rawValue)",
            "version: \(version)",
            "owner: \(Self.yamlScalar(owner))",
            "linked_runs: [\(linkedRuns.map(String.init).joined(separator: ", "))]",
            "created: \(Self.dayFormatter.string(from: created))",
        ]
        if !workers.isEmpty {
            let lines = ["workers:"] + workers.map { worker in
                let reason = worker.reason.map { ", reason: \(Self.yamlScalar($0))" } ?? ""
                let skills = worker.skills.isEmpty ? "" : ", skills: [\(worker.skills.map(Self.yamlScalar).joined(separator: ", "))]"
                let model = worker.model.map { ", model: \(Self.yamlScalar($0))" } ?? ""
                return "  - {role: \(Self.yamlScalar(worker.role)), name: \(Self.yamlScalar(worker.name))\(reason)\(skills)\(model)}"
            }
            front.insert(contentsOf: lines, at: 3)
        }
        if let workflow { front.insert("workflow: \(Self.yamlScalar(workflow))", at: 3) }
        let extraFront = extraFrontMatter.trimmingCharacters(in: .newlines)
        if !extraFront.isEmpty { front.append(extraFront) }

        var parts = ["---\n" + front.joined(separator: "\n") + "\n---"]
        if !preamble.isEmpty { parts.append(preamble) }
        parts.append(Self.section(.summary, summary))
        parts.append(Self.section(.interfaces, interfaces.map { "- \($0)" }.joined(separator: "\n")))
        parts.append(Self.section(.outOfScope, outOfScope.map { "- \($0)" }.joined(separator: "\n")))
        parts.append(Self.section(.acceptanceCriteria, acceptanceCriteria.map { "- [\($0.checked ? "x" : " ")] \($0.text)" }.joined(separator: "\n")))
        parts.append(Self.section(.verification, verification))
        for section in extraSections {
            let body = section.body.trimmingCharacters(in: .newlines)
            parts.append("## \(section.heading)" + (body.isEmpty ? "" : "\n\n" + body))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    public var planSpec: PlanSpec {
        PlanSpec(interfaces: interfaces, outOfScope: outOfScope, acceptanceCriteria: acceptanceCriteria.map(\.text), verification: verification)
    }

    public var checkedCount: Int { acceptanceCriteria.count(where: \.checked) }

    private static func section(_ heading: Heading, _ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "## \(heading.rawValue)" + (trimmed.isEmpty ? "" : "\n\n" + trimmed)
    }

    static func splitFrontMatter(_ markdown: String) -> (frontMatter: String?, body: String) {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return (nil, lines.joined(separator: "\n")) }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func sections(of body: String) -> (preamble: String, sections: [SpecSection]) {
        var preamble: [String] = []
        var sections: [(heading: String, lines: [String])] = []
        var fence: String?
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
            } else if line.hasPrefix("## ") {
                sections.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), []))
                continue
            }
            if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return (
            preamble.joined(separator: "\n"),
            sections.map { SpecSection(heading: $0.heading, body: $0.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
        )
    }

    private static func paragraph(_ body: String?) -> String {
        (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listItems(_ body: String?) -> [String] {
        let lines = (body ?? "").components(separatedBy: "\n")
        let hasMarkers = lines.contains { bulletText($0) != nil }
        var items: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let text = bulletText(line) {
                items.append(text)
            } else if hasMarkers, !items.isEmpty, line.first?.isWhitespace == true {
                items[items.count - 1] += " " + trimmed
            } else {
                items.append(trimmed)
            }
        }
        return items.filter { !$0.isEmpty }
    }

    private static func checklist(_ body: String?) -> [SpecCriterion] {
        listItems(body).map { item in
            let lowered = item.lowercased()
            if lowered.hasPrefix("[x]") { return SpecCriterion(text: item.dropFirst(3).trimmingCharacters(in: .whitespaces), checked: true) }
            if item.hasPrefix("[ ]") || item.hasPrefix("[]") {
                return SpecCriterion(text: item.drop { $0 != "]" }.dropFirst().trimmingCharacters(in: .whitespaces), checked: false)
            }
            return SpecCriterion(text: item, checked: false)
        }
    }

    private static func bulletText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed == "-" || trimmed == "*" { return "" }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
           trimmed[trimmed.index(after: dot)...].first == " " {
            return String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func unknownFrontMatter(_ frontMatter: String) -> String {
        var kept: [String] = []
        var keeping = false
        for line in frontMatter.components(separatedBy: "\n") {
            if let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") {
                keeping = !knownKeys.contains(line[..<colon].trimmingCharacters(in: .whitespaces))
            }
            if keeping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as Int: String(number)
        case let number as Double: String(number)
        case let date as Date: dayFormatter.string(from: date)
        case let flag as Bool: String(flag)
        default: nil
        }
    }

    private static func workers(_ value: Any?) -> [SpecWorker] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            if let map = item as? [String: Any], let name = string(map["name"])?.nilIfEmpty {
                return SpecWorker(
                    role: string(map["role"]) ?? "", name: name, reason: string(map["reason"]),
                    skills: strings(map["skills"]), model: string(map["model"])
                )
            }
            return string(item)?.nilIfEmpty.map { SpecWorker(role: "", name: $0) }
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let items = value as? [Any] { return items.compactMap { string($0)?.nilIfEmpty } }
        return string(value).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
    }

    private static func runIDs(_ value: Any?) -> [Int64] {
        switch value {
        case let numbers as [Any]:
            return numbers.compactMap { item in
                if let number = item as? Int { return Int64(number) }
                return string(item).flatMap { Int64($0.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
            }
        case let number as Int:
            return [Int64(number)]
        case let text as String:
            return text.split(whereSeparator: { ",; ".contains($0) }).compactMap { Int64($0.trimmingCharacters(in: CharacterSet(charactersIn: "#[] "))) }
        default:
            return []
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return day(of: date, in: TimeZone(identifier: "UTC") ?? .current) }
        guard let text = string(value) else { return nil }
        return dayFormatter.date(from: String(text.prefix(10)))
    }

    static func day(of date: Date, in zone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return dayFormatter.date(from: String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)) ?? date
    }

    static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func yamlScalar(_ text: String) -> String {
        if text.isEmpty { return "\"\"" }
        let reserved = ["true", "false", "yes", "no", "null", "~", "on", "off"]
        let special = CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")
        let plain = !text.unicodeScalars.contains { special.contains($0) || CharacterSet.newlines.contains($0) }
            && text.first.map { !$0.isWhitespace && !"-?".contains($0) } == true
            && text.last?.isWhitespace == false
            && !reserved.contains(text.lowercased())
            && Double(text) == nil
        if plain { return text }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
