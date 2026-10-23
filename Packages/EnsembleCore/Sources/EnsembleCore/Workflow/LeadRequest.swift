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

    public static func task(text: String, projectID: Int64, workflowID: String, now: Date = .now) -> ProjectTask? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return ProjectTask(
            projectId: projectID, title: title(for: body), body: body, source: .chat, workflow: workflowID,
            status: .incoming, createdAt: now, updatedAt: now
        )
    }
}

extension WorkflowDefinition {
    public func leadRole(among leadRoleIDs: Set<String>) -> String? {
        steps.lazy.compactMap(\.role).first { leadRoleIDs.contains($0) }
    }

    public func assigningLead(_ leadID: String, replacing leadRoleIDs: Set<String>) -> WorkflowDefinition {
        var workflow = self
        for index in workflow.steps.indices where workflow.steps[index].type == .agent {
            if let role = workflow.steps[index].role, leadRoleIDs.contains(role) {
                workflow.steps[index].role = leadID
            }
        }
        return workflow
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
