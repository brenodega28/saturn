import Foundation

public struct GateFinding: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case size
        case secret
        case dependency
        case duplication
        case complexity
        case evidence
        case criteria
    }

    public enum Severity: String, Sendable, Hashable, Codable {
        case blocking
        case warning
    }

    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String
    public var file: String?
    public var line: Int?
    public var agentName: String?

    public init(kind: Kind, severity: Severity, title: String, detail: String, file: String? = nil, line: Int? = nil, agentName: String? = nil) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.file = file
        self.line = line
        self.agentName = agentName
    }

    public var id: String { [kind.rawValue, agentName ?? "", file ?? "", line.map(String.init) ?? "", title].joined(separator: "|") }

    public var issue: ReviewIssue {
        ReviewIssue(description: "\(title). \(detail)", file: file, agent: agentName)
    }
}

public struct GateReport: Sendable, Hashable, Codable {
    public var findings: [GateFinding]
    public var criteria: [CriterionResult]

    public init(findings: [GateFinding] = [], criteria: [CriterionResult] = []) {
        self.findings = findings
        self.criteria = criteria
    }

    enum CodingKeys: String, CodingKey {
        case findings, criteria
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.findings = try container.decodeIfPresent([GateFinding].self, forKey: .findings) ?? []
        self.criteria = (try? container.decodeIfPresent([CriterionResult].self, forKey: .criteria)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(findings, forKey: .findings)
        if !criteria.isEmpty { try container.encode(criteria, forKey: .criteria) }
    }

    public var blocking: [GateFinding] { findings.filter { $0.severity == .blocking } }
    public var warnings: [GateFinding] { findings.filter { $0.severity == .warning } }
    public var passed: Bool { blocking.isEmpty }

    public var summary: String {
        if findings.isEmpty { return "All gates passed." }
        var parts: [String] = []
        if !blocking.isEmpty { parts.append("\(blocking.count) need\(blocking.count == 1 ? "s" : "") your decision") }
        if !warnings.isEmpty { parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") }
        return "Gates: " + parts.joined(separator: ", ") + "."
    }

    public var details: String {
        findings.map { finding in
            let place = [finding.agentName, finding.file.map { file in finding.line.map { "\(file):\($0)" } ?? file }].compactMap(\.self).joined(separator: " · ")
            return "• \(finding.severity == .blocking ? "Decide" : "Warning"): \(finding.title)\(place.isEmpty ? "" : " (\(place))")\n  \(finding.detail)"
        }.joined(separator: "\n")
    }
}

extension Array {
    func ifEmpty(_ replacement: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? replacement() : self
    }
}
