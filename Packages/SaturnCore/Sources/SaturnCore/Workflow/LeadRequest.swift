import Foundation

public enum LeadRequest {
    public static let maxTitleLength = 80

    public static func title(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > maxTitleLength else { return firstLine }
        let cut = firstLine.prefix(maxTitleLength - 1)
        let wordBoundary = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return wordBoundary.trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func task(text: String, projectID: Int64, workflowID: String, now: Date = .now) -> Chat? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return Chat(
            projectId: projectID, title: title(for: body), body: body, source: .chat, workflow: workflowID,
            status: .incoming, createdAt: now, updatedAt: now
        )
    }

    public static func partition(_ requests: [Chat]) -> (open: [Chat], closed: [Chat]) {
        let open = requests.filter { !$0.isClosed }
        let closed = requests.enumerated()
            .filter { $0.element.isClosed }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.closedAt ?? .distantPast, rhs.element.closedAt ?? .distantPast)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        return (open, closed)
    }
}

extension WorkflowDefinition {
    public var hasLead: Bool {
        steps.contains { $0.type == .agent && $0.agent == .lead }
    }
}

extension Run {
    public static func leadOrdering(_ runs: [Run]) -> [Run] {
        runs.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return (lhs.startedAt, lhs.id ?? 0) > (rhs.startedAt, rhs.id ?? 0)
        }
    }
}
