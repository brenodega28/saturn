import Foundation

public struct GateFinding: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case size
        case secret
        case dependency
        case duplication
        case complexity
        case evidence
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

    public init(findings: [GateFinding] = []) {
        self.findings = findings
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
