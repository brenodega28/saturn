import Foundation

public enum ChatGroup: String, CaseIterable, Sendable {
    case needsYou
    case inProgress
    case notStarted
    case finished

    public static func of(_ stage: ChatStage) -> ChatGroup? {
        switch stage {
        case .needsYou, .stuck: .needsYou
        case .inReview, .building: .inProgress
        case .idle: .notStarted
        case .finished: .finished
        case .done, .dropped: nil
        }
    }

    public static func grouped<Item>(_ items: [Item], stage: (Item) -> ChatStage, lastActivity: (Item) -> Date) -> [ChatGroup: [Item]] {
        let sorted = items.enumerated().sorted { lhs, rhs in
            let (left, right) = (stage(lhs.element), stage(rhs.element))
            if left.groupRank != right.groupRank { return left.groupRank < right.groupRank }
            let (leftDate, rightDate) = (lastActivity(lhs.element), lastActivity(rhs.element))
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.offset < rhs.offset
        }
        var groups: [ChatGroup: [Item]] = [:]
        for entry in sorted {
            guard let group = of(stage(entry.element)) else { continue }
            groups[group, default: []].append(entry.element)
        }
        return groups
    }
}

private extension ChatStage {
    var groupRank: Int {
        switch self {
        case .needsYou: 0
        case .stuck: 1
        case .inReview: 2
        case .building: 3
        case .idle: 4
        case .finished: 5
        case .done: 6
        case .dropped: 7
        }
    }
}

public enum ProjectFilterKey {
    public static let all = ""

    public static func make(daemon: DaemonID, projectID: Int64?) -> String {
        "\(daemon.uuidString)-\(projectID ?? -1)"
    }

    public static func resolve(_ stored: String, among open: [String]) -> String {
        open.contains(stored) ? stored : all
    }

    public static func filter<Item>(_ items: [Item], by active: String, key: (Item) -> String) -> [Item] {
        active == all ? items : items.filter { key($0) == active }
    }
}
