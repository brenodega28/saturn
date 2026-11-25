import Foundation

public enum SpecCriteria {
    public static func index(of reported: String, in criteria: [String]) -> Int? {
        let wanted = normalized(reported)
        if let exact = criteria.firstIndex(where: { normalized($0) == wanted }) { return exact }
        let digits = reported.trimmingCharacters(in: .whitespaces).drop { "#(".contains($0) }.prefix { $0.isNumber }
        if let number = Int(digits), criteria.indices.contains(number - 1) {
            let rest = normalized(String(reported.trimmingCharacters(in: .whitespaces).drop { "#(".contains($0) }.dropFirst(digits.count)))
            if rest.isEmpty || normalized(criteria[number - 1]).contains(rest) || rest.contains(normalized(criteria[number - 1])) {
                return number - 1
            }
        }
        guard !wanted.isEmpty else { return nil }
        let containing = criteria.indices.filter { normalized(criteria[$0]).contains(wanted) || wanted.contains(normalized(criteria[$0])) }
        return containing.count == 1 ? containing.first : nil
    }

    public static func latest(criteria: [String], verdicts: [Verdict]) -> [CriterionResult?] {
        var results = [CriterionResult?](repeating: nil, count: criteria.count)
        for verdict in verdicts {
            for result in verdict.criteria {
                guard let index = index(of: result.criterion, in: criteria) else { continue }
                results[index] = CriterionResult(criterion: criteria[index], status: result.status, evidence: result.evidence)
            }
        }
        return results
    }

    public static let missingEvidence = "No reviewer or tester reported on it."

    public static func report(criteria: [String], verdicts: [Verdict]) -> [CriterionResult] {
        zip(criteria, latest(criteria: criteria, verdicts: verdicts)).map { criterion, result in
            result ?? CriterionResult(criterion: criterion, status: .notVerified, evidence: missingEvidence)
        }
    }

    public static func findings(criteria: [String], verdicts: [Verdict]) -> [GateFinding] {
        let checked = !verdicts.isEmpty
        return zip(criteria.indices, latest(criteria: criteria, verdicts: verdicts)).compactMap { index, result in
            let label = "Criterion \(index + 1)"
            let text = criteria[index]
            switch result?.status {
            case .pass?:
                return nil
            case .fail?:
                return GateFinding(
                    kind: .criteria, severity: .blocking, title: "\(label) failed: \(text)",
                    detail: (result?.evidence).flatMap(\.nilIfEmpty) ?? "The latest check reported it as failing. Send the work back to fix it, or continue to accept it."
                )
            case .notVerified?:
                return GateFinding(
                    kind: .criteria, severity: .warning, title: "\(label) not verified: \(text)",
                    detail: (result?.evidence).flatMap(\.nilIfEmpty) ?? "The latest check couldn’t confirm it. Check it yourself before approving."
                )
            case nil:
                guard checked else { return nil }
                return GateFinding(kind: .criteria, severity: .warning, title: "\(label) has no result: \(text)", detail: missingEvidence + " Check it yourself before approving.")
            }
        }
    }

    public static func ticked(_ document: SpecDocument, verdicts: [Verdict]) -> SpecDocument {
        var updated = document
        let results = latest(criteria: document.acceptanceCriteria.map(\.text), verdicts: verdicts)
        for (index, result) in results.enumerated() where result?.status == .pass {
            updated.acceptanceCriteria[index].checked = true
        }
        return updated
    }

    public static func prompt(for criteria: [String]) -> String {
        let list = criteria.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
            ## Acceptance criteria to check
            \(list)

            Check every criterion above against the work. In `\(HandoffTool.submitVerdict.qualifiedName)`, add one `criteria` entry per criterion, in this order: `criterion` with its number and text, `status` `pass`, `fail` or `not_verified`, and `evidence`: the file and line, test, or command output that shows it. Use `not_verified` only when you couldn’t check it, and say why in the evidence. A failing criterion blocks approval until it is fixed or the user accepts it.
            """
    }

    static func normalized(_ text: String) -> String {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- [ ]", "- [x]", "[ ]", "[x]", "- ", "* "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        let kept = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }
}

extension PlanSpec {
    public func authoritative(over planner: PlanSpec?) -> PlanSpec {
        guard let planner else { return self }
        func union(_ mine: [String], _ theirs: [String]) -> [String] {
            mine + theirs.filter { item in !mine.contains { SpecCriteria.normalized($0) == SpecCriteria.normalized(item) } }
        }
        return PlanSpec(
            interfaces: union(interfaces, planner.interfaces),
            outOfScope: union(outOfScope, planner.outOfScope),
            acceptanceCriteria: acceptanceCriteria,
            verification: verification.isEmpty ? planner.verification : verification
        )
    }
}
