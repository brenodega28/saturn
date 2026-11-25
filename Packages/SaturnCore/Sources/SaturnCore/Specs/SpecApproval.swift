import Foundation

public enum SpecApproval {
    public static func covers(_ document: SpecDocument) -> Bool {
        !document.workers.isEmpty && (document.status == .approved || document.status == .inProgress)
    }

    public static func excess(plan: Plan, workers: [SpecWorker]) -> String? {
        let approved = Dictionary(grouping: workers, by: \.kind).mapValues(\.count)
        let planned = Dictionary(grouping: plan.tasks, by: \.agent).mapValues(\.count)
        var problems: [String] = []
        for kind in AgentKind.allCases {
            guard let count = planned[kind], let limit = approved[kind], count > limit else { continue }
            problems.append("\(count) \(noun(kind, count)) planned, \(limit) approved")
        }
        let newRoles = AgentKind.allCases.filter { planned[$0] != nil && approved[$0] == nil }
        if !newRoles.isEmpty {
            problems.append("new role\(newRoles.count == 1 ? "" : "s"): " + newRoles.map(\.rawValue).joined(separator: ", "))
        }
        return problems.isEmpty ? nil : "Exceeds the approved spec: " + problems.joined(separator: "; ")
    }

    private static func noun(_ kind: AgentKind, _ count: Int) -> String {
        kind.rawValue + (count == 1 ? "" : "s")
    }
}
